import CoreImage
import CoreML
import CoreVideo
import Foundation
import Vision

struct EnrollmentSample {
    let embedding: [Float]
    let yaw: Float
}

/// v2 profile: multiple pose templates (overall + center/left/right buckets)
/// built from a staged enrollment. v1 single-embedding profiles are ignored —
/// they were computed from unaligned crops and don't compare to aligned ones.
struct FaceProfile: Codable {
    var version: Int
    var createdAt: Date
    var templates: [[Float]]
}

/// Computes identity embeddings for face crops via a bundled Core ML model
/// (MobileFaceNet, 112x112 RGB in, 512-d out) and matches them against the
/// enrolled owner profile. Crops are aligned to the canonical ArcFace eye
/// positions using Vision landmarks before embedding, which is what makes the
/// match robust across head/eye angles. Without a model or profile it
/// degrades to presence-only (any face counts as the owner).
final class FaceRecognizer {
    static let embeddingSize = 112

    // Canonical ArcFace eye positions in a 112x112 crop, bottom-left origin
    // (top-left template: L=(38.2946, 51.6963), R=(73.5318, 51.5014)).
    private static let canonicalLeftEye = CGPoint(x: 38.2946, y: 112 - 51.6963)
    private static let canonicalRightEye = CGPoint(x: 73.5318, y: 112 - 51.5014)

    private let model: MLModel?
    private let inputName: String
    private let outputName: String
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let deviceRGB = CGColorSpaceCreateDeviceRGB()
    private var cropBuffer: CVPixelBuffer?
    private let profileLock = NSLock()
    private var _profile: FaceProfile?

    static let profileURL: URL = {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LockscreenDah", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("profile.json")
    }()

    init() {
        if let url = Bundle.main.url(forResource: "FaceEmbedding", withExtension: "mlmodelc") {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            model = try? MLModel(contentsOf: url, configuration: configuration)
        } else {
            model = nil
        }
        inputName = model?.modelDescription.inputDescriptionsByName.keys.first ?? "input"
        outputName = model?.modelDescription.outputDescriptionsByName.keys.first ?? "output"
        _profile = Self.loadProfile()
    }

    var hasModel: Bool { model != nil }

    var hasProfile: Bool {
        profileLock.lock(); defer { profileLock.unlock() }
        return _profile != nil
    }

    /// Presence-only mode: no model or no enrolled owner yet.
    var isPresenceOnly: Bool { !hasModel || !hasProfile }

    // MARK: - Matching

    /// Max cosine similarity across the enrolled profile's pose templates.
    func similarityToOwner(_ embedding: [Float]) -> Float? {
        profileLock.lock()
        let profile = _profile
        profileLock.unlock()
        guard let profile, !profile.templates.isEmpty else { return nil }
        return similarity(of: embedding, to: profile)
    }

    // MARK: - Embedding

    /// Aligns the observed face to the canonical eye positions (falling back
    /// to a plain bounding-box crop when landmarks fail), then runs the
    /// embedding model. Returns an L2-normalized embedding.
    func embedding(for face: VNFaceObservation, in pixelBuffer: CVPixelBuffer) -> [Float]? {
        guard let model else { return nil }
        guard let faceImage = alignedFaceImage(for: face, in: pixelBuffer)
            ?? croppedFaceImage(for: face, in: pixelBuffer)
        else { return nil }

        let target = CGFloat(Self.embeddingSize)
        guard let crop = reusableCropBuffer() else { return nil }
        ciContext.render(
            faceImage,
            to: crop,
            bounds: CGRect(x: 0, y: 0, width: target, height: target),
            colorSpace: deviceRGB
        )

        guard
            let input = try? MLDictionaryFeatureProvider(dictionary: [
                inputName: MLFeatureValue(pixelBuffer: crop)
            ]),
            let output = try? model.prediction(from: input),
            let array = output.featureValue(for: outputName)?.multiArrayValue
        else { return nil }

        var values = [Float](repeating: 0, count: array.count)
        for index in 0..<array.count {
            values[index] = array[index].floatValue
        }
        return Self.normalized(values)
    }

    /// Similarity-transforms the frame so the detected pupils land on the
    /// canonical ArcFace eye positions of a 112x112 crop.
    private func alignedFaceImage(for face: VNFaceObservation, in pixelBuffer: CVPixelBuffer) -> CIImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let imageSize = CGSize(width: width, height: height)

        let request = VNDetectFaceLandmarksRequest()
        request.inputFaceObservations = [face]
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard
            (try? handler.perform([request])) != nil,
            let landmarks = request.results?.first?.landmarks,
            let leftEye = Self.centroid(of: landmarks.leftPupil ?? landmarks.leftEye, imageSize: imageSize),
            let rightEye = Self.centroid(of: landmarks.rightPupil ?? landmarks.rightEye, imageSize: imageSize)
        else { return nil }

        // Vision's "left eye" is the subject's left, i.e. on the image's
        // right side for a mirrored-feeling webcam frame; order by x instead
        // so the transform never flips the face.
        let (imageLeft, imageRight) = leftEye.x <= rightEye.x
            ? (leftEye, rightEye) : (rightEye, leftEye)

        let sourceDelta = CGPoint(x: imageRight.x - imageLeft.x, y: imageRight.y - imageLeft.y)
        let sourceLength = hypot(sourceDelta.x, sourceDelta.y)
        guard sourceLength > 8 else { return nil } // face too small to align

        let targetDelta = CGPoint(
            x: Self.canonicalRightEye.x - Self.canonicalLeftEye.x,
            y: Self.canonicalRightEye.y - Self.canonicalLeftEye.y
        )
        let scale = hypot(targetDelta.x, targetDelta.y) / sourceLength
        let rotation = atan2(targetDelta.y, targetDelta.x) - atan2(sourceDelta.y, sourceDelta.x)

        let a = scale * cos(rotation)
        let b = scale * sin(rotation)
        let transform = CGAffineTransform(
            a: a, b: b, c: -b, d: a,
            tx: Self.canonicalLeftEye.x - (a * imageLeft.x - b * imageLeft.y),
            ty: Self.canonicalLeftEye.y - (b * imageLeft.x + a * imageLeft.y)
        )

        let side = CGFloat(Self.embeddingSize)
        return CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: transform)
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }

    /// Fallback when landmarks are unavailable (e.g. strong profile view):
    /// square bounding-box crop with margin, scaled to 112x112.
    private func croppedFaceImage(for face: VNFaceObservation, in pixelBuffer: CVPixelBuffer) -> CIImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let faceRect = VNImageRectForNormalizedRect(face.boundingBox, width, height)
        let side = max(faceRect.width, faceRect.height) * 1.5
        let square = CGRect(
            x: faceRect.midX - side / 2,
            y: faceRect.midY - side / 2,
            width: side,
            height: side
        ).intersection(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        guard !square.isEmpty else { return nil }

        let target = CGFloat(Self.embeddingSize)
        return CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: square)
            .transformed(by: CGAffineTransform(translationX: -square.minX, y: -square.minY))
            .transformed(by: CGAffineTransform(scaleX: target / square.width, y: target / square.height))
    }

    private static func centroid(of region: VNFaceLandmarkRegion2D?, imageSize: CGSize) -> CGPoint? {
        guard let region, region.pointCount > 0 else { return nil }
        let points = region.pointsInImage(imageSize: imageSize)
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private func reusableCropBuffer() -> CVPixelBuffer? {
        if let cropBuffer { return cropBuffer }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.embeddingSize,
            Self.embeddingSize,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer
        )
        cropBuffer = buffer
        return buffer
    }

    // MARK: - Enrollment profile

    /// Builds pose templates from the staged enrollment samples (overall mean
    /// plus per-pose means bucketed by yaw) and self-checks that the samples
    /// actually match their own profile. Nothing is persisted — the caller
    /// verifies live against the candidate, then `commit`s it.
    func makeCandidateProfile(samples: [EnrollmentSample]) throws -> FaceProfile {
        guard let dimensions = samples.first?.embedding.count, dimensions > 0 else {
            throw enrollmentError("No enrollment samples captured.")
        }

        var templates: [[Float]] = [Self.mean(of: samples.map(\.embedding), dimensions: dimensions)]
        let buckets: [(String, (Float) -> Bool)] = [
            ("center", { abs($0) <= 0.15 }),
            ("left", { $0 < -0.15 }),
            ("right", { $0 > 0.15 }),
        ]
        for (_, contains) in buckets {
            let bucket = samples.filter { contains($0.yaw) }.map(\.embedding)
            if bucket.count >= 2 {
                templates.append(Self.mean(of: bucket, dimensions: dimensions))
            }
        }

        // Self-check (guards against a corrupted enrollment locking the user
        // out repeatedly): every capture should strongly match the profile it
        // just produced.
        let profile = FaceProfile(version: 2, createdAt: Date(), templates: templates)
        let similarities = samples.map { similarity(of: $0.embedding, to: profile) }
        let meanSimilarity = similarities.reduce(0, +) / Float(similarities.count)
        guard meanSimilarity >= 0.5 else {
            throw enrollmentError(
                "Captures were too inconsistent (score \(String(format: "%.2f", meanSimilarity))). Try again with better lighting."
            )
        }

        return profile
    }

    /// Persists a verified candidate profile and makes it the active one.
    /// The file holds biometric templates, so it's written owner-only (0600) —
    /// keeps it out of reach of other local users (same-user code is already
    /// game over for any file the user can read).
    func commit(_ profile: FaceProfile) throws {
        let data = try JSONEncoder().encode(profile)
        try data.write(to: Self.profileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: Self.profileURL.path
        )

        profileLock.lock()
        _profile = profile
        profileLock.unlock()
    }

    /// Max cosine similarity of an embedding against a profile's templates —
    /// the one matching rule, shared by live matching, the enrollment
    /// self-check, and candidate verification.
    func similarity(of embedding: [Float], to profile: FaceProfile) -> Float {
        profile.templates
            .map { Self.cosineSimilarity(embedding, $0) }
            .max() ?? 0
    }

    private func enrollmentError(_ message: String) -> NSError {
        NSError(domain: "LockscreenDah", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func loadProfile() -> FaceProfile? {
        guard
            let data = try? Data(contentsOf: profileURL),
            let profile = try? JSONDecoder().decode(FaceProfile.self, from: data),
            profile.version >= 2, !profile.templates.isEmpty
        else { return nil }
        return profile
    }

    // MARK: - Math

    private static func mean(of vectors: [[Float]], dimensions: Int) -> [Float] {
        var result = [Float](repeating: 0, count: dimensions)
        for vector in vectors {
            for index in 0..<dimensions { result[index] += vector[index] }
        }
        for index in 0..<dimensions { result[index] /= Float(vectors.count) }
        return normalized(result)
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for index in 0..<a.count {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (sqrt(normA) * sqrt(normB))
    }
}

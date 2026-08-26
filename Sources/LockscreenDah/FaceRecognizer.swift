import CoreImage
import CoreML
import CoreVideo
import Foundation
import Vision

struct EnrollmentSample {
    let embedding: [Float]
    let yaw: Float
    /// Signed, but the sign convention is deliberately never relied on: the
    /// "tilted" stage gates on magnitude, so whichever direction a given user
    /// tips their head becomes their tilted bucket without the code having to
    /// know which way Vision counts as positive.
    let pitch: Float
    /// Vision's capture-quality score, when the enrollment-only quality request
    /// produced one. It is used only to rank captures from the same pose; the
    /// score is not a liveness signal and has no global pass/fail threshold.
    let captureQuality: Float?

    init(embedding: [Float], yaw: Float, pitch: Float, captureQuality: Float? = nil) {
        self.embedding = embedding
        self.yaw = yaw
        self.pitch = pitch
        self.captureQuality = captureQuality
    }
}

/// v3 profiles contain one template per completed enrollment pose. Existing v2
/// profiles remain readable and keep their original template set; v1
/// single-embedding profiles are ignored —
/// they were computed from unaligned crops and don't compare to aligned ones.
struct FaceProfile: Codable {
    var version: Int
    var createdAt: Date
    var templates: [[Float]]
    /// Resting head pitch measured during enrollment.
    ///
    /// A laptop camera sits above the screen looking down, so a seated user reads
    /// a non-zero pitch (~0.2 rad measured) while facing straight ahead — and the
    /// offset differs with screen height, chair, and external cameras. Judging
    /// tilt against absolute zero therefore means something different on every
    /// desk. Optional so profiles written before this decode unchanged; nil falls
    /// back to absolute.
    var baselinePitch: Float?
}

/// Computes identity embeddings for face crops via a bundled Core ML model
/// (MobileFaceNet, 112x112 RGB in, 512-d out) and matches them against the
/// enrolled owner profile. Crops are aligned to the canonical ArcFace eye
/// positions using Vision landmarks before embedding, which is what makes the
/// match robust across head/eye angles. Without a model or profile it
/// degrades to presence-only (any face counts as the owner).
final class FaceRecognizer {
    static let embeddingSize = 112
    static let embeddingDimensions = 512
    static let poseProfileVersion = 3
    /// How far from the user's *resting* pitch counts as tilted (radians, ~14°).
    /// Relative, not absolute: measured resting pitch is ~0.2 on a laptop and
    /// differs per desk, so an absolute bar would reject a straight-ahead pose on
    /// one setup and accept a barely-tilted one on another.
    static let tiltedPitch: Float = 0.25
    /// A turn far enough to be a distinct pose. Measured: a deliberate "slight"
    /// turn reaches only ~0.15 rad, so an 0.15 gate rejects real turns — which is
    /// exactly what stalled enrollment.
    static let turnedYaw: Float = 0.09

    // Canonical ArcFace eye positions in a 112x112 crop, bottom-left origin
    // (top-left template: L=(38.2946, 51.6963), R=(73.5318, 51.5014)).
    private static let canonicalLeftEye = CGPoint(x: 38.2946, y: 112 - 51.6963)
    private static let canonicalRightEye = CGPoint(x: 73.5318, y: 112 - 51.5014)

    private let modelURL: URL?
    private let modelCanLoad: Bool
    /// Mutable inference scratch belongs to one capture generation. Recovery can
    /// abandon a permanently hung generation and start another without the old
    /// and new callbacks racing on a shared Core Image context or crop buffer.
    final class InferenceContext {
        private let modelURL: URL?
        /// Loaded lazily on this generation's analysis queue. Model creation can
        /// itself be expensive; doing it on the session-control queue would put
        /// recovery back behind inference work by another route.
        fileprivate lazy var model: MLModel? = {
            guard let modelURL else { return nil }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            return try? MLModel(contentsOf: modelURL, configuration: configuration)
        }()
        fileprivate var inputName: String {
            model?.modelDescription.inputDescriptionsByName.keys.first ?? "input"
        }
        fileprivate var outputName: String {
            model?.modelDescription.outputDescriptionsByName.keys.first ?? "output"
        }
        fileprivate let ciContext = CIContext(options: [.cacheIntermediates: false])
        fileprivate let deviceRGB = CGColorSpaceCreateDeviceRGB()
        fileprivate var cropBuffer: CVPixelBuffer?

        fileprivate init(modelURL: URL?) {
            self.modelURL = modelURL
        }
    }
    /// What the last profile build scored, so a threshold can be chosen from
    /// evidence rather than intuition. Every threshold in this app was picked by
    /// reasoning; the scores were computed and thrown away.
    struct EnrollmentScores {
        let worst: Float
        let mean: Float
        let templates: Int
    }
    private(set) var lastEnrollmentScores: EnrollmentScores?

    private let profileLock = NSLock()
    private var _profile: FaceProfile?

    static let profileURL: URL = {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LockscreenDah", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("profile.json")
    }()

    convenience init() {
        self.init(
            modelURL: Bundle.main.url(forResource: "FaceEmbedding", withExtension: "mlmodelc"),
            profile: Self.loadProfile()
        )
    }

    /// Explicit model injection is reserved for the local evaluator. Production
    /// always calls `init()` above and therefore remains pinned to the bundled
    /// MobileFaceNet resource; supplying an R50 here cannot silently change the
    /// monitoring model or the persisted profile.
    init(modelURL url: URL?, profile: FaceProfile?) {
        modelURL = url
        if let url {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            modelCanLoad = (try? MLModel(contentsOf: url, configuration: configuration)) != nil
        } else {
            modelCanLoad = false
        }
        _profile = profile
    }

    var hasModel: Bool { modelCanLoad }

    func makeInferenceContext() -> InferenceContext {
        InferenceContext(modelURL: modelCanLoad ? modelURL : nil)
    }

    var hasProfile: Bool {
        profileLock.lock(); defer { profileLock.unlock() }
        return _profile != nil
    }

    /// Presence-only mode: no model or no enrolled owner yet.
    var isPresenceOnly: Bool { !hasModel || !hasProfile }

    /// The enrolled resting pitch, or 0 for profiles predating it.
    var baselinePitch: Float {
        profileLock.lock()
        defer { profileLock.unlock() }
        return _profile?.baselinePitch ?? 0
    }

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
    func embedding(
        for face: VNFaceObservation,
        in pixelBuffer: CVPixelBuffer,
        context: InferenceContext
    ) -> [Float]? {
        guard let model = context.model else { return nil }
        guard let faceImage = alignedFaceImage(for: face, in: pixelBuffer)
            ?? croppedFaceImage(for: face, in: pixelBuffer)
        else { return nil }

        let target = CGFloat(Self.embeddingSize)
        guard let crop = reusableCropBuffer(in: context) else { return nil }
        context.ciContext.render(
            faceImage,
            to: crop,
            bounds: CGRect(x: 0, y: 0, width: target, height: target),
            colorSpace: context.deviceRGB
        )

        guard
            let input = try? MLDictionaryFeatureProvider(dictionary: [
                context.inputName: MLFeatureValue(pixelBuffer: crop)
            ]),
            let output = try? model.prediction(from: input),
            let array = output.featureValue(for: context.outputName)?.multiArrayValue,
            array.count == Self.embeddingDimensions
        else { return nil }

        var values = [Float](repeating: 0, count: array.count)
        for index in 0..<array.count {
            values[index] = array[index].floatValue
        }
        guard values.allSatisfy(\.isFinite) else { return nil }
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

    private func reusableCropBuffer(in context: InferenceContext) -> CVPixelBuffer? {
        if let cropBuffer = context.cropBuffer { return cropBuffer }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.embeddingSize,
            Self.embeddingSize,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer
        )
        context.cropBuffer = buffer
        return buffer
    }

    // MARK: - Enrollment profile

    /// Builds exactly one template from each completed pose. The controller has
    /// already proved that every group satisfied its stage gate, so inferring
    /// poses again from noisy yaw/pitch values only loses information. It also
    /// avoids the former cross-pose mean, which broadened max-cosine acceptance
    /// by averaging incompatible views into one template.
    ///
    /// When every capture in a pose has a Vision quality score, the lowest one
    /// is omitted from that pose's mean. Capture quality is only comparable
    /// within this small burst; no global threshold is assumed. Missing quality
    /// preserves the old all-samples behavior.
    static func buildPoseTemplates(
        from poseSamples: [[EnrollmentSample]], dimensions: Int
    ) -> ([[Float]], Float) {
        let groups = poseSamples.filter { !$0.isEmpty }
        let templates = groups.map { group in
            let ranked: [EnrollmentSample]
            let qualities = group.compactMap(\.captureQuality)
            if group.count >= 3,
               qualities.count == group.count,
               qualities.allSatisfy(\.isFinite),
               let minimum = qualities.min(),
               let maximum = qualities.max(),
               maximum > minimum,
               qualities.filter({ $0 == minimum }).count == 1,
               let lowestIndex = qualities.firstIndex(of: minimum) {
                ranked = group.enumerated().compactMap { index, sample in
                    index == lowestIndex ? nil : sample
                }
            } else {
                ranked = group
            }
            return mean(of: ranked.map(\.embedding), dimensions: dimensions)
        }
        let resting = groups.first ?? []
        let restingPitch = resting.isEmpty
            ? 0
            : resting.reduce(0) { $0 + $1.pitch } / Float(resting.count)
        return (templates, restingPitch)
    }

    func makeCandidateProfile(poseSamples: [[EnrollmentSample]]) throws -> FaceProfile {
        let samples = poseSamples.flatMap { $0 }
        guard let dimensions = samples.first?.embedding.count, dimensions > 0 else {
            throw enrollmentError("No enrollment samples captured.")
        }
        guard poseSamples.allSatisfy({ $0.count >= 2 }),
              dimensions == Self.embeddingDimensions,
              samples.allSatisfy({
                  $0.embedding.count == dimensions && $0.embedding.allSatisfy(\.isFinite)
              })
        else {
            throw enrollmentError("Enrollment poses were incomplete or incompatible.")
        }

        let (templates, restingPitch) = Self.buildPoseTemplates(
            from: poseSamples, dimensions: dimensions
        )

        // Self-check (guards against a corrupted enrollment locking the user
        // out repeatedly): every capture should strongly match the profile it
        // just produced.
        let profile = FaceProfile(
            version: Self.poseProfileVersion,
            createdAt: Date(),
            templates: templates,
            baselinePitch: restingPitch
        )
        // Scored leave-one-out: each sample is measured against templates built
        // from the *other* samples. Scoring a sample against a profile it helped
        // build flatters it — the template partly is that sample — and these
        // numbers are what a decision to tighten `matchThreshold` rests on, so
        // the bias was live: it reads as headroom that doesn't exist.
        let poseSimilarities = poseSamples.indices.map { poseIndex in
            poseSamples[poseIndex].indices.map { sampleIndex in
                var heldOutGroups = poseSamples
                let sample = heldOutGroups[poseIndex].remove(at: sampleIndex)
                let (heldOut, baseline) = Self.buildPoseTemplates(
                    from: heldOutGroups, dimensions: dimensions
                )
                return similarity(
                    of: sample.embedding,
                    to: FaceProfile(
                        version: Self.poseProfileVersion,
                        createdAt: profile.createdAt,
                        templates: heldOut,
                        baselinePitch: baseline
                    )
                )
            }
        }
        let similarities = poseSimilarities.flatMap { $0 }
        // The *worst* pose is what decides whether the live threshold is safe to
        // tighten — a good mean can hide one pose scoring near the bar, which is
        // precisely the case that produces false countdowns in normal use.
        lastEnrollmentScores = EnrollmentScores(
            worst: similarities.min() ?? 0,
            mean: similarities.reduce(0, +) / Float(similarities.count),
            templates: templates.count
        )
        let poseMeans = poseSimilarities.map { scores in
            scores.reduce(0, +) / Float(scores.count)
        }
        let meanSimilarity = similarities.reduce(0, +) / Float(similarities.count)
        guard poseMeans.allSatisfy({ $0 >= 0.5 }) else {
            throw enrollmentError(
                "A captured pose was too inconsistent (overall score \(String(format: "%.2f", meanSimilarity))). Try again with better lighting."
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

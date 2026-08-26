import CoreGraphics
import CoreImage
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Vision

/// Opt-in, local-only A/B harness for compiled face-embedding models. It uses
/// the production `FaceRecognizer` path, holds images and embeddings in memory,
/// and writes aggregate JSON to stdout only. It is deliberately not reachable
/// from the menu-bar application flow.
enum RecognitionEvaluator {
    struct ModelInput: Equatable {
        let name: String
        let url: URL
    }

    struct Options: Equatable {
        let manifestURL: URL
        let models: [ModelInput]
        let threshold: Float?
    }

    struct Manifest: Decodable {
        struct EnrollmentGroup: Decodable {
            let name: String
            let images: [String]
        }

        struct Probe: Decodable {
            let image: String
            let subject: String
            let expectedOwner: Bool
        }

        let enrollment: [EnrollmentGroup]
        let probes: [Probe]
        let threshold: Float?
        let modelThresholds: [String: Float]?
    }

    struct LatencySummary: Encodable, Equatable {
        let samples: Int
        let p50Milliseconds: Double
        let p95Milliseconds: Double
        let p99Milliseconds: Double
    }

    struct OutcomeSummary: Encodable, Equatable {
        let ownerProbes: Int
        let otherProbes: Int
        let trueAccepts: Int
        let falseRejects: Int
        let falseAccepts: Int
        let trueRejects: Int
        let trueAcceptRate: Double?
        let falseRejectRate: Double?
        let falseAcceptRate: Double?
        let otherSubjects: Int
        let otherSubjectsEverAccepted: Int
        let subjectFalseAcceptRate: Double?
    }

    struct ModelReport: Encodable {
        let model: String
        let modelBytes: Int64
        let modelSHA256: String
        let threshold: Float
        let templates: Int
        let enrollmentImages: Int
        let modelValidationLoadMilliseconds: Double
        let coldEmbeddingMilliseconds: Double
        let warmEmbedding: LatencySummary
        let probeDetectionAndEmbedding: LatencySummary
        let ownerSimilarity: SimilaritySummary
        let otherSimilarity: SimilaritySummary
        let outcomes: OutcomeSummary
    }

    struct Report: Encodable {
        let osVersion: String
        let architecture: String
        let hardwareModel: String
        let computeUnits: String
        let inputSize: Int
        let embeddingDimensions: Int
        let manifestSHA256: String
        let alternatingModelOrder: [String]
        let models: [ModelReport]
    }

    struct SimilaritySummary: Encodable, Equatable {
        let samples: Int
        let minimum: Float
        let p05: Float
        let median: Float
        let p95: Float
        let maximum: Float
    }

    private struct PreparedImage {
        let url: URL
        let pixelBuffer: CVPixelBuffer
        let face: VNFaceObservation
        let captureQuality: Float?
        let detectionMilliseconds: Double
    }

    private final class ModelRun {
        let input: ModelInput
        let recognizer: FaceRecognizer
        let context: FaceRecognizer.InferenceContext
        let validationLoadMilliseconds: Double
        var poseSamples: [[EnrollmentSample]]
        var embeddingLatencies: [Double] = []
        var probeTotalLatencies: [Double] = []
        var outcomes: [(subject: String, expectedOwner: Bool, accepted: Bool)] = []
        var ownerScores: [Float] = []
        var otherScores: [Float] = []
        var profile: FaceProfile?

        init(input: ModelInput, poseGroups: Int) throws {
            self.input = input
            let start = Uptime.now
            recognizer = FaceRecognizer(modelURL: input.url, profile: nil)
            validationLoadMilliseconds = (Uptime.now - start) * 1_000
            guard recognizer.hasModel else {
                throw RecognitionEvaluator.failure("Model '\(input.name)' could not be loaded.")
            }
            context = recognizer.makeInferenceContext()
            poseSamples = Array(repeating: [], count: poseGroups)
        }
    }

    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    static let usage = """
    Usage:
      LockscreenDah --evaluate-model --manifest DATASET.json \\
        --model mbf=/path/FaceEmbedding.mlmodelc \\
        [--model r50=/path/UserProvidedR50.mlmodelc] [--threshold 0.45]

    Models must already be compiled `.mlmodelc` directories. The evaluator
    neither downloads nor converts models and emits aggregate JSON only.
    """

    static func parse(arguments: [String], currentDirectory: URL) throws -> Options {
        var manifestURL: URL?
        var models: [ModelInput] = []
        var threshold: Float?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            guard index + 1 < arguments.count else {
                throw failure("Missing value after \(argument).")
            }
            let value = arguments[index + 1]
            switch argument {
            case "--manifest":
                guard manifestURL == nil else { throw failure("--manifest may appear only once.") }
                manifestURL = resolvedURL(value, relativeTo: currentDirectory)
            case "--model":
                guard let separator = value.firstIndex(of: "=") else {
                    throw failure("--model must be NAME=/path/Model.mlmodelc.")
                }
                let name = String(value[..<separator])
                let path = String(value[value.index(after: separator)...])
                guard !name.isEmpty, !path.isEmpty else {
                    throw failure("--model must have a non-empty name and path.")
                }
                guard !models.contains(where: { $0.name == name }) else {
                    throw failure("Model name '\(name)' is duplicated.")
                }
                models.append(ModelInput(name: name, url: resolvedURL(path, relativeTo: currentDirectory)))
            case "--threshold":
                guard threshold == nil, let parsed = Float(value), (0...1).contains(parsed) else {
                    throw failure("--threshold must be a number from 0 through 1.")
                }
                threshold = parsed
            default:
                throw failure("Unknown evaluator argument: \(argument).")
            }
            index += 2
        }

        guard let manifestURL else { throw failure("--manifest is required.") }
        guard !models.isEmpty else { throw failure("At least one --model is required.") }
        return Options(manifestURL: manifestURL, models: models, threshold: threshold)
    }

    static func run(arguments: [String]) throws {
        let options = try parse(
            arguments: arguments,
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
        let data = try Data(contentsOf: options.manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        try validate(manifest)

        let baseURL = options.manifestURL.deletingLastPathComponent()
        var thresholds: [String: Float] = [:]
        for model in options.models {
            let threshold = options.threshold
                ?? manifest.modelThresholds?[model.name]
                ?? manifest.threshold
                ?? Settings.matchThreshold
            guard (0...1).contains(threshold) else {
                throw failure("Threshold for model '\(model.name)' must be from 0 through 1.")
            }
            thresholds[model.name] = threshold
        }
        let reports = try evaluate(
            models: options.models,
            manifest: manifest,
            baseURL: baseURL,
            thresholds: thresholds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let report = Report(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            hardwareModel: hardwareModel,
            computeUnits: "all",
            inputSize: FaceRecognizer.embeddingSize,
            embeddingDimensions: FaceRecognizer.embeddingDimensions,
            manifestSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            alternatingModelOrder: options.models.map(\.name),
            models: reports
        )
        let output = try encoder.encode(report)
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func summarizeLatencies(_ values: [Double]) -> LatencySummary {
        LatencySummary(
            samples: values.count,
            p50Milliseconds: percentile(values, at: 0.50),
            p95Milliseconds: percentile(values, at: 0.95),
            p99Milliseconds: percentile(values, at: 0.99)
        )
    }

    static func summarizeOutcomes(
        _ observations: [(subject: String, expectedOwner: Bool, accepted: Bool)]
    ) -> OutcomeSummary {
        let owner = observations.filter(\.expectedOwner)
        let others = observations.filter { !$0.expectedOwner }
        let trueAccepts = owner.filter(\.accepted).count
        let falseRejects = owner.count - trueAccepts
        let falseAccepts = others.filter(\.accepted).count
        let trueRejects = others.count - falseAccepts
        let otherSubjects = Set(others.map(\.subject))
        let acceptedSubjects = Set(others.filter(\.accepted).map(\.subject))
        return OutcomeSummary(
            ownerProbes: owner.count,
            otherProbes: others.count,
            trueAccepts: trueAccepts,
            falseRejects: falseRejects,
            falseAccepts: falseAccepts,
            trueRejects: trueRejects,
            trueAcceptRate: rate(trueAccepts, over: owner.count),
            falseRejectRate: rate(falseRejects, over: owner.count),
            falseAcceptRate: rate(falseAccepts, over: others.count),
            otherSubjects: otherSubjects.count,
            otherSubjectsEverAccepted: acceptedSubjects.count,
            subjectFalseAcceptRate: rate(acceptedSubjects.count, over: otherSubjects.count)
        )
    }

    static func summarizeSimilarities(_ values: [Float]) -> SimilaritySummary {
        guard !values.isEmpty else {
            return SimilaritySummary(
                samples: 0, minimum: 0, p05: 0, median: 0, p95: 0, maximum: 0
            )
        }
        let sorted = values.sorted()
        return SimilaritySummary(
            samples: sorted.count,
            minimum: sorted[0],
            p05: similarityPercentile(sorted, at: 0.05),
            median: similarityPercentile(sorted, at: 0.50),
            p95: similarityPercentile(sorted, at: 0.95),
            maximum: sorted[sorted.count - 1]
        )
    }

    private static func evaluate(
        models: [ModelInput],
        manifest: Manifest,
        baseURL: URL,
        thresholds: [String: Float]
    ) throws -> [ModelReport] {
        for model in models {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: model.url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  model.url.pathExtension == "mlmodelc"
            else {
                throw failure("Model '\(model.name)' must be an existing compiled .mlmodelc directory.")
            }
        }
        let runs = try models.map { try ModelRun(input: $0, poseGroups: manifest.enrollment.count) }

        // Decode/detect each frame once, then alternate which model embeds it
        // first. This removes image/Vision duplication and distributes warm-cache
        // and thermal order effects rather than always favoring the second model.
        var geometryGroups = Array(repeating: [EnrollmentSample](), count: manifest.enrollment.count)
        var frameIndex = 0
        for (poseIndex, group) in manifest.enrollment.enumerated() {
            for image in group.images {
                let prepared = try prepareImage(
                    at: resolvedURL(image, relativeTo: baseURL),
                    includeCaptureQuality: true
                )
                let geometry = EnrollmentSample(
                    embedding: [],
                    yaw: prepared.face.yaw?.floatValue ?? 0,
                    pitch: prepared.face.pitch?.floatValue ?? 0,
                    captureQuality: prepared.captureQuality
                )
                let previousGroups = Array(geometryGroups.prefix(poseIndex))
                guard EnrollmentStages.all[poseIndex].accepts(geometry, previousGroups) else {
                    throw failure("Image \(prepared.url.path) does not satisfy pose '\(group.name)'.")
                }
                geometryGroups[poseIndex].append(geometry)
                for runIndex in alternatingIndices(count: runs.count, frame: frameIndex) {
                    let (sample, latency) = try embed(prepared, with: runs[runIndex])
                    runs[runIndex].poseSamples[poseIndex].append(sample)
                    runs[runIndex].embeddingLatencies.append(latency)
                }
                frameIndex += 1
            }
        }
        for run in runs {
            run.profile = try run.recognizer.makeCandidateProfile(poseSamples: run.poseSamples)
        }

        for probe in manifest.probes {
            let prepared = try prepareImage(
                at: resolvedURL(probe.image, relativeTo: baseURL),
                includeCaptureQuality: false
            )
            for runIndex in alternatingIndices(count: runs.count, frame: frameIndex) {
                let run = runs[runIndex]
                guard let profile = run.profile, let threshold = thresholds[run.input.name] else {
                    throw failure("Evaluator profile or threshold was not initialized.")
                }
                let (sample, latency) = try embed(prepared, with: run)
                run.embeddingLatencies.append(latency)
                run.probeTotalLatencies.append(prepared.detectionMilliseconds + latency)
                let similarity = run.recognizer.similarity(of: sample.embedding, to: profile)
                if probe.expectedOwner {
                    run.ownerScores.append(similarity)
                } else {
                    run.otherScores.append(similarity)
                }
                run.outcomes.append((
                    subject: probe.subject,
                    expectedOwner: probe.expectedOwner,
                    accepted: similarity >= threshold
                ))
            }
            frameIndex += 1
        }

        return try runs.map { run in
            guard let profile = run.profile, let threshold = thresholds[run.input.name] else {
                throw failure("Evaluator profile or threshold was not initialized.")
            }
            return ModelReport(
                model: run.input.name,
                modelBytes: try directoryBytes(run.input.url),
                modelSHA256: try directorySHA256(run.input.url),
                threshold: threshold,
                templates: profile.templates.count,
                enrollmentImages: run.poseSamples.reduce(0) { $0 + $1.count },
                modelValidationLoadMilliseconds: run.validationLoadMilliseconds,
                coldEmbeddingMilliseconds: run.embeddingLatencies.first ?? 0,
                warmEmbedding: summarizeLatencies(Array(run.embeddingLatencies.dropFirst())),
                probeDetectionAndEmbedding: summarizeLatencies(run.probeTotalLatencies),
                ownerSimilarity: summarizeSimilarities(run.ownerScores),
                otherSimilarity: summarizeSimilarities(run.otherScores),
                outcomes: summarizeOutcomes(run.outcomes)
            )
        }
    }

    private static func prepareImage(
        at url: URL, includeCaptureQuality: Bool
    ) throws -> PreparedImage {
        let pixelBuffer = try loadPixelBuffer(url)
        let detectionStart = Uptime.now
        let faceRequest = VNDetectFaceRectanglesRequest()
        faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try handler.perform([faceRequest])
        guard let faces = faceRequest.results, faces.count == 1, let face = faces.first else {
            throw failure("Expected exactly one face in \(url.path); found \(faceRequest.results?.count ?? 0).")
        }
        var captureQuality: Float?
        if includeCaptureQuality {
            let qualityRequest = VNDetectFaceCaptureQualityRequest()
            if (try? handler.perform([qualityRequest])) != nil {
                captureQuality = FaceCaptureQualityMatcher.quality(
                    for: face.boundingBox,
                    candidates: (qualityRequest.results ?? []).compactMap { qualityFace in
                        qualityFace.faceCaptureQuality.map {
                            (box: qualityFace.boundingBox, quality: $0)
                        }
                    }
                )
            }
        }
        return PreparedImage(
            url: url,
            pixelBuffer: pixelBuffer,
            face: face,
            captureQuality: captureQuality,
            detectionMilliseconds: milliseconds(since: detectionStart)
        )
    }

    private static func embed(
        _ prepared: PreparedImage, with run: ModelRun
    ) throws -> (sample: EnrollmentSample, milliseconds: Double) {
        let start = Uptime.now
        guard let embedding = run.recognizer.embedding(
            for: prepared.face,
            in: prepared.pixelBuffer,
            context: run.context
        ) else {
            throw failure(
                "Model '\(run.input.name)' failed to embed \(prepared.url.path); expected a finite 512-value output."
            )
        }
        return (
            EnrollmentSample(
                embedding: embedding,
                yaw: prepared.face.yaw?.floatValue ?? 0,
                pitch: prepared.face.pitch?.floatValue ?? 0,
                captureQuality: prepared.captureQuality
            ),
            milliseconds(since: start)
        )
    }

    static func alternatingIndices(count: Int, frame: Int) -> [Int] {
        let indices = Array(0..<count)
        return frame.isMultiple(of: 2) ? indices : Array(indices.reversed())
    }

    private static func loadPixelBuffer(_ url: URL) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw failure("Could not read image at \(url.path).")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw failure("Could not decode image at \(url.path).")
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            image.width,
            image.height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw failure("Could not allocate an image buffer for \(url.path).")
        }
        imageContext.render(
            CIImage(cgImage: image),
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return buffer
    }

    private static func validate(_ manifest: Manifest) throws {
        let expectedNames = ["straight", "left", "right", "down"]
        guard manifest.enrollment.count == EnrollmentStages.all.count,
              zip(manifest.enrollment, EnrollmentStages.all).enumerated().allSatisfy({ index, pair in
                  pair.0.name == expectedNames[index] && pair.0.images.count >= pair.1.target
              })
        else {
            throw failure("Enrollment groups must be straight, left, right, down in order, with at least four images each.")
        }
        guard manifest.probes.contains(where: \.expectedOwner),
              manifest.probes.contains(where: { !$0.expectedOwner }),
              manifest.probes.allSatisfy({ !$0.subject.isEmpty }),
              Set(manifest.probes.filter(\.expectedOwner).map(\.subject)).count == 1
        else {
            throw failure("Probes need one opaque owner subject and at least one non-owner subject.")
        }
    }

    private static func resolvedURL(_ path: String, relativeTo baseURL: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return baseURL.appendingPathComponent(path).standardizedFileURL
    }

    private static func percentile(_ values: [Double], at quantile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = max(0, min(sorted.count - 1, Int(ceil(quantile * Double(sorted.count))) - 1))
        return sorted[index]
    }

    private static func similarityPercentile(_ sorted: [Float], at quantile: Double) -> Float {
        let index = max(0, min(sorted.count - 1, Int(ceil(quantile * Double(sorted.count))) - 1))
        return sorted[index]
    }

    private static func rate(_ numerator: Int, over denominator: Int) -> Double? {
        denominator == 0 ? nil : Double(numerator) / Double(denominator)
    }

    private static func milliseconds(since start: TimeInterval) -> Double {
        (Uptime.now - start) * 1_000
    }

    private static func directoryBytes(_ url: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: keys)
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    /// Stable fingerprint over relative file names and bytes, without exposing
    /// the local model path. Two reports can therefore prove they evaluated the
    /// same compiled artifact rather than trusting a caller-supplied label.
    private static func directorySHA256(_ url: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return "" }
        let files = enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path < $1.path }
        var hasher = SHA256()
        for file in files {
            let relativePath = String(file.path.dropFirst(url.path.count))
            let fileSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let header = "\(relativePath.utf8.count):\(relativePath):\(fileSize):"
            hasher.update(data: Data(header.utf8))
            let handle = try FileHandle(forReadingFrom: file)
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            try handle.close()
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: value)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(
            domain: "LockscreenDah.RecognitionEvaluator",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

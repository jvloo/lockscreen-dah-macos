import Foundation
import XCTest
@testable import LockscreenDah

final class RecognitionModelTests: XCTestCase {
    private func sample(
        _ embedding: [Float],
        quality: Float? = nil,
        yaw: Float = 0,
        pitch: Float = 0.2
    ) -> EnrollmentSample {
        EnrollmentSample(
            embedding: embedding,
            yaw: yaw,
            pitch: pitch,
            captureQuality: quality
        )
    }

    func testPoseTemplatesDoNotAddACrossPoseMean() {
        let groups = [
            Array(repeating: sample([1, 0]), count: 4),
            Array(repeating: sample([0, 1]), count: 4),
            Array(repeating: sample([-1, 0]), count: 4),
            Array(repeating: sample([0, -1]), count: 4),
        ]

        let (templates, _) = FaceRecognizer.buildPoseTemplates(from: groups, dimensions: 2)

        XCTAssertEqual(templates.count, groups.count)
        XCTAssertEqual(templates[0], [1, 0])
        XCTAssertEqual(templates[1], [0, 1])
        XCTAssertEqual(templates[2], [-1, 0])
        XCTAssertEqual(templates[3], [0, -1])
    }

    func testPoseTemplateDropsOnlyTheLowestQualityCapture() {
        let group = [
            sample([1, 0], quality: 0.9),
            sample([1, 0], quality: 0.8),
            sample([1, 0], quality: 0.7),
            sample([0, 1], quality: 0.1),
        ]

        let (templates, _) = FaceRecognizer.buildPoseTemplates(from: [group], dimensions: 2)

        XCTAssertEqual(templates, [[1, 0]])
    }

    func testMissingCaptureQualityFailsOpenToAllSamples() {
        let group = [
            sample([1, 0], quality: 0.9),
            sample([1, 0], quality: 0.8),
            sample([1, 0], quality: 0.7),
            sample([0, 1]),
        ]

        let (templates, _) = FaceRecognizer.buildPoseTemplates(from: [group], dimensions: 2)

        XCTAssertGreaterThan(templates[0][1], 0)
    }

    func testTiedOrNonFiniteCaptureQualityDoesNotDiscardArbitrarily() {
        let tied = [
            sample([1, 0], quality: 0.5),
            sample([1, 0], quality: 0.5),
            sample([1, 0], quality: 0.5),
            sample([0, 1], quality: 0.5),
        ]
        let nonFinite = [
            sample([1, 0], quality: 0.9),
            sample([1, 0], quality: 0.8),
            sample([1, 0], quality: 0.7),
            sample([0, 1], quality: .nan),
        ]

        let (tiedTemplates, _) = FaceRecognizer.buildPoseTemplates(from: [tied], dimensions: 2)
        let (nonFiniteTemplates, _) = FaceRecognizer.buildPoseTemplates(
            from: [nonFinite], dimensions: 2
        )

        XCTAssertGreaterThan(tiedTemplates[0][1], 0)
        XCTAssertGreaterThan(nonFiniteTemplates[0][1], 0)
    }

    func testCaptureQualityIsMatchedByOverlapNotResultOrder() {
        let face = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        let quality = FaceCaptureQualityMatcher.quality(
            for: face,
            candidates: [
                (box: CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2), quality: 0.9),
                (box: CGRect(x: 0.11, y: 0.11, width: 0.29, height: 0.29), quality: 0.4),
            ]
        )

        XCTAssertEqual(quality, 0.4)
        XCTAssertNil(FaceCaptureQualityMatcher.quality(
            for: face,
            candidates: [(box: CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2), quality: 0.9)]
        ))
    }

    func testCandidateRequiresCompleteFinite512DimensionPoseGroups() throws {
        let recognizer = FaceRecognizer(modelURL: nil, profile: nil)
        let valid = [Float](repeating: 0, count: FaceRecognizer.embeddingDimensions - 1) + [1]
        let groups = (0..<4).map { _ in Array(repeating: sample(valid), count: 4) }

        let profile = try recognizer.makeCandidateProfile(poseSamples: groups)

        XCTAssertEqual(profile.version, FaceRecognizer.poseProfileVersion)
        XCTAssertEqual(profile.templates.count, 4)

        let wrongSize = Array(repeating: sample([1, 0]), count: 2)
        XCTAssertThrowsError(try recognizer.makeCandidateProfile(poseSamples: [wrongSize]))

        var nonFinite = valid
        nonFinite[0] = .nan
        XCTAssertThrowsError(try recognizer.makeCandidateProfile(
            poseSamples: [Array(repeating: sample(nonFinite), count: 2)]
        ))
    }

    func testCandidateRejectsOneInconsistentPoseDespiteThreeStrongPoses() {
        let recognizer = FaceRecognizer(modelURL: nil, profile: nil)
        func basis(_ index: Int, sign: Float = 1) -> [Float] {
            var vector = [Float](repeating: 0, count: FaceRecognizer.embeddingDimensions)
            vector[index] = sign
            return vector
        }
        let good = Array(repeating: sample(basis(0)), count: 4)
        let inconsistent = [
            sample(basis(1)), sample(basis(1, sign: -1)),
            sample(basis(2)), sample(basis(2, sign: -1)),
        ]

        XCTAssertThrowsError(try recognizer.makeCandidateProfile(
            poseSamples: [good, good, good, inconsistent]
        ))
    }

    func testRemovingOverallTemplateCannotRaiseMaxCosineSimilarity() {
        let recognizer = FaceRecognizer(modelURL: nil, profile: nil)
        let probe: [Float] = [1, 1]
        let poses: [[Float]] = [[1, 0], [0, 1]]
        let withOverall = FaceProfile(
            version: 2,
            createdAt: Date(),
            templates: [[1, 1]] + poses,
            baselinePitch: nil
        )
        let poseOnly = FaceProfile(
            version: FaceRecognizer.poseProfileVersion,
            createdAt: Date(),
            templates: poses,
            baselinePitch: nil
        )

        XCTAssertLessThanOrEqual(
            recognizer.similarity(of: probe, to: poseOnly),
            recognizer.similarity(of: probe, to: withOverall)
        )
    }

    func testEvaluatorParsesExplicitModelsAndThreshold() throws {
        let root = URL(fileURLWithPath: "/tmp/recognition-evaluator-tests")
        let options = try RecognitionEvaluator.parse(
            arguments: [
                "--manifest", "dataset.json",
                "--model", "mbf=models/FaceEmbedding.mlmodelc",
                "--model", "r50=/private/tmp/R50.mlmodelc",
                "--threshold", "0.5",
            ],
            currentDirectory: root
        )

        XCTAssertEqual(options.manifestURL.path, root.appendingPathComponent("dataset.json").path)
        XCTAssertEqual(options.models.map(\.name), ["mbf", "r50"])
        XCTAssertEqual(options.models[0].url.path, root.appendingPathComponent("models/FaceEmbedding.mlmodelc").path)
        XCTAssertEqual(options.models[1].url.path, "/private/tmp/R50.mlmodelc")
        XCTAssertEqual(options.threshold, 0.5)
    }

    func testEvaluatorRejectsImplicitOrDuplicateModelSelection() {
        let root = URL(fileURLWithPath: "/tmp")
        XCTAssertThrowsError(try RecognitionEvaluator.parse(
            arguments: ["--manifest", "dataset.json"],
            currentDirectory: root
        ))
        XCTAssertThrowsError(try RecognitionEvaluator.parse(
            arguments: [
                "--manifest", "dataset.json",
                "--model", "mbf=a.mlmodelc",
                "--model", "mbf=b.mlmodelc",
            ],
            currentDirectory: root
        ))
    }

    func testEvaluatorAggregateMetricsUseExplicitDenominators() {
        let outcomes = RecognitionEvaluator.summarizeOutcomes([
            (subject: "owner", expectedOwner: true, accepted: true),
            (subject: "owner", expectedOwner: true, accepted: false),
            (subject: "other-a", expectedOwner: false, accepted: true),
            (subject: "other-a", expectedOwner: false, accepted: false),
            (subject: "other-b", expectedOwner: false, accepted: false),
        ])
        XCTAssertEqual(outcomes.ownerProbes, 2)
        XCTAssertEqual(outcomes.otherProbes, 3)
        XCTAssertEqual(outcomes.trueAcceptRate, 0.5)
        XCTAssertEqual(outcomes.falseRejectRate, 0.5)
        XCTAssertEqual(outcomes.falseAcceptRate, 1.0 / 3.0)
        XCTAssertEqual(outcomes.otherSubjects, 2)
        XCTAssertEqual(outcomes.otherSubjectsEverAccepted, 1)
        XCTAssertEqual(outcomes.subjectFalseAcceptRate, 0.5)

        let latency = RecognitionEvaluator.summarizeLatencies([1, 2, 3, 4, 100])
        XCTAssertEqual(latency.p50Milliseconds, 3)
        XCTAssertEqual(latency.p95Milliseconds, 100)
        XCTAssertEqual(latency.p99Milliseconds, 100)

        let similarities = RecognitionEvaluator.summarizeSimilarities([0.1, 0.2, 0.3, 0.4, 0.9])
        XCTAssertEqual(similarities.median, 0.3)
        XCTAssertEqual(similarities.p95, 0.9)
    }

    func testEvaluatorAlternatesModelOrderPerFrame() {
        XCTAssertEqual(RecognitionEvaluator.alternatingIndices(count: 2, frame: 0), [0, 1])
        XCTAssertEqual(RecognitionEvaluator.alternatingIndices(count: 2, frame: 1), [1, 0])
        XCTAssertEqual(RecognitionEvaluator.alternatingIndices(count: 1, frame: 1), [0])
    }
}

import XCTest
@testable import LockscreenDah

/// The pose gates are the only part of enrollment that can silently refuse to
/// advance, and every bug in this flow so far has lived here — in a threshold
/// or in what a gate was allowed to look at. These drive the real stage list.
final class EnrollmentStagesTests: XCTestCase {
    /// Resting pitch on a laptop, where the camera sits above the screen.
    private static let restingPitch: Float = 0.2

    private func sample(yaw: Float, pitch: Float = restingPitch) -> EnrollmentSample {
        EnrollmentSample(embedding: [], yaw: yaw, pitch: pitch)
    }

    /// Feeds one held pose to a stage the way the controller does, and returns
    /// how many samples it accepted before giving up.
    private func collect(
        _ stage: EnrollmentStage,
        holding pose: EnrollmentSample,
        after completed: [[EnrollmentSample]],
        attempts: Int = 40
    ) -> [EnrollmentSample] {
        var accepted: [EnrollmentSample] = []
        for _ in 0..<attempts where accepted.count < stage.target {
            if stage.accepts(pose, completed) { accepted.append(pose) }
        }
        return accepted
    }

    /// Walks every stage with a pose that plainly satisfies it. A stage that
    /// stops accepting partway is the 50% stall: stage three used to average its
    /// own accepted samples into the reference direction, flipping the sign it
    /// was testing against after two captures.
    private func assertRunCompletes(
        straight: Float, firstTurn: Float, secondTurn: Float, down: Float,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var completed: [[EnrollmentSample]] = []
        let poses = [
            sample(yaw: straight),
            sample(yaw: firstTurn),
            sample(yaw: secondTurn),
            sample(yaw: straight, pitch: down),
        ]
        for (index, stage) in EnrollmentStages.all.enumerated() {
            let accepted = collect(stage, holding: poses[index], after: completed)
            XCTAssertEqual(
                accepted.count, stage.target,
                "stage \(index) (\(stage.instruction)) stalled at "
                    + "\(accepted.count * 100 / stage.target)% — \(stage.correction)",
                file: file, line: line
            )
            completed.append(accepted)
        }
    }

    func testRunCompletesTurningOneWayThenTheOther() {
        assertRunCompletes(straight: 0.05, firstTurn: -0.15, secondTurn: 0.18, down: 0.55)
    }

    /// The mirrored preview means "left" on screen need not match the sign of
    /// yaw, so the flow must work whichever way the user turns first.
    func testRunCompletesWithTheTurnsReversed() {
        assertRunCompletes(straight: 0.05, firstTurn: 0.15, secondTurn: -0.18, down: 0.55)
    }

    /// A gate must never see its own output. Holding one direction through the
    /// second turn stage has to be refused indefinitely — under the old flat
    /// sample list it was refused only until the running average drifted, at
    /// which point the *wrong* direction started being accepted.
    func testSecondTurnNeverAcceptsTheSameDirectionAsTheFirst() {
        let straight = (0..<4).map { _ in sample(yaw: 0.05) }
        let firstTurn = (0..<4).map { _ in sample(yaw: -0.15) }
        let stage = EnrollmentStages.all[2]
        let accepted = collect(stage, holding: sample(yaw: -0.18), after: [straight, firstTurn])
        XCTAssertTrue(accepted.isEmpty, "accepted \(accepted.count) samples of the first turn's direction")
    }

    /// The straight-ahead gate admits yaw well past `turnedYaw`, so stage one's
    /// samples must not vote on a turn direction they never demonstrated.
    func testSecondTurnIgnoresStraightAheadSamplesWhenChoosingDirection() {
        // Off-centre but still "straight", and enough of them to outweigh the
        // real turn if they were counted.
        let straight = (0..<4).map { _ in sample(yaw: 0.22) }
        let firstTurn = (0..<4).map { _ in sample(yaw: -0.12) }
        let stage = EnrollmentStages.all[2]
        let accepted = collect(stage, holding: sample(yaw: 0.18), after: [straight, firstTurn])
        XCTAssertEqual(accepted.count, stage.target, "the true opposite turn was rejected")
    }

    /// Tilt is judged against the user's own resting pose, because a laptop
    /// camera reads ~0.2 rad at rest while an external one at eye level reads ~0.
    func testHeadDownIsJudgedRelativeToRestingPitch() {
        let stage = EnrollmentStages.all[3]
        let turns = [[EnrollmentSample]](repeating: [], count: 2)

        let laptop = [(0..<4).map { _ in sample(yaw: 0.05, pitch: 0.2) }] + turns
        XCTAssertTrue(stage.accepts(sample(yaw: 0.05, pitch: 0.55), laptop))
        XCTAssertFalse(
            stage.accepts(sample(yaw: 0.05, pitch: 0.35), laptop),
            "a 0.15 rad dip from resting should not count as looking down"
        )

        // Same head movement, camera at eye level: still accepted.
        let external = [(0..<4).map { _ in sample(yaw: 0.05, pitch: 0.0) }] + turns
        XCTAssertTrue(stage.accepts(sample(yaw: 0.05, pitch: 0.35), external))
    }

    /// Without stage one there is no baseline, so tilt is unjudgeable and must
    /// fail closed rather than admit an unverified pose.
    func testHeadDownFailsClosedWithoutARestingBaseline() {
        XCTAssertFalse(EnrollmentStages.all[3].accepts(sample(yaw: 0, pitch: 0.9), []))
    }
}

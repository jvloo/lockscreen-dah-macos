import XCTest
@testable import LockscreenDah

/// The camera-liveness rule shipped a restart loop that locked the screen twice.
/// It lived inside the coordinator, where no test could construct it; these
/// exist so that can't recur silently.
final class CameraLivenessTests: XCTestCase {
    private let staleAfter: TimeInterval = 3
    private let startupAllowance: TimeInterval = 15
    private let firstAnalysisAllowance: TimeInterval = 25
    private let analysisStaleAfter: TimeInterval = 10
    private let requestedAt: TimeInterval = 1_000

    private func read(
        now: TimeInterval,
        streamingSince: TimeInterval? = nil,
        lastFrameAt: TimeInterval? = nil,
        lastResultAt: TimeInterval? = nil
    ) -> CameraLiveness.Reading {
        CameraLiveness.evaluate(
            now: now,
            requestedAt: requestedAt,
            streamingSince: streamingSince,
            lastFrameAt: lastFrameAt,
            lastResultAt: lastResultAt,
            staleAfter: staleAfter,
            startupAllowance: startupAllowance,
            firstAnalysisAllowance: firstAnalysisAllowance,
            analysisStaleAfter: analysisStaleAfter
        )
    }

    // MARK: - Opening the device (the shipped bug)

    /// Measured cold start on an M1 Pro built-in camera is ~7.7 s end to end.
    /// Against the 3 s mid-stream bar the app tore the session down before the
    /// system had even been asked to stream, then retried and did it again.
    func testACameraStillOpeningIsNotStaleAtFourSeconds() {
        let reading = read(now: requestedAt + 4)
        XCTAssertFalse(reading.isStale)
        XCTAssertEqual(reading.bar, startupAllowance, "opening must be judged against the startup allowance")
    }

    func testACameraStillOpeningIsNotStaleRightUpToTheAllowance() {
        XCTAssertFalse(read(now: requestedAt + startupAllowance).isStale)
    }

    /// Bounded, not unlimited: a device that never comes up must still be caught.
    func testACameraThatNeverStartsIsEventuallyStale() {
        XCTAssertTrue(read(now: requestedAt + startupAllowance + 0.1).isStale)
    }

    // MARK: - Streaming

    func testAStreamingCameraIsStaleAfterAFrameGap() {
        let streaming = requestedAt + 8
        // Last frame 3.5 s ago — past the bar, not merely at it. The boundary
        // itself is pinned separately by testAGapExactlyAtTheBarIsNotStale.
        let reading = read(now: streaming + 4, streamingSince: streaming, lastFrameAt: streaming + 0.5)
        XCTAssertTrue(reading.isStale)
        XCTAssertEqual(reading.gap, 3.5, accuracy: 0.001)
        XCTAssertEqual(reading.bar, staleAfter, "streaming must be judged against the frame-gap bar")
    }

    func testAStreamingCameraDeliveringFramesIsNotStale() {
        let streaming = requestedAt + 8
        XCTAssertFalse(read(now: streaming + 2, streamingSince: streaming, lastFrameAt: streaming + 1.5).isStale)
    }

    /// A session that has started but not yet delivered gets its gap measured
    /// from when streaming began — never from when it was *requested*, or the
    /// device-open time would be charged to the frame gap and the session would
    /// be torn down the moment it came up.
    func testStreamingWithNoFrameYetMeasuresFromWhenStreamingBegan() {
        let streaming = requestedAt + 10
        XCTAssertFalse(read(now: streaming + 2, streamingSince: streaming).isStale)
        XCTAssertTrue(read(now: streaming + 4, streamingSince: streaming).isStale)
    }

    /// The regression that made the loop inescapable: a stale `lastFrameAt` left
    /// over from the *previous* session is always older than any bar, so every
    /// fresh session looked dead on its first supervisor tick. Measured in the
    /// field as 8 of 10 teardowns reporting a frame gap larger than the session
    /// had existed — arithmetically impossible otherwise.
    ///
    /// The fix is that the monitor clears it synchronously on start, so this
    /// asserts the rule *given* a correctly cleared value: a brand-new session
    /// with no frames is judged as opening, not as stalled.
    func testAFreshSessionIsNeverJudgedOnAPreviousSessionsClock() {
        let reading = read(now: requestedAt + 1, streamingSince: nil, lastFrameAt: nil)
        XCTAssertFalse(reading.isStale, "a session one second old must never read as stalled")
        XCTAssertEqual(reading.gap, 1, accuracy: 0.001)
    }

    // MARK: - Boundaries

    /// Strictly greater, matching the supervisor's own comparison, so a gap
    /// exactly at the bar is not yet stale.
    func testAGapExactlyAtTheBarIsNotStale() {
        let streaming = requestedAt + 5
        XCTAssertFalse(read(now: streaming + staleAfter, streamingSince: streaming, lastFrameAt: streaming).isStale)
    }

    // MARK: - Analysis stalling while the camera looks healthy
    //
    // Two paths in the capture callback return without ever producing a result —
    // an unusable pixel buffer, and Vision's perform throwing. Frames keep
    // arriving through both, so the camera reads healthy while nothing is
    // looking at them. Presence then stops advancing, the grace period expires,
    // and the screen locks on absence that was never observed.

    func testFramesArrivingButAnalysisStalledIsStale() {
        let streaming = requestedAt + 5
        let reading = read(
            now: streaming + 30,
            streamingSince: streaming,
            lastFrameAt: streaming + 29.9,   // camera perfectly healthy
            lastResultAt: streaming + 5      // nothing analysed for 25s
        )
        XCTAssertTrue(reading.isStale)
        XCTAssertEqual(reading.stall, .analysis, "must be attributed to analysis, not the camera")
        XCTAssertEqual(reading.bar, analysisStaleAfter)
    }

    /// Results are throttled by design — up to 2.5 s at the idle cadence — so a
    /// slow cadence must never read as a stall.
    func testASlowButHealthyCadenceIsNotAStall() {
        let streaming = requestedAt + 5
        let reading = read(
            now: streaming + 30,
            streamingSince: streaming,
            lastFrameAt: streaming + 29.9,
            lastResultAt: streaming + 21     // 9s ago, inside the 10s bar
        )
        XCTAssertFalse(reading.isStale)
        XCTAssertEqual(reading.stall, .none)
    }

    /// Before the first result there is nothing to judge yet: model load and
    /// warm-up get a separate allowance from the steady-state cadence.
    func testNoResultYetIsNotAnAnalysisStall() {
        let streaming = requestedAt + 5
        let reading = read(now: streaming + 2, streamingSince: streaming, lastFrameAt: streaming + 1.9)
        XCTAssertFalse(reading.isStale)
    }

    /// And it must stay true for a *long* first inference. The worst observed
    /// first result under contention was 19.85 s with frames flowing throughout.
    /// Measuring that against the analysis bar would tear the camera down before
    /// recognition had ever answered — the same cold-start mistake that caused
    /// the restart loop, arriving by a different route.
    func testALongFirstInferenceIsNotAnAnalysisStall() {
        let streaming = requestedAt + 5
        let reading = read(
            now: streaming + 20,
            streamingSince: streaming,
            lastFrameAt: streaming + 19.9,
            lastResultAt: nil
        )
        XCTAssertFalse(reading.isStale, "a long first inference is not a stalled pipeline")
    }

    func testNoFirstResultIsNotStaleAtTheAllowanceBoundary() {
        let streaming = requestedAt + 5
        let reading = read(
            now: requestedAt + firstAnalysisAllowance,
            streamingSince: streaming,
            lastFrameAt: requestedAt + firstAnalysisAllowance - 0.1,
            lastResultAt: nil
        )
        XCTAssertFalse(reading.isStale, "the first-result boundary is inclusive")
        XCTAssertEqual(reading.stall, .none)
        XCTAssertEqual(reading.bar, firstAnalysisAllowance)
    }

    func testFramesWithNoFirstResultEventuallyBecomeAnAnalysisStall() {
        let streaming = requestedAt + 5
        let reading = read(
            now: requestedAt + firstAnalysisAllowance + 0.1,
            streamingSince: streaming,
            lastFrameAt: requestedAt + firstAnalysisAllowance,
            lastResultAt: nil
        )
        XCTAssertTrue(reading.isStale)
        XCTAssertEqual(reading.stall, .analysis)
        XCTAssertEqual(reading.bar, firstAnalysisAllowance)
        XCTAssertEqual(reading.gap, firstAnalysisAllowance + 0.1, accuracy: 0.001)
    }

    func testBlindTimeDoesNotTurnIntoProvenAbsence() {
        let reading = CameraLiveness.Reading(gap: 10, bar: 3, stall: .analysis)
        XCTAssertFalse(reading.absenceWasProven(now: 30, graceAnchor: 19, gracePeriod: 3))
    }

    func testAbsenceProvenBeforeTheStallRemainsEvidence() {
        let reading = CameraLiveness.Reading(gap: 10, bar: 3, stall: .analysis)
        XCTAssertTrue(reading.absenceWasProven(now: 30, graceAnchor: 16, gracePeriod: 3))
    }

    /// A dead camera is reported as a dead camera even if analysis is also
    /// quiet — otherwise the remedy would chase the wrong stage.
    func testFrameStallTakesPrecedenceOverAnalysisStall() {
        let streaming = requestedAt + 5
        let reading = read(
            now: streaming + 60,
            streamingSince: streaming,
            lastFrameAt: streaming + 1,
            lastResultAt: streaming + 1
        )
        XCTAssertEqual(reading.stall, .frames)
        XCTAssertEqual(reading.bar, staleAfter)
    }

    func testAnalysisStallBoundaryIsStrictlyGreater() {
        let streaming = requestedAt + 5
        let reading = read(
            now: streaming + 30,
            streamingSince: streaming,
            lastFrameAt: streaming + 29.9,
            lastResultAt: streaming + 20     // exactly 10s
        )
        XCTAssertFalse(reading.isStale, "a gap exactly at the bar is not yet a stall")
    }
}

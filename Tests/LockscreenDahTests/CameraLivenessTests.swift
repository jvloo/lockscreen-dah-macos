import XCTest
@testable import LockscreenDah

/// The camera-liveness rule shipped a restart loop that locked the screen twice.
/// It lived inside the coordinator, where no test could construct it; these
/// exist so that can't recur silently.
final class CameraLivenessTests: XCTestCase {
    private let staleAfter: TimeInterval = 3
    private let startupAllowance: TimeInterval = 15
    private let requestedAt: TimeInterval = 1_000

    private func read(
        now: TimeInterval,
        streamingSince: TimeInterval? = nil,
        lastFrameAt: TimeInterval? = nil
    ) -> CameraLiveness.Reading {
        CameraLiveness.evaluate(
            now: now,
            requestedAt: requestedAt,
            streamingSince: streamingSince,
            lastFrameAt: lastFrameAt,
            staleAfter: staleAfter,
            startupAllowance: startupAllowance
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
}

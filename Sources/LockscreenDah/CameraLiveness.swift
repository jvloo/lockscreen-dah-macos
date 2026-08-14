import Foundation

/// Answers "has the capture pipeline stopped delivering?" — as a gap and the bar
/// that gap should be judged against.
///
/// Pure and free of AVFoundation so it can be driven from a test, which is the
/// whole point: this rule was previously three lines inside a coordinator no test
/// could construct, and it shipped a restart loop that locked the screen.
///
/// The two cases are genuinely different questions and must not share a bar:
///
/// * **Opening the device.** No frame gap exists yet, only elapsed time. Opening
///   is slow — measured on an M1 Pro built-in camera at ~3.7 s of session
///   configuration plus 4.03 s from the daemon being asked to stream to frames
///   actually flowing, with a worst observed first result of 19.85 s under
///   contention. Judged against the 3 s mid-stream bar, the app declared the
///   camera dead *before the system had even been asked to stream*, tore it
///   down, retried, and did the same thing again.
/// * **Streaming.** Frames arrive at the sensor's own rate regardless of how
///   coarse the analysis throttle is, so here a gap really is unambiguous.
enum CameraLiveness {
    struct Reading: Equatable {
        /// Seconds to judge — a frame gap while streaming, elapsed time while opening.
        let gap: TimeInterval
        /// The bar this particular gap should be compared against.
        let bar: TimeInterval

        var isStale: Bool { gap > bar }
    }

    /// - Parameters:
    ///   - requestedAt: when the coordinator asked the camera to start.
    ///   - streamingSince: when the session actually began streaming, or nil
    ///     while it is still opening the device. Nil means "no opinion yet", not
    ///     "stalled" — reading it as the latter is what produced the loop.
    ///   - lastFrameAt: the most recent delivered frame, or nil if none yet *for
    ///     this session*. It must be cleared when a session stops: a previous
    ///     session's timestamp is already older than any bar, so leaving it set
    ///     made every fresh session look stale on its first tick.
    static func evaluate(
        now: TimeInterval,
        requestedAt: TimeInterval,
        streamingSince: TimeInterval?,
        lastFrameAt: TimeInterval?,
        staleAfter: TimeInterval,
        startupAllowance: TimeInterval
    ) -> Reading {
        guard let streamingSince else {
            // Bounded rather than unlimited, so a device that never comes up is
            // still caught — just not before it has had a fair chance.
            return Reading(gap: now - requestedAt, bar: startupAllowance)
        }
        // Falls back to when streaming began rather than when it was requested,
        // so the device-open time is never counted as a frame gap.
        return Reading(gap: now - (lastFrameAt ?? streamingSince), bar: staleAfter)
    }
}

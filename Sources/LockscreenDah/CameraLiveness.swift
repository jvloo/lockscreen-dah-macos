import Foundation

/// Answers "has the detection pipeline stopped?" — as a gap, the bar that gap
/// should be judged against, and which stage stalled.
///
/// Pure and free of AVFoundation so it can be driven from a test, which is the
/// whole point: this rule was previously three lines inside a coordinator no test
/// could construct, and it shipped a restart loop that locked the screen.
///
/// Three genuinely different questions, which must not share a bar:
///
/// * **Opening the device.** No frame gap exists yet, only elapsed time. Opening
///   is slow — measured on an M1 Pro built-in camera at ~3.7 s of session
///   configuration plus 4.03 s from the daemon being asked to stream to frames
///   actually flowing, with a worst observed first result of 19.85 s under
///   contention. Judged against the mid-stream bar, the app declared the camera
///   dead *before the system had even been asked to stream*, tore it down,
///   retried, and did the same thing again.
/// * **Streaming.** Frames arrive at the sensor's own rate regardless of how
///   coarse the analysis throttle is, so here a gap really is unambiguous.
/// * **Analysing.** Frames arriving proves the *camera* is alive; it proves
///   nothing about whether anything is looking at them. Vision can throw on every
///   frame, or the buffer can be unusable, and both paths return without ever
///   producing a result. The camera then reports healthy while the app is blind —
///   and because presence stops advancing, the grace period expires and the
///   screen locks on absence that was never observed. That inverts the app's own
///   rule that absence measured while blind is not evidence: the rule was right,
///   but "blind" only ever covered *seeing*, never *thinking*.
enum CameraLiveness {
    /// Which stage stopped, so the remedy and the log can say which.
    enum Stall: Equatable {
        case none
        /// The camera is not delivering frames.
        case frames
        /// Frames are arriving but nothing is analysing them.
        case analysis
    }

    struct Reading: Equatable {
        /// Seconds to judge — a frame gap while streaming, elapsed time while
        /// opening, or a result gap when analysis has stalled.
        let gap: TimeInterval
        /// The bar this particular gap should be compared against.
        let bar: TimeInterval
        let stall: Stall

        var isStale: Bool { stall != .none }

        /// Whether the absence deadline had already passed before this pipeline
        /// went blind. Time after the stall is not evidence and must never turn
        /// a recovery into a lock.
        func absenceWasProven(
            now: TimeInterval,
            graceAnchor: TimeInterval,
            gracePeriod: TimeInterval
        ) -> Bool {
            let stallBeganAt = now - gap
            return graceAnchor + gracePeriod <= stallBeganAt
        }
    }

    /// - Parameters:
    ///   - requestedAt: when the coordinator asked the camera to start.
    ///   - streamingSince: when the session actually began streaming, or nil
    ///     while it is still opening the device. Nil means "no opinion yet", not
    ///     "stalled" — reading it as the latter is what produced the restart loop.
    ///   - lastFrameAt: the most recent delivered frame, or nil if none yet *for
    ///     this session*. Must be cleared when a session stops: a previous
    ///     session's timestamp is already older than any bar, so leaving it set
    ///     made every fresh session look stale on its first tick.
    ///   - lastResultAt: the most recent *analysis result*, or nil if none has
    ///     been produced yet. First inference carries model load, so nil gets a
    ///     separate, generous allowance rather than the steady-state result bar.
    ///     It must still be bounded: frames with no result forever are a blind
    ///     pipeline, not a healthy camera.
    ///   - firstAnalysisAllowance: maximum elapsed time from the original start
    ///     request to the first result.
    ///   - analysisStaleAfter: must comfortably exceed the analysis interval,
    ///     since results are throttled by design and a slow cadence is not a
    ///     stall.
    static func evaluate(
        now: TimeInterval,
        requestedAt: TimeInterval,
        streamingSince: TimeInterval?,
        lastFrameAt: TimeInterval?,
        lastResultAt: TimeInterval?,
        staleAfter: TimeInterval,
        startupAllowance: TimeInterval,
        firstAnalysisAllowance: TimeInterval,
        analysisStaleAfter: TimeInterval
    ) -> Reading {
        guard let streamingSince else {
            // Bounded rather than unlimited, so a device that never comes up is
            // still caught — just not before it has had a fair chance.
            let elapsed = now - requestedAt
            return Reading(
                gap: elapsed,
                bar: startupAllowance,
                stall: elapsed > startupAllowance ? .frames : .none
            )
        }

        // Falls back to when streaming began rather than when it was requested,
        // so the device-open time is never counted as a frame gap.
        let frameGap = now - (lastFrameAt ?? streamingSince)
        if frameGap > staleAfter {
            return Reading(gap: frameGap, bar: staleAfter, stall: .frames)
        }

        // Frames are fine. Is anything looking at them? First inference gets its
        // own allowance because model/ANE warm-up is much slower than the normal
        // cadence. Measure from the original request so the bound covers the
        // whole blind startup, not an unbounded device-open phase plus inference.
        guard let lastResultAt else {
            let elapsed = now - requestedAt
            return Reading(
                gap: elapsed,
                bar: firstAnalysisAllowance,
                stall: elapsed > firstAnalysisAllowance ? .analysis : .none
            )
        }

        let resultGap = now - lastResultAt
        if resultGap > analysisStaleAfter {
            return Reading(gap: resultGap, bar: analysisStaleAfter, stall: .analysis)
        }

        return Reading(gap: frameGap, bar: staleAfter, stall: .none)
    }
}

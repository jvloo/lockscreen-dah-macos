import Foundation

/// The coordinator's state, without the payloads the decision doesn't depend on.
enum SupervisedState: Equatable {
    case paused
    case watching
    case alerting
    case locked
    case enrolling
    case cameraUnavailable
}

/// Everything the supervisor is allowed to reason from — all of it read from
/// the system at the moment of the decision, never remembered from an event.
/// That restriction is the point: every stranded-camera bug in this app came
/// from trusting a notification that turned out not to arrive.
struct SystemConditions: Equatable {
    var sessionLocked: Bool
    var displayAsleep: Bool
    /// Since the last delivered camera frame. Frames are the liveness signal
    /// rather than `AVCaptureSession.isRunning`, which reads false while the
    /// session configures and true while a wedged driver delivers nothing.
    var secondsSinceLastFrame: TimeInterval
    /// Since presence was last confirmed — the same anchor the grace deadline
    /// is measured from.
    var secondsSinceOwnerSeen: TimeInterval
}

enum SupervisionDecision: Equatable {
    case doNothing
    /// Screen is usable again — re-decide what regime we should be in.
    case resumeFromLocked
    /// Stop watching and park. Does *not* lock: the screen is already locked,
    /// or is dark with no proven absence behind it.
    case enterLocked
    /// The capture pipeline has stopped delivering; hand off to the recovery
    /// path, which owns the retry ladder and the lock-safety rules.
    case cameraStopped
    /// Lock the screen now.
    case lockNow
}

/// Decides what the app should be doing, from conditions alone.
///
/// Pure and total: every state has an answer, so no situation can fall through
/// to "whatever we happened to be doing". Both the 1 Hz supervisor and the
/// lock/sleep notifications route through this, which is what stops them
/// drifting apart — the notifications are now a prompt to re-decide rather than
/// separate logic that has to stay in agreement.
enum PresenceSupervisor {
    static func decide(
        state: SupervisedState,
        conditions: SystemConditions,
        gracePeriod: TimeInterval,
        staleAfter: TimeInterval
    ) -> SupervisionDecision {
        switch state {
        case .paused, .enrolling:
            // Deliberately idle, or the enrollment controller owns the camera.
            return .doNothing

        case .cameraUnavailable:
            // Its retry ladder owns restarts. Re-starting once a second would
            // hammer a device that is already failing.
            return .doNothing

        case .locked:
            // Entered for two unrelated reasons — the session locked, or the
            // display slept without locking — and only the first is undone by
            // an unlock. Treating a sleeping display as a missed unlock is what
            // restarted the camera behind a dark screen in 1.4.0.
            let screenIsUsable = !conditions.sessionLocked && !conditions.displayAsleep
            return screenIsUsable ? .resumeFromLocked : .doNothing

        case .watching, .alerting:
            if conditions.sessionLocked { return .enterLocked }
            if conditions.displayAsleep {
                // A dark screen is not the owner coming back. Absence proven
                // *before* it went dark is evidence gathered while we could
                // still see, so it locks — the same rule the blind-camera path
                // uses. Otherwise park without locking: a sleeping display on
                // its own proves nothing.
                return conditions.secondsSinceOwnerSeen >= gracePeriod ? .lockNow : .enterLocked
            }
            return conditions.secondsSinceLastFrame > staleAfter ? .cameraStopped : .doNothing
        }
    }
}

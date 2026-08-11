import Foundation

/// Everything the camera-rest decision depends on, gathered as plain values.
/// Nothing here reads a global or touches AVFoundation, which is what makes the
/// decision testable — it previously lived inline in a tick handler that needed
/// a camera, a run loop and the user's real settings to execute at all.
struct CameraRestInputs {
    var now: TimeInterval
    var secondsSinceInput: TimeInterval
    /// True while the capture session is stopped.
    var isResting: Bool
    /// When the current rest began; nil when awake.
    var restStartedAt: TimeInterval?
    /// When input first became continuous; nil when it has lapsed.
    var inputActiveSince: TimeInterval?
    var lastCameraWake: TimeInterval
    /// Identity must already be established — input can maintain presence, never
    /// create it.
    var chainActive: Bool

    /// Sustained input required before resting. 0 means "Never Idle".
    var restAfter: TimeInterval
    /// Input silence that ends a rest.
    var wakeQuiet: TimeInterval
    /// Minimum awake time between rests, so bursty typing can't thrash the
    /// session (each stop/start costs a device open and auto-exposure re-run).
    var minimumAwake: TimeInterval
    /// Absolute ceiling on one rest; 0 disables the cap.
    var maximumRest: TimeInterval
    /// False when the countdown delay is too short for a woken camera to land a
    /// match before it expires.
    var restAvailable: Bool
}

/// What the coordinator should do about the camera this tick.
enum CameraRestDecision: Equatable {
    /// Stay asleep; input is standing in for presence.
    case keepResting
    /// Wake the session. `peeking` means input never stopped — this is a
    /// scheduled identity re-check, so a match should return straight to rest
    /// rather than serving the full awake minimum.
    case wake(peeking: Bool)
    /// Stop the session; presence passes to input.
    case beginResting
    /// Camera stays as it is.
    case none
}

/// The rest/wake half of the presence loop, as a pure function.
///
/// Kept separate from the coordinator because the interesting cases — a rest
/// that outlives its ceiling, a wake caused by a live settings change, the
/// interaction between the awake minimum and the ceiling — are all
/// arithmetic, and arithmetic deserves tests rather than a manual checklist.
enum CameraRestPolicy {
    static func decide(_ input: CameraRestInputs) -> CameraRestDecision {
        input.isResting ? decideWhileResting(input) : decideWhileAwake(input)
    }

    private static func decideWhileResting(_ input: CameraRestInputs) -> CameraRestDecision {
        // Every condition that permitted the rest is re-checked, not just the
        // one that started it: switching to "Never Idle", or shortening the
        // countdown delay below the minimum, must end the rest now rather than
        // merely blocking the next one.
        let restedFor = input.now - (input.restStartedAt ?? input.now)
        let hitCeiling = input.maximumRest > 0 && restedFor >= input.maximumRest
        let stillIdling = input.secondsSinceInput < input.wakeQuiet
            && input.restAfter > 0
            && input.restAvailable
            && !hitCeiling
        if stillIdling { return .keepResting }
        // A ceiling-triggered wake is the only one where input never stopped, so
        // it's the only one that counts as a peek.
        return .wake(peeking: hitCeiling)
    }

    private static func decideWhileAwake(_ input: CameraRestInputs) -> CameraRestDecision {
        guard let activeSince = input.inputActiveSince,
              input.chainActive,
              input.restAfter > 0, // "Never Idle"
              input.restAvailable,
              input.now - activeSince >= input.restAfter,
              input.now - input.lastCameraWake >= input.minimumAwake
        else { return .none }
        return .beginResting
    }

    /// Tracks how long input has been continuous. Returns the updated value:
    /// the first moment of the current unbroken run, or nil once it lapses.
    static func inputActiveSince(_ input: CameraRestInputs) -> TimeInterval? {
        input.secondsSinceInput < input.wakeQuiet ? (input.inputActiveSince ?? input.now) : nil
    }
}

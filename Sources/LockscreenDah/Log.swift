import Foundation
import os

/// Unified-logging channels for the app.
///
/// Every camera outage reported so far — a failure path that paused for the
/// day, a retry ladder that gave up, a missed unlock notification, a supervisor
/// that restarted the camera behind a sleeping display — was diagnosed by
/// reading source and guessing, because the app recorded nothing. Each took a
/// hunt that a single line of history would have made a glance.
///
/// Unified logging is used rather than a file: nothing to rotate or clean up,
/// it survives a crash, and it is off the disk unless someone asks for it.
///
/// **What is deliberately never logged:** anything derived from a face. No
/// embeddings, no landmarks, no images. Recognition logs a similarity score
/// only at `.debug`, which is not captured unless explicitly requested — a
/// score is not identifying on its own, but it is biometric-adjacent and should
/// not sit in a default capture.
///
/// Read the last hour with:
/// ```sh
/// log show --last 1h --predicate 'subsystem == "com.xavierloo.lockscreen-dah"' --style compact
/// # add --debug for recognition scores
/// ```
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier
        ?? "com.xavierloo.lockscreen-dah"

    /// State machine transitions — the spine of any investigation.
    static let state = Logger(subsystem: subsystem, category: "state")
    /// Capture session lifecycle, staleness, failures and retries.
    static let camera = Logger(subsystem: subsystem, category: "camera")
    /// Active Hours/Days resolution and manual overrides.
    static let schedule = Logger(subsystem: subsystem, category: "schedule")
    /// Locking, and the identity checks around it.
    static let lock = Logger(subsystem: subsystem, category: "lock")
    /// Enrollment and matching. Scores are `.debug` only — see above.
    static let recognition = Logger(subsystem: subsystem, category: "recognition")
}

extension MonitorCoordinator.State {
    /// Stable, non-identifying names for logs. Spelled out rather than derived
    /// from `String(describing:)` so a rename can't silently change log output
    /// that someone is grepping months later.
    var logName: String {
        switch self {
        case .paused: return "paused"
        case .watching: return "watching"
        case .alerting: return "alerting"
        case .locked: return "locked"
        case .enrolling: return "enrolling"
        case .cameraUnavailable: return "cameraUnavailable"
        }
    }
}

import Foundation

/// The seat-continuity presence chain, kept as a pure value type so the core
/// decision logic is testable without AppKit or a camera.
///
/// Identity is *established* by a positive owner match and then *maintained* —
/// with no time cap — by seat continuity: a face at any angle, or a detected
/// upper body (head turned to another screen). The chain breaks when a
/// clearly frontal stranger face is seen for several consecutive frames, or
/// when the coordinator fires a countdown (cancelling it requires a fresh
/// identity match).
struct PresenceTracker {
    private(set) var chainActive = false
    private var strangerStreak = 0
    /// Monotonic instant presence was last confirmed — the anchor a grace
    /// deadline is computed from. Exposed so the coordinator can schedule a
    /// precise one-shot timer against it instead of polling.
    private(set) var lastOwnerSeen: TimeInterval

    /// Consecutive clear-stranger frames that end the chain.
    private let strangerStreakLimit: Int
    /// When a judgeable face first failed to confirm the owner, cleared by any
    /// confident match.
    private var unconfirmedSince: TimeInterval?
    /// How long a judgeable-but-unmatched face may sustain presence.
    ///
    /// This is what stops an ambiguous intruder holding the screen forever.
    /// Confidence sets the speed: a face the model is *sure* about ends the chain
    /// in three frames, while one it is unsure about gets this window to become
    /// certain either way. It deliberately does **not** apply to turned-away
    /// faces or a torso — those are unjudgeable, and capping them would lock out
    /// an owner working at a second screen.
    private let unconfirmedLimit: TimeInterval

    init(
        now: TimeInterval = Uptime.now,
        strangerStreakLimit: Int = 3,
        unconfirmedLimit: TimeInterval = 5
    ) {
        lastOwnerSeen = now
        self.strangerStreakLimit = strangerStreakLimit
        self.unconfirmedLimit = unconfirmedLimit
    }

    /// Fresh start (monitoring begins): no chain until the owner is matched.
    mutating func reset(now: TimeInterval = Uptime.now) {
        chainActive = false
        strangerStreak = 0
        unconfirmedSince = nil
        lastOwnerSeen = now
    }

    /// Owner positively matched — (re)establish the chain.
    mutating func establish(now: TimeInterval = Uptime.now) {
        chainActive = true
        strangerStreak = 0
        unconfirmedSince = nil // identity just confirmed
        lastOwnerSeen = now
    }

    /// The countdown is the identity gate: whoever wants the screen to stay
    /// open must positively match — coasting on the old chain won't do.
    mutating func breakChain() {
        chainActive = false
    }

    /// Restarts the grace period without re-establishing identity (Esc cancel).
    mutating func touch(now: TimeInterval = Uptime.now) {
        lastOwnerSeen = now
    }

    /// Folds one detection into the chain. Returns true when the owner was
    /// positively matched.
    @discardableResult
    mutating func observe(_ result: DetectionResult, now: TimeInterval = Uptime.now) -> Bool {
        if result.ownerMatched {
            establish(now: now)
            return true
        }

        // A clearly frontal stranger face for several consecutive frames ends
        // the chain even if they keep the seat warm.
        strangerStreak = result.strangerSeen ? strangerStreak + 1 : 0
        if strangerStreak >= strangerStreakLimit {
            chainActive = false
        }

        // A judgeable face that couldn't confirm the owner starts a clock. The
        // model could see it and still didn't recognise it, which is weak
        // evidence — enough to bound, not enough to accuse.
        if result.frontalButUnmatched {
            unconfirmedSince = unconfirmedSince ?? now
        }
        let unconfirmedTooLong = unconfirmedSince.map { now - $0 > unconfirmedLimit } ?? false

        // Seat continuity: a face at any angle, or an upper body, keeps an
        // established chain alive — indefinitely, so working turned toward a
        // second screen never nags. Two things break it: a face just flagged a
        // confident stranger (which doesn't get to buy itself time), and a
        // judgeable face that has failed to confirm for too long. Without the
        // second, an intruder scoring between the two thresholds would hold the
        // screen open forever.
        if chainActive, !unconfirmedTooLong,
           (result.faceCount > 0 && !result.strangerSeen) || result.bodyCount > 0 {
            lastOwnerSeen = now
        }
        return false
    }
}

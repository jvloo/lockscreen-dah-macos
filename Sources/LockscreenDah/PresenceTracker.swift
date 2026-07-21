import Foundation

/// The seat-continuity presence chain, kept as a pure value type so the core
/// decision logic is testable without AppKit or a camera.
///
/// Identity is *established* by a positive owner match and then *maintained* —
/// with no time cap — by seat continuity: a face at any angle, a detected
/// upper body (head turned to another screen), or active keyboard/mouse
/// input. The chain breaks when a clearly frontal stranger face is seen for
/// several consecutive frames, or when the coordinator fires a countdown
/// (cancelling it requires a fresh identity match).
struct PresenceTracker {
    private(set) var chainActive = false
    private var strangerStreak = 0
    private var lastOwnerSeen: Date

    /// Consecutive clear-stranger frames that end the chain.
    private let strangerStreakLimit: Int
    /// Input newer than this counts as "someone is actively using the Mac".
    private let inputRecency: TimeInterval

    init(now: Date = Date(), strangerStreakLimit: Int = 3, inputRecency: TimeInterval = 2) {
        lastOwnerSeen = now
        self.strangerStreakLimit = strangerStreakLimit
        self.inputRecency = inputRecency
    }

    /// Fresh start (monitoring begins): no chain until the owner is matched.
    mutating func reset(now: Date = Date()) {
        chainActive = false
        strangerStreak = 0
        lastOwnerSeen = now
    }

    /// Owner positively matched — (re)establish the chain.
    mutating func establish(now: Date = Date()) {
        chainActive = true
        strangerStreak = 0
        lastOwnerSeen = now
    }

    /// The countdown is the identity gate: whoever wants the screen to stay
    /// open must positively match — coasting on the old chain won't do.
    mutating func breakChain() {
        chainActive = false
    }

    /// Restarts the grace period without re-establishing identity (Esc cancel).
    mutating func touch(now: Date = Date()) {
        lastOwnerSeen = now
    }

    /// Folds one detection into the chain. Returns true when the owner was
    /// positively matched.
    @discardableResult
    mutating func observe(
        _ result: DetectionResult,
        secondsSinceInput: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        if result.ownerMatched {
            establish(now: now)
            return true
        }

        // A clearly frontal stranger face for several consecutive frames ends
        // the chain even if they keep the seat warm and keep typing.
        strangerStreak = result.strangerSeen ? strangerStreak + 1 : 0
        if strangerStreak >= strangerStreakLimit {
            chainActive = false
        }

        // Seat continuity: face at any angle, upper body, or live input keeps
        // an established chain alive. If everything goes quiet the grace
        // period runs out and the countdown becomes the identity gate — so an
        // unbroken chain can't outlive an empty seat by more than the grace
        // period.
        if chainActive,
           result.faceCount > 0 || result.bodyCount > 0 || secondsSinceInput < inputRecency {
            lastOwnerSeen = now
        }
        return false
    }

    /// Seconds since presence was last confirmed.
    func absence(now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(lastOwnerSeen)
    }
}

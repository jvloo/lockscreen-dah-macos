import XCTest
@testable import LockscreenDah

/// The seat-continuity chain is where every presence bug this project has had
/// actually lived, and it's a pure value type — so it gets real coverage.
/// Each test names the behaviour it pins down rather than the method it calls.
final class PresenceTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func result(
        faces: Int = 0,
        bodies: Int = 0,
        owner: Bool = false,
        stranger: Bool = false
    ) -> DetectionResult {
        DetectionResult(
            faceCount: faces,
            bodyCount: bodies,
            ownerMatched: owner,
            strangerSeen: stranger,
            capturedAt: t0
        )
    }

    // MARK: - Establishing identity

    func testChainStartsInactiveAndAFaceAloneCannotEstablishIt() {
        var tracker = PresenceTracker(now: t0)
        XCTAssertFalse(tracker.chainActive)

        // A face with no owner match must not create identity, only maintain it.
        tracker.observe(result(faces: 1), now: t0.addingTimeInterval(1))
        XCTAssertFalse(tracker.chainActive)
        XCTAssertEqual(tracker.lastOwnerSeen, t0, "an unmatched face must not refresh presence before identity exists")
    }

    func testOwnerMatchEstablishesChainAndStampsPresence() {
        var tracker = PresenceTracker(now: t0)
        let seen = t0.addingTimeInterval(5)

        XCTAssertTrue(tracker.observe(result(faces: 1, owner: true), now: seen))
        XCTAssertTrue(tracker.chainActive)
        XCTAssertEqual(tracker.lastOwnerSeen, seen)
    }

    // MARK: - Seat continuity

    func testAmbiguousFaceMaintainsAnEstablishedChain() {
        var tracker = PresenceTracker(now: t0)
        tracker.establish(now: t0)

        // Turned head: detected, but too oblique to judge either way.
        let later = t0.addingTimeInterval(2)
        tracker.observe(result(faces: 1), now: later)
        XCTAssertEqual(tracker.lastOwnerSeen, later, "a face at an unjudgeable angle should hold the seat")
    }

    func testBodyAloneMaintainsAnEstablishedChain() {
        var tracker = PresenceTracker(now: t0)
        tracker.establish(now: t0)

        let later = t0.addingTimeInterval(2)
        tracker.observe(result(bodies: 1), now: later)
        XCTAssertEqual(tracker.lastOwnerSeen, later)
    }

    func testEmptyFrameDoesNotMaintainTheChain() {
        var tracker = PresenceTracker(now: t0)
        tracker.establish(now: t0)

        tracker.observe(result(), now: t0.addingTimeInterval(2))
        XCTAssertEqual(tracker.lastOwnerSeen, t0, "an empty seat must let absence accrue")
    }

    // MARK: - The v1.1.2 regression: a stranger buying itself time

    func testConfirmedStrangerFaceDoesNotRefreshPresence() {
        var tracker = PresenceTracker(now: t0)
        tracker.establish(now: t0)

        // Before the fix, this frame satisfied "is there a face" and refreshed
        // the presence clock using the very face just flagged as not-the-owner,
        // which roughly doubled the real time to countdown for a seat takeover.
        tracker.observe(result(faces: 1, stranger: true), now: t0.addingTimeInterval(1))
        XCTAssertEqual(tracker.lastOwnerSeen, t0)
    }

    func testStrangerStreakBreaksTheChainAtTheLimit() {
        var tracker = PresenceTracker(now: t0, strangerStreakLimit: 3)
        tracker.establish(now: t0)

        for frame in 1...2 {
            tracker.observe(result(faces: 1, stranger: true), now: t0.addingTimeInterval(Double(frame)))
            XCTAssertTrue(tracker.chainActive, "chain should survive \(frame) stranger frame(s) of 3")
        }
        tracker.observe(result(faces: 1, stranger: true), now: t0.addingTimeInterval(3))
        XCTAssertFalse(tracker.chainActive)
    }

    func testStrangerStreakResetsOnANonStrangerFrame() {
        var tracker = PresenceTracker(now: t0, strangerStreakLimit: 3)
        tracker.establish(now: t0)

        tracker.observe(result(faces: 1, stranger: true), now: t0.addingTimeInterval(1))
        tracker.observe(result(faces: 1, stranger: true), now: t0.addingTimeInterval(2))
        tracker.observe(result(faces: 1), now: t0.addingTimeInterval(3)) // ambiguous, clears the streak
        tracker.observe(result(faces: 1, stranger: true), now: t0.addingTimeInterval(4))
        tracker.observe(result(faces: 1, stranger: true), now: t0.addingTimeInterval(5))

        XCTAssertTrue(tracker.chainActive, "two fresh stranger frames must not trip a limit of 3")
    }

    // MARK: - Supervising a colleague at your own screen

    func testOwnerMatchWinsWhenAStrangerIsInTheSameFrame() {
        var tracker = PresenceTracker(now: t0)
        tracker.establish(now: t0)

        // Both flags set on one frame: the colleague was checked first and
        // flagged, then the owner matched. Identity must take precedence, and
        // the stranger streak must not accumulate while the owner is present.
        let seen = t0.addingTimeInterval(1)
        XCTAssertTrue(tracker.observe(result(faces: 2, owner: true, stranger: true), now: seen))
        XCTAssertTrue(tracker.chainActive)
        XCTAssertEqual(tracker.lastOwnerSeen, seen)

        for frame in 2...4 {
            tracker.observe(result(faces: 2, owner: true, stranger: true), now: t0.addingTimeInterval(Double(frame)))
        }
        XCTAssertTrue(tracker.chainActive, "a matched owner must never be locked out by a bystander's face")
    }

    // MARK: - Gates

    func testBrokenChainStopsContinuityUntilAFreshMatch() {
        var tracker = PresenceTracker(now: t0)
        tracker.establish(now: t0)
        tracker.breakChain() // what the countdown and camera-wake gates do

        tracker.observe(result(faces: 1), now: t0.addingTimeInterval(1))
        tracker.observe(result(bodies: 1), now: t0.addingTimeInterval(2))
        XCTAssertEqual(tracker.lastOwnerSeen, t0, "only a positive match may restore presence after a gate")

        let match = t0.addingTimeInterval(3)
        tracker.observe(result(faces: 1, owner: true), now: match)
        XCTAssertTrue(tracker.chainActive)
        XCTAssertEqual(tracker.lastOwnerSeen, match)
    }

    func testTouchRefreshesPresenceWithoutGrantingIdentity() {
        var tracker = PresenceTracker(now: t0)
        let touched = t0.addingTimeInterval(4)

        tracker.touch(now: touched) // Esc-cancel and camera-rest use this
        XCTAssertEqual(tracker.lastOwnerSeen, touched)
        XCTAssertFalse(tracker.chainActive, "touch must not concede identity")
    }

    func testResetClearsIdentityAndStreak() {
        var tracker = PresenceTracker(now: t0, strangerStreakLimit: 3)
        tracker.establish(now: t0)
        tracker.observe(result(faces: 1, stranger: true), now: t0.addingTimeInterval(1))

        let restart = t0.addingTimeInterval(10)
        tracker.reset(now: restart)
        XCTAssertFalse(tracker.chainActive)
        XCTAssertEqual(tracker.lastOwnerSeen, restart)

        // Streak must have been cleared: two more stranger frames shouldn't
        // reach a limit of 3 on their own.
        tracker.establish(now: restart)
        tracker.observe(result(faces: 1, stranger: true), now: restart.addingTimeInterval(1))
        tracker.observe(result(faces: 1, stranger: true), now: restart.addingTimeInterval(2))
        XCTAssertTrue(tracker.chainActive)
    }
}

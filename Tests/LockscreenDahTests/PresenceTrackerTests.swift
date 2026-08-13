import XCTest
@testable import LockscreenDah

/// The seat-continuity chain is where every presence bug this project has had
/// actually lived, and it's a pure value type — so it gets real coverage.
/// Each test names the behaviour it pins down rather than the method it calls.
final class PresenceTrackerTests: XCTestCase {
    // Monotonic uptime seconds, matching PresenceTracker's clock (see Uptime).
    private let t0: TimeInterval = 1_000_000

    private func result(
        faces: Int = 0,
        bodies: Int = 0,
        owner: Bool = false,
        stranger: Bool = false,
        frontalUnmatched: Bool = false
    ) -> DetectionResult {
        DetectionResult(
            faceCount: faces,
            bodyCount: bodies,
            ownerMatched: owner,
            strangerSeen: stranger,
            frontalButUnmatched: frontalUnmatched,
            capturedAt: t0
        )
    }

    // MARK: - Establishing identity

    func testChainStartsInactiveAndAFaceAloneCannotEstablishIt() {
        var tracker = PresenceTracker(now: t0)
        XCTAssertFalse(tracker.chainActive)

        // A face with no owner match must not create identity, only maintain it.
        tracker.observe(result(faces: 1), now: t0 + 1)
        XCTAssertFalse(tracker.chainActive)
        XCTAssertEqual(tracker.lastOwnerSeen, t0, "an unmatched face must not refresh presence before identity exists")
    }

    func testOwnerMatchEstablishesChainAndStampsPresence() {
        var tracker = PresenceTracker(now: t0)
        let seen = t0 + 5

        XCTAssertTrue(tracker.observe(result(faces: 1, owner: true), now: seen))
        XCTAssertTrue(tracker.chainActive)
        XCTAssertEqual(tracker.lastOwnerSeen, seen)
    }

    // MARK: - Seat continuity

    func testAmbiguousFaceMaintainsAnEstablishedChain() {
        var tracker = PresenceTracker(now: t0)
        tracker.establish(now: t0)

        // Turned head: detected, but too oblique to judge either way.
        let later = t0 + 2
        tracker.observe(result(faces: 1), now: later)
        XCTAssertEqual(tracker.lastOwnerSeen, later, "a face at an unjudgeable angle should hold the seat")
    }

    func testBodyAloneMaintainsAnEstablishedChain() {
        var tracker = PresenceTracker(now: t0)
        tracker.establish(now: t0)

        let later = t0 + 2
        tracker.observe(result(bodies: 1), now: later)
        XCTAssertEqual(tracker.lastOwnerSeen, later)
    }

    func testEmptyFrameDoesNotMaintainTheChain() {
        var tracker = PresenceTracker(now: t0)
        tracker.establish(now: t0)

        tracker.observe(result(), now: t0 + 2)
        XCTAssertEqual(tracker.lastOwnerSeen, t0, "an empty seat must let absence accrue")
    }

    // MARK: - The v1.1.2 regression: a stranger buying itself time

    func testConfirmedStrangerFaceDoesNotRefreshPresence() {
        var tracker = PresenceTracker(now: t0)
        tracker.establish(now: t0)

        // Before the fix, this frame satisfied "is there a face" and refreshed
        // the presence clock using the very face just flagged as not-the-owner,
        // which roughly doubled the real time to countdown for a seat takeover.
        tracker.observe(result(faces: 1, stranger: true), now: t0 + 1)
        XCTAssertEqual(tracker.lastOwnerSeen, t0)
    }

    func testStrangerStreakBreaksTheChainAtTheLimit() {
        var tracker = PresenceTracker(now: t0, strangerStreakLimit: 3)
        tracker.establish(now: t0)

        for frame in 1...2 {
            tracker.observe(result(faces: 1, stranger: true), now: t0 + Double(frame))
            XCTAssertTrue(tracker.chainActive, "chain should survive \(frame) stranger frame(s) of 3")
        }
        tracker.observe(result(faces: 1, stranger: true), now: t0 + 3)
        XCTAssertFalse(tracker.chainActive)
    }

    func testStrangerStreakResetsOnANonStrangerFrame() {
        var tracker = PresenceTracker(now: t0, strangerStreakLimit: 3)
        tracker.establish(now: t0)

        tracker.observe(result(faces: 1, stranger: true), now: t0 + 1)
        tracker.observe(result(faces: 1, stranger: true), now: t0 + 2)
        tracker.observe(result(faces: 1), now: t0 + 3) // ambiguous, clears the streak
        tracker.observe(result(faces: 1, stranger: true), now: t0 + 4)
        tracker.observe(result(faces: 1, stranger: true), now: t0 + 5)

        XCTAssertTrue(tracker.chainActive, "two fresh stranger frames must not trip a limit of 3")
    }

    // MARK: - "Don't know" is not "not you"
    //
    // The distinction the flicker bug turned on. `strangerSeen` means the model
    // is *confident* the face isn't the owner. A face that merely failed to
    // reach the match threshold is ambiguous, and ambiguity must sustain
    // presence exactly like a turned head does — otherwise four marginal frames
    // of the owner's own face put a blackout on screen.

    func testAmbiguousUnmatchedFaceSustainsPresence() {
        var tracker = PresenceTracker(now: t0)
        tracker.establish(now: t0)

        // Detected, not matched, not confidently a stranger: the owner tipped
        // their head down at the keyboard.
        let later = t0 + 2
        tracker.observe(result(faces: 1, owner: false, stranger: false), now: later)
        XCTAssertEqual(tracker.lastOwnerSeen, later, "ambiguity must not stop the presence clock")
    }

    func testRepeatedAmbiguityNeverTriggersTheStrangerFailsafe() {
        var tracker = PresenceTracker(now: t0, strangerStreakLimit: 3)
        tracker.establish(now: t0)

        // A long run of marginal frames is the owner in poor light, not an
        // intruder, and must never break the chain on its own.
        for frame in 1...10 {
            tracker.observe(result(faces: 1), now: t0 + Double(frame))
        }
        XCTAssertTrue(tracker.chainActive)
        XCTAssertEqual(tracker.lastOwnerSeen, t0 + 10, "presence should have advanced throughout")
    }

    func testConfidentStrangerStillBlocksPresenceImmediately() {
        var tracker = PresenceTracker(now: t0)
        tracker.establish(now: t0)

        // The v1.1.2 protection must survive the ambiguity change: a face the
        // model is sure about gets no continuity at all.
        tracker.observe(result(faces: 1, stranger: true), now: t0 + 1)
        XCTAssertEqual(tracker.lastOwnerSeen, t0)
    }

    // MARK: - Bounding ambiguity without punishing a turned head
    //
    // The distinction that closes the "stranger scoring between the thresholds
    // holds the screen forever" hole. A face the model could *see* and still
    // couldn't confirm is weak evidence; a turned-away face or a torso is no
    // evidence at all. Only the first is put on a clock.

    func testJudgeableButUnmatchedFaceIsBoundedInTime() {
        var tracker = PresenceTracker(now: t0, unconfirmedLimit: 5)
        tracker.establish(now: t0)

        // Inside the window it still sustains presence — the owner gets time to
        // be recognised rather than being blacked out on a marginal frame.
        tracker.observe(result(faces: 1, frontalUnmatched: true), now: t0 + 1)
        XCTAssertEqual(tracker.lastOwnerSeen, t0 + 1)

        // Past it, presence stops advancing and the countdown becomes the gate.
        tracker.observe(result(faces: 1, frontalUnmatched: true), now: t0 + 7)
        XCTAssertEqual(tracker.lastOwnerSeen, t0 + 1, "an unconfirmed face must not hold the screen forever")
    }

    func testAConfidentMatchClearsTheUnconfirmedClock() {
        var tracker = PresenceTracker(now: t0, unconfirmedLimit: 5)
        tracker.establish(now: t0)

        tracker.observe(result(faces: 1, frontalUnmatched: true), now: t0 + 1)
        tracker.observe(result(faces: 1, owner: true), now: t0 + 2) // recognised
        // The clock restarts from scratch, so a later marginal frame is covered
        // again rather than inheriting the earlier doubt.
        tracker.observe(result(faces: 1, frontalUnmatched: true), now: t0 + 6)
        XCTAssertEqual(tracker.lastOwnerSeen, t0 + 6)
    }

    func testTurnedAwayFaceIsNeverPutOnTheClock() {
        var tracker = PresenceTracker(now: t0, unconfirmedLimit: 5)
        tracker.establish(now: t0)

        // Working at a second screen for a long stretch: detected, unmatched, but
        // never judgeable — so it must sustain presence indefinitely.
        for minute in 1...20 {
            tracker.observe(result(faces: 1), now: t0 + Double(minute) * 60)
        }
        XCTAssertEqual(tracker.lastOwnerSeen, t0 + 1200, "an off-angle face must never be timed out")
    }

    func testBodyOnlyIsNeverPutOnTheClock() {
        var tracker = PresenceTracker(now: t0, unconfirmedLimit: 5)
        tracker.establish(now: t0)
        for minute in 1...20 {
            tracker.observe(result(bodies: 1), now: t0 + Double(minute) * 60)
        }
        XCTAssertEqual(tracker.lastOwnerSeen, t0 + 1200)
    }

    // MARK: - Supervising a colleague at your own screen

    func testOwnerMatchWinsWhenAStrangerIsInTheSameFrame() {
        var tracker = PresenceTracker(now: t0)
        tracker.establish(now: t0)

        // Both flags set on one frame: the colleague was checked first and
        // flagged, then the owner matched. Identity must take precedence, and
        // the stranger streak must not accumulate while the owner is present.
        let seen = t0 + 1
        XCTAssertTrue(tracker.observe(result(faces: 2, owner: true, stranger: true), now: seen))
        XCTAssertTrue(tracker.chainActive)
        XCTAssertEqual(tracker.lastOwnerSeen, seen)

        for frame in 2...4 {
            tracker.observe(result(faces: 2, owner: true, stranger: true), now: t0 + Double(frame))
        }
        XCTAssertTrue(tracker.chainActive, "a matched owner must never be locked out by a bystander's face")
    }

    // MARK: - Gates

    func testBrokenChainStopsContinuityUntilAFreshMatch() {
        var tracker = PresenceTracker(now: t0)
        tracker.establish(now: t0)
        tracker.breakChain() // what the countdown and camera-wake gates do

        tracker.observe(result(faces: 1), now: t0 + 1)
        tracker.observe(result(bodies: 1), now: t0 + 2)
        XCTAssertEqual(tracker.lastOwnerSeen, t0, "only a positive match may restore presence after a gate")

        let match = t0 + 3
        tracker.observe(result(faces: 1, owner: true), now: match)
        XCTAssertTrue(tracker.chainActive)
        XCTAssertEqual(tracker.lastOwnerSeen, match)
    }

    func testTouchRefreshesPresenceWithoutGrantingIdentity() {
        var tracker = PresenceTracker(now: t0)
        let touched = t0 + 4

        tracker.touch(now: touched) // Esc-cancel and camera-rest use this
        XCTAssertEqual(tracker.lastOwnerSeen, touched)
        XCTAssertFalse(tracker.chainActive, "touch must not concede identity")
    }

    func testResetClearsIdentityAndStreak() {
        var tracker = PresenceTracker(now: t0, strangerStreakLimit: 3)
        tracker.establish(now: t0)
        tracker.observe(result(faces: 1, stranger: true), now: t0 + 1)

        let restart = t0 + 10
        tracker.reset(now: restart)
        XCTAssertFalse(tracker.chainActive)
        XCTAssertEqual(tracker.lastOwnerSeen, restart)

        // Streak must have been cleared: two more stranger frames shouldn't
        // reach a limit of 3 on their own.
        tracker.establish(now: restart)
        tracker.observe(result(faces: 1, stranger: true), now: restart + 1)
        tracker.observe(result(faces: 1, stranger: true), now: restart + 2)
        XCTAssertTrue(tracker.chainActive)
    }
}

import XCTest
@testable import LockscreenDah

/// Every bug this file guards against shipped. The coordinator's state machine
/// had no coverage because it needs a camera and AppKit; the decisions it makes
/// need neither, so they live here where they can be pinned down.
final class PresenceSupervisorTests: XCTestCase {
    private let grace: TimeInterval = 3
    private let staleAfter: TimeInterval = 3

    private func conditions(
        sessionLocked: Bool = false,
        displayAsleep: Bool = false,
        sinceFrame: TimeInterval = 0,
        sinceOwner: TimeInterval = 0
    ) -> SystemConditions {
        SystemConditions(
            sessionLocked: sessionLocked,
            displayAsleep: displayAsleep,
            secondsSinceLastFrame: sinceFrame,
            secondsSinceOwnerSeen: sinceOwner
        )
    }

    private func decide(_ state: SupervisedState, _ conditions: SystemConditions) -> SupervisionDecision {
        PresenceSupervisor.decide(
            state: state, conditions: conditions, gracePeriod: grace, staleAfter: staleAfter
        )
    }

    // MARK: - Shipped bug: stranded in .locked (v1.3.0 – v1.4.0)

    /// The unlock notification is best-effort. Dropping one used to leave the
    /// app locked with the camera off and no timer running to notice.
    func testResumesWhenTheScreenIsUsableAgain() {
        XCTAssertEqual(decide(.locked, conditions()), .resumeFromLocked)
    }

    func testStaysLockedWhileTheSessionIsLocked() {
        XCTAssertEqual(decide(.locked, conditions(sessionLocked: true)), .doNothing)
    }

    // MARK: - Shipped bug: camera restarted behind a dark screen (v1.4.0)

    /// `.locked` is entered both by a session lock and by a display sleep that
    /// didn't lock. Reading the second as a missed unlock restarted the camera
    /// one second after every display sleep, and ran it behind a black screen.
    func testDoesNotResumeWhileTheDisplayIsAsleep() {
        XCTAssertEqual(decide(.locked, conditions(displayAsleep: true)), .doNothing)
    }

    /// Belt and braces: a locked session *and* a sleeping display.
    func testDoesNotResumeWhenBothAreTrue() {
        XCTAssertEqual(
            decide(.locked, conditions(sessionLocked: true, displayAsleep: true)), .doNothing
        )
    }

    // MARK: - Shipped bug: countdown abandoned on display sleep

    /// A countdown means absence was already proven. The display going dark is
    /// not the owner returning, and parking without locking left the machine
    /// unlocked behind a black screen.
    func testLocksWhenTheDisplaySleepsDuringACountdown() {
        XCTAssertEqual(
            decide(.alerting, conditions(displayAsleep: true, sinceOwner: grace + 1)), .lockNow
        )
    }

    /// Same rule from `.watching`, for the window where the grace deadline has
    /// passed but the countdown hasn't started yet.
    func testLocksWhenTheDisplaySleepsAfterAbsenceWasProven() {
        XCTAssertEqual(
            decide(.watching, conditions(displayAsleep: true, sinceOwner: grace)), .lockNow
        )
    }

    /// But a sleeping display on its own proves nothing — the owner may be
    /// sitting right there reading. Park, don't lock.
    func testDisplaySleepAloneDoesNotLock() {
        XCTAssertEqual(
            decide(.watching, conditions(displayAsleep: true, sinceOwner: grace - 0.5)), .enterLocked
        )
    }

    // MARK: - Camera liveness

    func testStaleFramesHandOffToTheRecoveryPath() {
        XCTAssertEqual(decide(.watching, conditions(sinceFrame: staleAfter + 0.1)), .cameraStopped)
    }

    /// The session configures asynchronously, so the first moments of every
    /// start have no frames yet. Reacting inside the window would tear the
    /// camera down on startup.
    func testFreshlyStartedCameraIsNotTreatedAsStale() {
        XCTAssertEqual(decide(.watching, conditions(sinceFrame: staleAfter)), .doNothing)
    }

    func testStaleFramesAreAlsoCaughtDuringACountdown() {
        XCTAssertEqual(decide(.alerting, conditions(sinceFrame: staleAfter + 0.1)), .cameraStopped)
    }

    // MARK: - Locking the session while watching

    /// A missed `screenIsLocked` used to leave the camera running behind a
    /// locked session.
    func testStopsWatchingWhenTheSessionLocks() {
        XCTAssertEqual(decide(.watching, conditions(sessionLocked: true)), .enterLocked)
        XCTAssertEqual(decide(.alerting, conditions(sessionLocked: true)), .enterLocked)
    }

    /// A locked session takes precedence over everything else — including stale
    /// frames, which are expected once the camera has been stopped.
    func testSessionLockWinsOverStaleFrames() {
        XCTAssertEqual(
            decide(.watching, conditions(sessionLocked: true, sinceFrame: 600)), .enterLocked
        )
    }

    // MARK: - States the supervisor must keep its hands off

    /// `.cameraUnavailable` owns its own retry ladder; restarting once a second
    /// would hammer a device that is already failing. `.enrolling` hands the
    /// session to the enrollment controller. `.paused` is a deliberate choice.
    func testLeavesTheDeliberatelyIdleStatesAlone() {
        for state: SupervisedState in [.paused, .enrolling, .cameraUnavailable] {
            XCTAssertEqual(
                decide(state, conditions(sinceFrame: 600, sinceOwner: 600)), .doNothing,
                "\(state) must not be driven by the supervisor"
            )
            XCTAssertEqual(
                decide(state, conditions(sessionLocked: true, displayAsleep: true)), .doNothing,
                "\(state) must not be driven by the supervisor"
            )
        }
    }

    /// Nothing may fall through to "carry on with whatever we were doing":
    /// every state has an answer for any conditions.
    func testEveryStateDecidesUnderEveryCombination() {
        let states: [SupervisedState] = [
            .paused, .watching, .alerting, .locked, .enrolling, .cameraUnavailable,
        ]
        for state in states {
            for sessionLocked in [true, false] {
                for displayAsleep in [true, false] {
                    for sinceFrame in [0.0, staleAfter + 1] {
                        for sinceOwner in [0.0, grace + 1] {
                            _ = decide(state, conditions(
                                sessionLocked: sessionLocked, displayAsleep: displayAsleep,
                                sinceFrame: sinceFrame, sinceOwner: sinceOwner
                            ))
                        }
                    }
                }
            }
        }
    }
}

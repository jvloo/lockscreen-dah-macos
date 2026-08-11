import XCTest
@testable import LockscreenDah

/// Camera rest decides when the app is deliberately blind, so its edges are
/// security edges. This logic lived inside a tick handler that needed a camera,
/// a run loop and the user's real settings to run at all — every one of the
/// cases below was previously reachable only by typing at a laptop and watching.
final class CameraRestPolicyTests: XCTestCase {
    private let t0: TimeInterval = 1_000

    /// Awake, chain established, input flowing long enough to rest.
    private func awake(
        now: TimeInterval? = nil,
        secondsSinceInput: TimeInterval = 0.1,
        inputActiveSince: TimeInterval? = 1_000,
        lastCameraWake: TimeInterval = 0,
        chainActive: Bool = true,
        restAfter: TimeInterval = 10,
        wakeQuiet: TimeInterval = 2,
        minimumAwake: TimeInterval = 20,
        maximumRest: TimeInterval = 0,
        restAvailable: Bool = true
    ) -> CameraRestInputs {
        CameraRestInputs(
            now: now ?? t0 + 30,
            secondsSinceInput: secondsSinceInput,
            isResting: false,
            restStartedAt: nil,
            inputActiveSince: inputActiveSince,
            lastCameraWake: lastCameraWake,
            chainActive: chainActive,
            restAfter: restAfter,
            wakeQuiet: wakeQuiet,
            minimumAwake: minimumAwake,
            maximumRest: maximumRest,
            restAvailable: restAvailable
        )
    }

    private func resting(
        now: TimeInterval,
        restStartedAt: TimeInterval,
        secondsSinceInput: TimeInterval = 0.1,
        restAfter: TimeInterval = 10,
        wakeQuiet: TimeInterval = 2,
        maximumRest: TimeInterval = 0,
        restAvailable: Bool = true
    ) -> CameraRestInputs {
        var i = awake(
            now: now,
            secondsSinceInput: secondsSinceInput,
            restAfter: restAfter,
            wakeQuiet: wakeQuiet,
            maximumRest: maximumRest,
            restAvailable: restAvailable
        )
        i.isResting = true
        i.restStartedAt = restStartedAt
        return i
    }

    // MARK: - Entering rest

    func testRestsOnceInputHasBeenSustained() {
        XCTAssertEqual(CameraRestPolicy.decide(awake()), .beginResting)
    }

    func testNeverRestsWithoutAnEstablishedChain() {
        // Input can maintain identity; it must never create it. Resting here
        // would hand presence to keystrokes that never proved who is typing.
        XCTAssertEqual(CameraRestPolicy.decide(awake(chainActive: false)), .none)
    }

    func testNeverIdleIsHonoured() {
        XCTAssertEqual(CameraRestPolicy.decide(awake(restAfter: 0)), .none)
    }

    func testDoesNotRestWhenRestIsUnavailableAtThisCountdownDelay() {
        XCTAssertEqual(CameraRestPolicy.decide(awake(restAvailable: false)), .none)
    }

    func testDoesNotRestBeforeInputHasBeenSustainedLongEnough() {
        // Input started 3 s ago but the threshold is 10 s.
        XCTAssertEqual(CameraRestPolicy.decide(awake(now: t0 + 3, inputActiveSince: t0)), .none)
    }

    func testDoesNotRestAgainInsideTheAwakeMinimum() {
        // Woke 5 s ago, minimum is 20 s. Without this, bursty typing would
        // thrash the capture session — each cycle costs a device open and an
        // auto-exposure re-run.
        XCTAssertEqual(
            CameraRestPolicy.decide(awake(now: t0 + 30, lastCameraWake: t0 + 25)),
            .none
        )
    }

    // MARK: - Leaving rest

    func testStaysRestedWhileInputKeepsFlowing() {
        XCTAssertEqual(
            CameraRestPolicy.decide(resting(now: t0 + 5, restStartedAt: t0)),
            .keepResting
        )
    }

    func testWakesWhenInputGoesQuiet() {
        XCTAssertEqual(
            CameraRestPolicy.decide(resting(now: t0 + 5, restStartedAt: t0, secondsSinceInput: 3)),
            .wake(peeking: false)
        )
    }

    func testSwitchingToNeverIdleEndsAnActiveRestImmediately() {
        // A live settings change must end the rest now, not merely block the
        // next one — otherwise the camera stays off under a setting that says
        // it shouldn't be.
        XCTAssertEqual(
            CameraRestPolicy.decide(resting(now: t0 + 5, restStartedAt: t0, restAfter: 0)),
            .wake(peeking: false)
        )
    }

    func testRestBecomingUnavailableEndsAnActiveRestImmediately() {
        XCTAssertEqual(
            CameraRestPolicy.decide(resting(now: t0 + 5, restStartedAt: t0, restAvailable: false)),
            .wake(peeking: false)
        )
    }

    // MARK: - The rest ceiling (currently disabled; see docs/TESTING.md entry 2)

    func testRestIsUnboundedWhenTheCeilingIsDisabled() {
        // maximumRest == 0 means no cap. This is the shipped configuration, and
        // the reason the blind window is documented as unbounded: an intruder
        // holding a key keeps input flowing, which is what keeps the camera off.
        XCTAssertEqual(
            CameraRestPolicy.decide(resting(now: t0 + 3_600, restStartedAt: t0, maximumRest: 0)),
            .keepResting
        )
    }

    func testCeilingForcesAPeekEvenWhileInputNeverStops() {
        XCTAssertEqual(
            CameraRestPolicy.decide(resting(now: t0 + 10, restStartedAt: t0, maximumRest: 10)),
            .wake(peeking: true)
        )
    }

    func testCeilingDoesNotFireEarly() {
        XCTAssertEqual(
            CameraRestPolicy.decide(resting(now: t0 + 9.9, restStartedAt: t0, maximumRest: 10)),
            .keepResting
        )
    }

    func testAQuietWakeIsNotAPeekEvenAtTheCeiling() {
        // Distinguishing these matters: a peek returns straight to rest on a
        // match, a real wake serves the full awake minimum.
        let atCeilingButQuiet = resting(
            now: t0 + 10, restStartedAt: t0, secondsSinceInput: 5, maximumRest: 10
        )
        XCTAssertEqual(CameraRestPolicy.decide(atCeilingButQuiet), .wake(peeking: true),
                       "the ceiling takes precedence once reached")
    }

    // MARK: - Input-run tracking

    func testInputRunStartsAtTheFirstContinuousMoment() {
        var i = awake(secondsSinceInput: 0.1, inputActiveSince: nil)
        i.now = t0
        XCTAssertEqual(CameraRestPolicy.inputActiveSince(i), t0)
    }

    func testInputRunIsPreservedWhileInputContinues() {
        let i = awake(now: t0 + 5, secondsSinceInput: 0.1, inputActiveSince: t0)
        XCTAssertEqual(CameraRestPolicy.inputActiveSince(i), t0)
    }

    func testInputRunClearsOnceInputLapses() {
        let i = awake(now: t0 + 5, secondsSinceInput: 9, inputActiveSince: t0)
        XCTAssertNil(CameraRestPolicy.inputActiveSince(i))
    }
}

import XCTest
@testable import LockscreenDah

/// Settings is pure logic over UserDefaults, so it's covered directly. Every
/// test runs against a scratch suite — never the real app domain, which holds
/// the user's actual configuration.
final class SettingsTests: XCTestCase {
    private static let suiteName = "com.xavierloo.lockscreen-dah.tests"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: Self.suiteName)
        Settings.defaults = UserDefaults(suiteName: Self.suiteName)!
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: Self.suiteName)
        Settings.defaults = .standard
        super.tearDown()
    }

    // MARK: - Duration clamps
    //
    // Both deadlines are armed as precise one-shot timers, so a value of 0 or
    // less would schedule a fire date in the past and spin the run loop. The
    // old polling implementation floored these implicitly; the clamp is what
    // replaces that guarantee.

    func testGracePeriodDefaultsToTheShortestOfferedValue() {
        // A security tool shouldn't ship a weaker default than the one it
        // recommends; the cost of the shortest value is CPU, not reliability.
        XCTAssertEqual(Settings.gracePeriod, 1)
        XCTAssertEqual(Settings.gracePeriod, Settings.gracePeriodOptions.min())
    }

    func testGracePeriodRejectsZeroAndNegatives() {
        for tampered in [0.0, -1.0, -10_000.0] {
            Settings.defaults.set(tampered, forKey: "gracePeriod")
            XCTAssertGreaterThan(Settings.gracePeriod, 0, "\(tampered) must not survive as a timer deadline")
        }
    }

    func testGracePeriodClampsAbsurdlyLargeValues() {
        Settings.defaults.set(999_999.0, forKey: "gracePeriod")
        XCTAssertEqual(Settings.gracePeriod, 600)
    }

    func testEveryOfferedGracePeriodSurvivesTheClampUnchanged() {
        for option in Settings.gracePeriodOptions {
            Settings.gracePeriod = option
            XCTAssertEqual(Settings.gracePeriod, option, "menu option \(option) must not be altered on read")
        }
    }

    func testCountdownPreservesZeroAsNeverCountdown() {
        Settings.countdownDuration = 0
        XCTAssertEqual(Settings.countdownDuration, 0)
        XCTAssertTrue(Settings.countdownDisabled)
    }

    func testCountdownClampsNegativesUpInsteadOfTreatingThemAsInstant() {
        // A tampered negative must not silently become the most aggressive
        // setting available.
        Settings.defaults.set(-5.0, forKey: "countdownDuration")
        XCTAssertGreaterThan(Settings.countdownDuration, 0)
        XCTAssertFalse(Settings.countdownDisabled)
    }

    func testEveryOfferedCountdownSurvivesTheClampUnchanged() {
        for option in Settings.countdownOptions {
            Settings.countdownDuration = option
            XCTAssertEqual(Settings.countdownDuration, option)
        }
    }

    func testCountdownDisabledOnlyAtExactlyZero() {
        Settings.countdownDuration = 3
        XCTAssertFalse(Settings.countdownDisabled)
        Settings.countdownDuration = 0
        XCTAssertTrue(Settings.countdownDisabled)
    }

    func testCountdownFloorIsTheShortestOfferedNotTheSharedMinimum() {
        // The Esc escape gesture is sized against this floor: three presses plus
        // a Touch ID round trip do not fit in 0.5 s, so a stored 0.5 must be
        // pulled up to 3 rather than accepted by the shared duration minimum.
        Settings.defaults.set(0.5, forKey: "countdownDuration")
        XCTAssertEqual(Settings.countdownDuration, Settings.countdownFloor)
        XCTAssertEqual(Settings.countdownFloor, 3)
    }

    func testGracePeriodKeepsTheLowerFloorDeliberately() {
        // The two floors differ on purpose: the countdown is sized against the
        // Esc gesture, grace is not.
        Settings.defaults.set(0.5, forKey: "gracePeriod")
        XCTAssertEqual(Settings.gracePeriod, 0.5)
        XCTAssertLessThan(Settings.gracePeriod, Settings.countdownFloor)
    }

    func testLockLoopCounterRejectsNegatives() {
        // A stored negative would make ">= threshold" unreachable and silently
        // remove the only failsafe against a "Never Countdown" lock loop.
        Settings.defaults.set(-100, forKey: "consecutiveLocksWithoutMatch")
        XCTAssertEqual(Settings.consecutiveLocksWithoutMatch, 0)
    }

    func testLockLoopCounterSaturatesInsteadOfGrowingUnbounded() {
        Settings.consecutiveLocksWithoutMatch = 10_000
        XCTAssertLessThanOrEqual(Settings.consecutiveLocksWithoutMatch, 1000)
    }

    func testMatchThresholdIsClampedToASaneBand() {
        Settings.defaults.set(Float(-1), forKey: "matchThreshold")
        XCTAssertGreaterThanOrEqual(Settings.matchThreshold, 0.2, "must never mean everyone passes")

        Settings.defaults.set(Float(50), forKey: "matchThreshold")
        XCTAssertLessThanOrEqual(Settings.matchThreshold, 0.9, "must never mean no one ever passes")
    }

    // MARK: - Re-enrollment requirement

    func testReenrollmentIsNotRequiredByDefault() {
        XCTAssertFalse(Settings.reenrollmentRequired)
    }

    func testReenrollmentRequirementPersists() {
        // Must survive a relaunch, otherwise quitting the app would clear a
        // requirement that exists because recognition stopped working.
        Settings.reenrollmentRequired = true
        XCTAssertTrue(Settings.reenrollmentRequired)
        Settings.reenrollmentRequired = false
        XCTAssertFalse(Settings.reenrollmentRequired)
    }

    func testLockLoopCounterDefaultsToZeroAndPersists() {
        // Persisted because each iteration of a lock loop passes through a screen
        // lock: an in-memory counter would never observe the loop it detects.
        XCTAssertEqual(Settings.consecutiveLocksWithoutMatch, 0)
        Settings.consecutiveLocksWithoutMatch = 2
        XCTAssertEqual(Settings.consecutiveLocksWithoutMatch, 2)
    }

    // MARK: - Display

    func testFormatMinutesUsesATwelveHourClock() {
        XCTAssertEqual(Settings.formatMinutes(0), "12:00 AM")
        XCTAssertEqual(Settings.formatMinutes(9 * 60), "9:00 AM")
        XCTAssertEqual(Settings.formatMinutes(12 * 60), "12:00 PM")
        XCTAssertEqual(Settings.formatMinutes(20 * 60 + 30), "8:30 PM")
        XCTAssertEqual(Settings.formatMinutes(23 * 60 + 5), "11:05 PM")
    }

    // MARK: - Helpers

    /// A fixed local-time instant on a **Tuesday**, so hour-only tests aren't
    /// silently filtered out by the default Mon–Fri active days. Uses
    /// `Calendar.current`, the same calendar the production code reads.
    private func at(hour: Int, minute: Int = 0) -> Date {
        at(weekday: 3, hour: hour, minute: minute)
    }

    /// Walks forward from a fixed reference date to the requested weekday, so
    /// this stays correct in any time zone rather than hard-coding an epoch.
    private func at(weekday: Int, hour: Int, minute: Int = 0) -> Date {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        while calendar.component(.weekday, from: day) != weekday {
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }
}

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

    func testGracePeriodDefaultsToThree() {
        XCTAssertEqual(Settings.gracePeriod, 3)
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
        // Unlike the countdown, grace must be allowed below its menu minimum so
        // `cameraRestAvailable` can go false. The two floors differ on purpose.
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

    // MARK: - Camera rest availability

    func testCameraRestIsAvailableAtEveryOfferedCountdownDelay() {
        for option in Settings.gracePeriodOptions {
            Settings.gracePeriod = option
            XCTAssertTrue(Settings.cameraRestAvailable, "idling should be offered at \(option)s")
        }
    }

    func testCameraRestIsUnavailableBelowTheMinimum() {
        // Only reachable via `defaults write`. Below 1 s a woken camera can't
        // land even one match before the delay expires, so the rows are disabled
        // with the reason shown rather than silently ignored.
        Settings.defaults.set(0.5, forKey: "gracePeriod")
        XCTAssertLessThan(Settings.gracePeriod, Settings.cameraRestMinimumGrace)
        XCTAssertFalse(Settings.cameraRestAvailable)
    }

    func testMatchThresholdIsClampedToASaneBand() {
        Settings.defaults.set(Float(-1), forKey: "matchThreshold")
        XCTAssertGreaterThanOrEqual(Settings.matchThreshold, 0.2, "must never mean everyone passes")

        Settings.defaults.set(Float(50), forKey: "matchThreshold")
        XCTAssertLessThanOrEqual(Settings.matchThreshold, 0.9, "must never mean no one ever passes")
    }

    // MARK: - Active Hours window

    func testWithinMonitoringHoursForADaytimeRange() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 20 * 60

        XCTAssertTrue(Settings.withinMonitoringHours(now: at(hour: 12)))
        XCTAssertTrue(Settings.withinMonitoringHours(now: at(hour: 9)), "start boundary is inclusive")
        XCTAssertFalse(Settings.withinMonitoringHours(now: at(hour: 20)), "end boundary is exclusive")
        XCTAssertFalse(Settings.withinMonitoringHours(now: at(hour: 3)))
    }

    func testWithinMonitoringHoursForAnOvernightRange() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 21 * 60
        Settings.scheduleEndMinutes = 6 * 60

        XCTAssertTrue(Settings.withinMonitoringHours(now: at(hour: 23)))
        XCTAssertTrue(Settings.withinMonitoringHours(now: at(hour: 2)), "after midnight is still inside")
        XCTAssertFalse(Settings.withinMonitoringHours(now: at(hour: 12)))
    }

    func testScheduleDisabledIsAlwaysWithinHours() {
        Settings.scheduleEnabled = false
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 10 * 60
        XCTAssertTrue(Settings.withinMonitoringHours(now: at(hour: 23)))
    }

    func testEqualStartAndEndMeansAlwaysWithinHours() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 9 * 60
        XCTAssertTrue(Settings.withinMonitoringHours(now: at(hour: 3)))
    }

    // MARK: - Boundary staleness
    //
    // This is what lets a manual pause survive sleep/lock and still resume at
    // the next real schedule boundary. `.distantPast` is the "no meaningful
    // boundary" sentinel that makes a decision timestamp never look stale.

    func testNoBoundaryWhenScheduleIsDisabled() {
        Settings.scheduleEnabled = false
        XCTAssertEqual(Settings.mostRecentBoundary(before: at(hour: 12)), .distantPast)
    }

    func testNoBoundaryWhenTheScheduleIsContinuous() {
        // A full-day window on every day never changes state, so a manual pause
        // must survive indefinitely — same as having the schedule off.
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 9 * 60
        Settings.activeDays = Set(1...7)
        XCTAssertTrue(Settings.isContinuous)
        XCTAssertEqual(Settings.mostRecentBoundary(before: at(hour: 12)), .distantPast)
    }

    func testFullDayWindowStillHasBoundariesWhenSomeDaysAreInactive() {
        // Mon–Fri with a 24-hour window really does switch off at each weekend
        // boundary, so it must not claim to be continuous.
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 9 * 60
        Settings.activeDays = Settings.defaultActiveDays
        XCTAssertFalse(Settings.isContinuous)
        XCTAssertNotEqual(Settings.mostRecentBoundary(before: at(hour: 12)), .distantPast)
    }

    func testBoundaryIsTheMostRecentConfiguredTimeAtOrBeforeNow() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 20 * 60

        // Asserted on wall-clock components rather than an absolute instant so
        // this stays correct across time zones and DST.
        let boundary = Settings.mostRecentBoundary(before: at(hour: 12))
        let parts = Calendar.current.dateComponents([.hour, .minute], from: boundary)
        XCTAssertEqual(parts.hour, 9, "midday should resolve to today's start boundary")
        XCTAssertEqual(parts.minute, 0)
    }

    func testBoundaryLooksBackToYesterdayBeforeTheFirstOfToday() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 20 * 60

        let now = at(hour: 3)
        let boundary = Settings.mostRecentBoundary(before: now)
        let parts = Calendar.current.dateComponents([.hour, .minute], from: boundary)
        XCTAssertEqual(parts.hour, 20, "3am should resolve to yesterday's end boundary")
        XCTAssertLessThanOrEqual(boundary, now)
        XCTAssertLessThan(now.timeIntervalSince(boundary), 24 * 3600)
    }

    func testBoundaryNeverLandsInTheFuture() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 21 * 60
        Settings.scheduleEndMinutes = 6 * 60

        for hour in 0...23 {
            let now = at(hour: hour)
            XCTAssertLessThanOrEqual(
                Settings.mostRecentBoundary(before: now), now,
                "a future boundary would make every decision look stale at \(hour):00"
            )
        }
    }

    // MARK: - Field validation
    //
    // Every stored value is read through a clamp, because `defaults write` (or a
    // stale value from an older build) must never be able to put the app in a
    // state where it looks configured but silently protects nothing.

    func testScheduleMinutesAreClampedToARealTimeOfDay() {
        // Out of range would reach date(bySettingHour:) as e.g. hour 83, which
        // returns nil there and would drop the day's window entirely.
        Settings.defaults.set(99_999, forKey: "scheduleStartMinutes")
        XCTAssertEqual(Settings.scheduleStartMinutes, 1439)
        Settings.defaults.set(-500, forKey: "scheduleEndMinutes")
        XCTAssertEqual(Settings.scheduleEndMinutes, 0)
    }

    func testScheduleStillResolvesAWindowAfterAnAbsurdStoredTime() {
        Settings.scheduleEnabled = true
        Settings.defaults.set(99_999, forKey: "scheduleStartMinutes")
        Settings.scheduleEndMinutes = 30
        Settings.activeDays = Set(1...7)
        // 23:59 -> 00:30 overnight: the point is that a window exists at all.
        XCTAssertTrue(Settings.withinMonitoringHours(now: at(hour: 0, minute: 10)))
    }

    func testCameraRestAfterPreservesNeverButClampsOtherValues() {
        Settings.cameraRestAfter = 0
        XCTAssertEqual(Settings.cameraRestAfter, 0, "0 means Never Idle and must survive")

        Settings.defaults.set(0.01, forKey: "cameraRestAfter")
        XCTAssertGreaterThanOrEqual(Settings.cameraRestAfter, 1, "must not rest the camera almost immediately")

        Settings.defaults.set(-5.0, forKey: "cameraRestAfter")
        XCTAssertGreaterThanOrEqual(Settings.cameraRestAfter, 1)
    }

    func testCameraWakeQuietIsClamped() {
        // 0 or negative would make every tick read as "input has gone quiet".
        Settings.defaults.set(0.0, forKey: "cameraWakeQuiet")
        XCTAssertGreaterThanOrEqual(Settings.cameraWakeQuiet, 0.5)
        Settings.defaults.set(-1.0, forKey: "cameraWakeQuiet")
        XCTAssertGreaterThanOrEqual(Settings.cameraWakeQuiet, 0.5)
        Settings.defaults.set(9_999.0, forKey: "cameraWakeQuiet")
        XCTAssertLessThanOrEqual(Settings.cameraWakeQuiet, 60, "the camera must not stay blind that long")
    }

    func testEveryOfferedIdleAndWakeOptionSurvivesItsClamp() {
        for option in Settings.cameraRestOptions {
            Settings.cameraRestAfter = option
            XCTAssertEqual(Settings.cameraRestAfter, option)
        }
        for option in Settings.cameraWakeOptions {
            Settings.cameraWakeQuiet = option
            XCTAssertEqual(Settings.cameraWakeQuiet, option)
        }
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

    // MARK: - Active days

    func testDefaultsToMondayThroughFriday() {
        XCTAssertEqual(Settings.activeDays, [2, 3, 4, 5, 6])
    }

    func testAnActiveDayIsInsideMonitoringHours() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 20 * 60
        Settings.activeDays = Settings.defaultActiveDays
        XCTAssertTrue(Settings.withinMonitoringHours(now: at(weekday: 3, hour: 12)))
    }

    func testAnInactiveDayIsOutsideMonitoringHoursEvenMidWindow() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 20 * 60
        Settings.activeDays = Settings.defaultActiveDays
        XCTAssertFalse(Settings.withinMonitoringHours(now: at(weekday: 7, hour: 12)), "Saturday isn't selected")
        XCTAssertFalse(Settings.withinMonitoringHours(now: at(weekday: 1, hour: 12)), "Sunday isn't selected")
    }

    func testOvernightWindowIsGovernedByTheDayItOpened() {
        // A Friday-night shift must stay active into Saturday morning even
        // though Saturday itself isn't a selected day.
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 21 * 60
        Settings.scheduleEndMinutes = 6 * 60
        Settings.activeDays = Settings.defaultActiveDays

        XCTAssertTrue(Settings.withinMonitoringHours(now: at(weekday: 6, hour: 23)), "Friday evening")
        XCTAssertTrue(Settings.withinMonitoringHours(now: at(weekday: 7, hour: 2)), "Saturday 2am, opened Friday")
        XCTAssertFalse(Settings.withinMonitoringHours(now: at(weekday: 7, hour: 23)), "Saturday never opens a window")
        XCTAssertFalse(Settings.withinMonitoringHours(now: at(weekday: 1, hour: 2)), "Sunday 2am, Saturday never opened")
    }

    func testEmptyStoredActiveDaysFallsBackToTheDefault() {
        // "No active days" would mean monitoring never runs — it must never be
        // honoured, since it reads as configured protection but provides none.
        Settings.defaults.set([Int](), forKey: "activeDays")
        XCTAssertEqual(Settings.activeDays, Settings.defaultActiveDays)
    }

    func testInvalidWeekdayNumbersAreDiscarded() {
        Settings.defaults.set([0, 3, 9, 42], forKey: "activeDays")
        XCTAssertEqual(Settings.activeDays, [3])
    }

    func testSetterRefusesToPersistAnEmptySet() {
        Settings.activeDays = [3, 4]
        Settings.activeDays = []
        XCTAssertEqual(Settings.activeDays, [3, 4], "the previous selection must stand")
    }

    func testScheduleDisabledIgnoresInactiveDays() {
        Settings.scheduleEnabled = false
        Settings.activeDays = [3]
        XCTAssertTrue(Settings.withinMonitoringHours(now: at(weekday: 7, hour: 4)))
    }

    func testFormatActiveDays() {
        Settings.activeDays = Set(1...7)
        XCTAssertEqual(Settings.formatActiveDays(), "All days")
        Settings.activeDays = Settings.defaultActiveDays
        XCTAssertEqual(Settings.formatActiveDays(), "Mon–Fri")
        Settings.activeDays = [1, 7]
        XCTAssertEqual(Settings.formatActiveDays(), "Weekends")
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

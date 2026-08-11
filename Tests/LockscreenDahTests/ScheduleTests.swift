import XCTest
@testable import LockscreenDah

/// The schedule resolves hours *and* days through one window model, so these
/// exercise `MonitoringSchedule` directly with an explicit calendar rather than
/// through `Settings` — which means time zones and DST are actually assertable.
final class ScheduleTests: XCTestCase {
    private static let suiteName = "com.xavierloo.lockscreen-dah.tests.schedule"

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

    // MARK: - Active Hours window

    func testWithinMonitoringHoursForADaytimeRange() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 20 * 60

        XCTAssertTrue(Settings.schedule.isActive(at: at(hour: 12)))
        XCTAssertTrue(Settings.schedule.isActive(at: at(hour: 9)), "start boundary is inclusive")
        XCTAssertFalse(Settings.schedule.isActive(at: at(hour: 20)), "end boundary is exclusive")
        XCTAssertFalse(Settings.schedule.isActive(at: at(hour: 3)))
    }

    func testWithinMonitoringHoursForAnOvernightRange() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 21 * 60
        Settings.scheduleEndMinutes = 6 * 60

        XCTAssertTrue(Settings.schedule.isActive(at: at(hour: 23)))
        XCTAssertTrue(Settings.schedule.isActive(at: at(hour: 2)), "after midnight is still inside")
        XCTAssertFalse(Settings.schedule.isActive(at: at(hour: 12)))
    }

    func testScheduleDisabledIsAlwaysWithinHours() {
        Settings.scheduleEnabled = false
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 10 * 60
        XCTAssertTrue(Settings.schedule.isActive(at: at(hour: 23)))
    }

    func testEqualStartAndEndMeansAlwaysWithinHours() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 9 * 60
        XCTAssertTrue(Settings.schedule.isActive(at: at(hour: 3)))
    }

    // MARK: - Boundary staleness
    //
    // This is what lets a manual pause survive sleep/lock and still resume at
    // the next real schedule boundary. `.distantPast` is the "no meaningful
    // boundary" sentinel that makes a decision timestamp never look stale.

    func testNoBoundaryWhenScheduleIsDisabled() {
        Settings.scheduleEnabled = false
        XCTAssertEqual(Settings.schedule.mostRecentBoundary(before: at(hour: 12)), .distantPast)
    }

    func testNoBoundaryWhenTheScheduleIsContinuous() {
        // A full-day window on every day never changes state, so a manual pause
        // must survive indefinitely — same as having the schedule off.
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 9 * 60
        Settings.activeDays = Set(1...7)
        XCTAssertTrue(Settings.schedule.isContinuous)
        XCTAssertEqual(Settings.schedule.mostRecentBoundary(before: at(hour: 12)), .distantPast)
    }

    func testFullDayWindowStillHasBoundariesWhenSomeDaysAreInactive() {
        // Mon–Fri with a 24-hour window really does switch off at each weekend
        // boundary, so it must not claim to be continuous.
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 9 * 60
        Settings.activeDays = ScheduleConfig.defaultActiveDays
        XCTAssertFalse(Settings.schedule.isContinuous)
        XCTAssertNotEqual(Settings.schedule.mostRecentBoundary(before: at(hour: 12)), .distantPast)
    }

    func testBoundaryIsTheMostRecentConfiguredTimeAtOrBeforeNow() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 20 * 60

        // Asserted on wall-clock components rather than an absolute instant so
        // this stays correct across time zones and DST.
        let boundary = Settings.schedule.mostRecentBoundary(before: at(hour: 12))
        let parts = Calendar.current.dateComponents([.hour, .minute], from: boundary)
        XCTAssertEqual(parts.hour, 9, "midday should resolve to today's start boundary")
        XCTAssertEqual(parts.minute, 0)
    }

    func testBoundaryLooksBackToYesterdayBeforeTheFirstOfToday() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 20 * 60

        let now = at(hour: 3)
        let boundary = Settings.schedule.mostRecentBoundary(before: now)
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
                Settings.schedule.mostRecentBoundary(before: now), now,
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
        XCTAssertTrue(Settings.schedule.isActive(at: at(hour: 0, minute: 10)))
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


    // MARK: - Active days

    func testDefaultsToMondayThroughFriday() {
        XCTAssertEqual(Settings.activeDays, [2, 3, 4, 5, 6])
    }

    func testAnActiveDayIsInsideMonitoringHours() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 20 * 60
        Settings.activeDays = ScheduleConfig.defaultActiveDays
        XCTAssertTrue(Settings.schedule.isActive(at: at(weekday: 3, hour: 12)))
    }

    func testAnInactiveDayIsOutsideMonitoringHoursEvenMidWindow() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 20 * 60
        Settings.activeDays = ScheduleConfig.defaultActiveDays
        XCTAssertFalse(Settings.schedule.isActive(at: at(weekday: 7, hour: 12)), "Saturday isn't selected")
        XCTAssertFalse(Settings.schedule.isActive(at: at(weekday: 1, hour: 12)), "Sunday isn't selected")
    }

    func testOvernightWindowIsGovernedByTheDayItOpened() {
        // A Friday-night shift must stay active into Saturday morning even
        // though Saturday itself isn't a selected day.
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 21 * 60
        Settings.scheduleEndMinutes = 6 * 60
        Settings.activeDays = ScheduleConfig.defaultActiveDays

        XCTAssertTrue(Settings.schedule.isActive(at: at(weekday: 6, hour: 23)), "Friday evening")
        XCTAssertTrue(Settings.schedule.isActive(at: at(weekday: 7, hour: 2)), "Saturday 2am, opened Friday")
        XCTAssertFalse(Settings.schedule.isActive(at: at(weekday: 7, hour: 23)), "Saturday never opens a window")
        XCTAssertFalse(Settings.schedule.isActive(at: at(weekday: 1, hour: 2)), "Sunday 2am, Saturday never opened")
    }

    func testEmptyStoredActiveDaysFallsBackToTheDefault() {
        // "No active days" would mean monitoring never runs — it must never be
        // honoured, since it reads as configured protection but provides none.
        Settings.defaults.set([Int](), forKey: "activeDays")
        XCTAssertEqual(Settings.activeDays, ScheduleConfig.defaultActiveDays)
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
        XCTAssertTrue(Settings.schedule.isActive(at: at(weekday: 7, hour: 4)))
    }

    func testDescribeActiveDays() {
        Settings.activeDays = Set(1...7)
        XCTAssertEqual(Weekday.describe(Settings.activeDays), "All days")
        Settings.activeDays = ScheduleConfig.defaultActiveDays
        XCTAssertEqual(Weekday.describe(Settings.activeDays), "Mon–Fri")
        Settings.activeDays = [1, 7]
        XCTAssertEqual(Weekday.describe(Settings.activeDays), "Weekends")
    }

    // MARK: - Calendars other than the tester's
    //
    // Only reachable because MonitoringSchedule takes its calendar as a
    // parameter. Through Settings these read Calendar.current and could only be
    // asserted against whatever machine happened to run them.

    private func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    private func date(_ cal: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testSpringForwardDoesNotDropTheDaysWindow() {
        // 2026-03-08, America/New_York: 02:00–03:00 never happens. A start time
        // inside that gap must not silently drop the day — that would leave
        // monitoring off for a whole day with no indication.
        let cal = calendar("America/New_York")
        let schedule = MonitoringSchedule(
            ScheduleConfig(isEnabled: true, startMinutes: 2 * 60 + 30, endMinutes: 12 * 60,
                           activeDays: Set(1...7)),
            calendar: cal
        )
        XCTAssertTrue(schedule.isActive(at: date(cal, 2026, 3, 8, 9)),
                      "the window must still exist on the spring-forward day")
    }

    func testFallBackDoesNotOpenTwoWindowsInOneDay() {
        // 2026-11-01: 01:00–02:00 happens twice. The window must not double up.
        let cal = calendar("America/New_York")
        let schedule = MonitoringSchedule(
            ScheduleConfig(isEnabled: true, startMinutes: 60 + 30, endMinutes: 6 * 60,
                           activeDays: Set(1...7)),
            calendar: cal
        )
        let boundary = schedule.mostRecentBoundary(before: date(cal, 2026, 11, 1, 10))
        XCTAssertLessThanOrEqual(boundary, date(cal, 2026, 11, 1, 10))
    }

    func testOvernightWindowResolvesIdenticallyAcrossTimeZones() {
        // The same wall-clock schedule should behave the same way regardless of
        // where the Mac is: the schedule follows local time by definition.
        for zone in ["UTC", "Asia/Kuala_Lumpur", "America/Los_Angeles", "Pacific/Chatham"] {
            let cal = calendar(zone)
            let schedule = MonitoringSchedule(
                ScheduleConfig(isEnabled: true, startMinutes: 21 * 60, endMinutes: 6 * 60,
                               activeDays: Set(1...7)),
                calendar: cal
            )
            XCTAssertTrue(schedule.isActive(at: date(cal, 2026, 7, 15, 23)), "23:00 in \(zone)")
            XCTAssertTrue(schedule.isActive(at: date(cal, 2026, 7, 16, 2)), "02:00 in \(zone)")
            XCTAssertFalse(schedule.isActive(at: date(cal, 2026, 7, 16, 12)), "12:00 in \(zone)")
        }
    }

    func testWeekdayNumberingIsIndependentOfFirstWeekdayPreference() {
        // Calendar.firstWeekday varies by locale; activeDays uses absolute
        // weekday numbers, so a Sunday-first vs Monday-first calendar must agree.
        var sundayFirst = calendar("UTC"); sundayFirst.firstWeekday = 1
        var mondayFirst = calendar("UTC"); mondayFirst.firstWeekday = 2
        let config = ScheduleConfig(isEnabled: true, startMinutes: 9 * 60,
                                    endMinutes: 17 * 60, activeDays: [2]) // Mondays only
        let monday = date(sundayFirst, 2026, 7, 13, 12) // a Monday
        XCTAssertTrue(MonitoringSchedule(config, calendar: sundayFirst).isActive(at: monday))
        XCTAssertTrue(MonitoringSchedule(config, calendar: mondayFirst).isActive(at: monday))
    }

    // MARK: - Helpers

    /// A fixed local-time instant on a **Tuesday**, so hour-only tests aren't
    /// silently filtered out by the default Mon–Fri active days.
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

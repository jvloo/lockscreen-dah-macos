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

    func testCountdownPreservesZeroAsInstant() {
        Settings.countdownDuration = 0
        XCTAssertEqual(Settings.countdownDuration, 0)
        XCTAssertTrue(Settings.locksInstantly)
    }

    func testCountdownClampsNegativesUpInsteadOfTreatingThemAsInstant() {
        // A tampered negative must not silently become the most aggressive
        // setting available.
        Settings.defaults.set(-5.0, forKey: "countdownDuration")
        XCTAssertGreaterThan(Settings.countdownDuration, 0)
        XCTAssertFalse(Settings.locksInstantly)
    }

    func testEveryOfferedCountdownSurvivesTheClampUnchanged() {
        for option in Settings.countdownOptions {
            Settings.countdownDuration = option
            XCTAssertEqual(Settings.countdownDuration, option)
        }
    }

    func testLocksInstantlyOnlyAtExactlyZero() {
        Settings.countdownDuration = 3
        XCTAssertFalse(Settings.locksInstantly)
        Settings.countdownDuration = 0
        XCTAssertTrue(Settings.locksInstantly)
    }

    // MARK: - Camera rest availability

    func testCameraRestIsUnavailableAtTheShortestCountdownDelay() {
        Settings.gracePeriod = 1
        XCTAssertFalse(Settings.cameraRestAvailable, "the menu greys the idle rows out on this")

        Settings.gracePeriod = Settings.cameraRestMinimumGrace
        XCTAssertTrue(Settings.cameraRestAvailable)
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

    func testNoBoundaryWhenStartEqualsEnd() {
        Settings.scheduleEnabled = true
        Settings.scheduleStartMinutes = 9 * 60
        Settings.scheduleEndMinutes = 9 * 60
        XCTAssertEqual(Settings.mostRecentBoundary(before: at(hour: 12)), .distantPast)
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

    // MARK: - Display

    func testFormatMinutesUsesATwelveHourClock() {
        XCTAssertEqual(Settings.formatMinutes(0), "12:00 AM")
        XCTAssertEqual(Settings.formatMinutes(9 * 60), "9:00 AM")
        XCTAssertEqual(Settings.formatMinutes(12 * 60), "12:00 PM")
        XCTAssertEqual(Settings.formatMinutes(20 * 60 + 30), "8:30 PM")
        XCTAssertEqual(Settings.formatMinutes(23 * 60 + 5), "11:05 PM")
    }

    // MARK: - Helpers

    /// A fixed local-time instant today, so schedule maths is exercised against
    /// the same `Calendar.current` the production code uses.
    private func at(hour: Int, minute: Int = 0) -> Date {
        let today = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: today)!
    }
}

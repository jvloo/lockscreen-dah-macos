import Foundation

/// When monitoring should run, as plain data. Separated from where it is stored
/// so the resolution below can be exercised without touching UserDefaults.
struct ScheduleConfig: Equatable {
    /// When false the schedule imposes nothing and monitoring is always active.
    var isEnabled: Bool
    /// Minutes since local midnight.
    var startMinutes: Int
    var endMinutes: Int
    /// `Calendar` weekday numbering: 1 = Sunday through 7 = Saturday.
    var activeDays: Set<Int>

    static let defaultActiveDays: Set<Int> = [2, 3, 4, 5, 6] // Mon–Fri
}

/// Resolves an hour range plus a weekday selection into concrete monitoring
/// windows, and answers the only two questions the app asks of a schedule:
/// "should monitoring be running now" and "when did the schedule last change".
///
/// Both answers come from the *same* window enumeration on purpose. They were
/// once computed by separate arithmetic and could disagree, which is the class of
/// bug that let a manual pause be overridden at a moment nothing had changed.
///
/// The calendar is injected rather than read from `Calendar.current`, so DST
/// transitions, time zones and first-day-of-week differences are testable.
struct MonitoringSchedule {
    private let config: ScheduleConfig
    private let calendar: Calendar

    init(_ config: ScheduleConfig, calendar: Calendar = .current) {
        self.config = config
        self.calendar = calendar
    }

    /// Length of one window. Start == end is rejected by the settings panel — it
    /// has no single honest reading, a whole day or none of it — so treating it
    /// as a full day here only covers a tampered stored value.
    private var windowMinutes: Int {
        let span = (config.endMinutes - config.startMinutes + 1440) % 1440
        return span == 0 ? 1440 : span
    }

    /// True when the schedule never actually changes state: every day selected
    /// and a full-day window. Such a schedule has no boundaries at all, so a
    /// manual pause must survive it indefinitely.
    var isContinuous: Bool { windowMinutes == 1440 && config.activeDays.count == 7 }

    /// Whether monitoring should be active at `now`.
    func isActive(at now: Date) -> Bool {
        guard config.isEnabled else { return true }
        return windows(around: now).contains { now >= $0.open && now < $0.close }
    }

    /// The most recent instant the schedule changed state, at or before `now`.
    /// `.distantPast` means there is no meaningful boundary — disabled, or
    /// continuous — so a caller comparing a decision timestamp is never stale.
    func mostRecentBoundary(before now: Date) -> Date {
        guard config.isEnabled, !isContinuous else { return .distantPast }
        return windows(around: now)
            .flatMap { [$0.open, $0.close] }
            .filter { $0 <= now }
            .max() ?? .distantPast
    }

    /// Windows near `now`, merged so a contiguous stretch exposes no interior
    /// edge. Merging matters: without it, every-day-selected with a 24-hour range
    /// would show a spurious boundary at each midnight and override a manual
    /// pause when nothing had actually changed.
    ///
    /// A window belongs to the day it *opened* on, so a Friday 21:00–06:00 shift
    /// stays active into Saturday morning even when Saturday isn't selected —
    /// which is what anyone setting an overnight range means.
    private func windows(around now: Date) -> [(open: Date, close: Date)] {
        let today = calendar.startOfDay(for: now)
        let duration = TimeInterval(windowMinutes) * 60

        // A day ahead and eight back covers "the window that opened yesterday and
        // is still running", plus enough history for the boundary lookup after a
        // multi-day sleep.
        let raw: [(open: Date, close: Date)] = (-8...1).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  config.activeDays.contains(calendar.component(.weekday, from: day)),
                  let open = calendar.date(
                      bySettingHour: config.startMinutes / 60,
                      minute: config.startMinutes % 60,
                      second: 0,
                      of: day
                  )
            else { return nil }
            return (open, open.addingTimeInterval(duration))
        }

        return raw.sorted { $0.open < $1.open }.reduce(into: []) { merged, window in
            if let last = merged.last, window.open <= last.close {
                merged[merged.count - 1].close = max(last.close, window.close)
            } else {
                merged.append(window)
            }
        }
    }
}

// MARK: - Weekday presentation

/// Naming and ordering for weekdays, kept beside the schedule they describe.
enum Weekday {
    /// Work weeks read Monday-first, whereas `Calendar` numbers Sunday as 1.
    static let displayOrder = [2, 3, 4, 5, 6, 7, 1]

    static func name(_ weekday: Int, calendar: Calendar = .current) -> String {
        let symbols = calendar.shortWeekdaySymbols // index 0 == Sunday
        guard (1...7).contains(weekday) else { return "?" }
        return symbols[weekday - 1]
    }

    /// Compact description for the menu: "All days", "Mon–Fri", "Weekends", or a
    /// comma list.
    static func describe(_ days: Set<Int>, calendar: Calendar = .current) -> String {
        if days.count == 7 { return "All days" }
        if days == ScheduleConfig.defaultActiveDays { return "Mon–Fri" }
        if days == [1, 7] { return "Weekends" }
        return displayOrder.filter(days.contains)
            .map { name($0, calendar: calendar) }
            .joined(separator: ", ")
    }
}

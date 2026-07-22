import Foundation

enum Settings {
    private static let defaults = UserDefaults.standard

    /// Single point for the "stored value or default" read every setting uses.
    private static func value<T>(forKey key: String, default fallback: T) -> T {
        defaults.object(forKey: key) as? T ?? fallback
    }

    /// How long the owner's face must be absent before the countdown overlay appears.
    static var gracePeriod: TimeInterval {
        get { value(forKey: "gracePeriod", default: 3) }
        set { defaults.set(newValue, forKey: "gracePeriod") }
    }

    /// Length of the on-screen countdown before the screen locks.
    static var countdownDuration: TimeInterval {
        get { value(forKey: "countdownDuration", default: 3) }
        set { defaults.set(newValue, forKey: "countdownDuration") }
    }

    /// Sustained typing/mouse use required before the camera goes idle.
    /// 0 = never idle (the camera always watches).
    static var cameraRestAfter: TimeInterval {
        get { value(forKey: "cameraRestAfter", default: 10) }
        set { defaults.set(newValue, forKey: "cameraRestAfter") }
    }

    /// Typing pause that wakes an idle camera. Larger = the camera sleeps
    /// through natural typing pauses (more savings), but departure detection
    /// is delayed by up to this long after the last keystroke.
    static var cameraWakeQuiet: TimeInterval {
        get { value(forKey: "cameraWakeQuiet", default: 2) }
        set { defaults.set(newValue, forKey: "cameraWakeQuiet") }
    }

    /// Cosine-similarity threshold for "this face is the owner".
    /// Crops are landmark-aligned, so genuine matches typically score 0.6+;
    /// the lenient default leaves room for the unaligned bounding-box
    /// fallback used when landmarks fail (e.g. strong profile views).
    /// Clamped to a sane band so a stray/tampered defaults value can't turn
    /// matching into "everyone passes" (≤ 0) or "no one ever does" (> 1).
    static var matchThreshold: Float {
        get { min(max(value(forKey: "matchThreshold", default: 0.35), 0.2), 0.9) }
        set { defaults.set(newValue, forKey: "matchThreshold") }
    }

    // MARK: - Monitoring hours (follows system time)

    /// When enabled, monitoring auto-starts/pauses at the configured times;
    /// when disabled, monitoring is always on unless the user pauses it.
    static var scheduleEnabled: Bool {
        get { value(forKey: "scheduleEnabled", default: true) }
        set { defaults.set(newValue, forKey: "scheduleEnabled") }
    }

    /// Minutes since midnight, local time.
    static var scheduleStartMinutes: Int {
        get { value(forKey: "scheduleStartMinutes", default: 9 * 60) }
        set { defaults.set(newValue, forKey: "scheduleStartMinutes") }
    }

    static var scheduleEndMinutes: Int {
        get { value(forKey: "scheduleEndMinutes", default: 20 * 60) }
        set { defaults.set(newValue, forKey: "scheduleEndMinutes") }
    }

    /// True when monitoring should be active right now. Supports overnight
    /// ranges (end before start, e.g. 21:00–06:00). Always true when the
    /// schedule is disabled.
    static func withinMonitoringHours(now: Date = Date()) -> Bool {
        guard scheduleEnabled else { return true }
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let start = scheduleStartMinutes
        let end = scheduleEndMinutes
        if start == end { return true }
        return start < end
            ? (minutes >= start && minutes < end)
            : (minutes >= start || minutes < end)
    }

    /// The most recent schedule boundary (start- or end-of-hours instant) at
    /// or before `now`. Looks back through yesterday's boundaries too, so
    /// overnight ranges (e.g. 21:00–06:00) and the hours right after
    /// midnight resolve correctly. Returns `.distantPast` when there's no
    /// meaningful boundary — schedule disabled, or start == end (the
    /// "always within" case above) — so a caller comparing a decision
    /// timestamp against this is never "stale".
    static func mostRecentBoundary(before now: Date = Date()) -> Date {
        guard scheduleEnabled, scheduleStartMinutes != scheduleEndMinutes else { return .distantPast }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let boundaries = [yesterday, today].flatMap { day in
            [scheduleStartMinutes, scheduleEndMinutes].compactMap { minutes in
                calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
            }
        }
        return boundaries.filter { $0 <= now }.max() ?? .distantPast
    }

    // MARK: - Update check (About panel)

    /// When the "Check for Update" action last ran, so reopening About
    /// reflects the last result without a fresh network call.
    static var lastUpdateCheckAt: Date? {
        get { defaults.object(forKey: "lastUpdateCheckAt") as? Date }
        set { defaults.set(newValue, forKey: "lastUpdateCheckAt") }
    }

    /// The version tag found at the last check, if newer than the running
    /// app. `nil` means the last check found nothing newer (or never ran).
    static var lastUpdateCheckNewerVersion: String? {
        get { defaults.string(forKey: "lastUpdateCheckNewerVersion") }
        set { defaults.set(newValue, forKey: "lastUpdateCheckNewerVersion") }
    }

    /// 12-hour clock with AM/PM, matching what the time pickers display.
    static func formatMinutes(_ minutes: Int) -> String {
        let hour24 = minutes / 60
        let minute = minutes % 60
        var hour12 = hour24 % 12
        if hour12 == 0 { hour12 = 12 }
        let period = hour24 < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", hour12, minute, period)
    }

    /// Both duration pickers offer the same steps — one source so they can't drift.
    static let gracePeriodOptions: [TimeInterval] = [1, 3, 5, 10, 15, 30]
    static let countdownOptions: [TimeInterval] = gracePeriodOptions
    /// 0 renders as "Never Idle".
    static let cameraRestOptions: [TimeInterval] = [5, 10, 15, 30, 0]
    static let cameraWakeOptions: [TimeInterval] = [1, 2, 3, 5, 10]
}

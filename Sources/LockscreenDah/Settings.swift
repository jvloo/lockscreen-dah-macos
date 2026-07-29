import Foundation

enum Settings {
    /// Overridable purely so tests can point at a scratch suite instead of the
    /// real user defaults; production code never reassigns it.
    static var defaults = UserDefaults.standard

    /// Single point for the "stored value or default" read every setting uses.
    private static func value<T>(forKey key: String, default fallback: T) -> T {
        defaults.object(forKey: key) as? T ?? fallback
    }

    /// Both deadlines below are armed as precise one-shot timers, so a stray or
    /// tampered defaults value of 0 (or negative) would schedule a fire date in
    /// the past and spin the run loop, rebuilding the overlay every pass. The
    /// old polling implementation floored these implicitly; clamping restores
    /// that guarantee explicitly. Same reasoning as `matchThreshold` below.
    private static let durationBounds = (min: 0.5, max: 600.0)

    /// How long the owner's face must be absent before the countdown overlay appears.
    static var gracePeriod: TimeInterval {
        get { min(max(value(forKey: "gracePeriod", default: 3), durationBounds.min), durationBounds.max) }
        set { defaults.set(newValue, forKey: "gracePeriod") }
    }

    /// Length of the on-screen countdown before the screen locks. Exactly 0 is
    /// meaningful — "Instant", lock with no countdown at all — so it survives
    /// the clamp; anything else below the floor (including a negative, which
    /// must not silently become the most aggressive setting) is clamped up.
    static var countdownDuration: TimeInterval {
        get {
            let stored: TimeInterval = value(forKey: "countdownDuration", default: 3)
            if stored == 0 { return 0 }
            return min(max(stored, durationBounds.min), durationBounds.max)
        }
        set { defaults.set(newValue, forKey: "countdownDuration") }
    }

    /// True when the countdown is disabled entirely (lock on presence lapse).
    static var locksInstantly: Bool { countdownDuration == 0 }

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

    // MARK: - Login item

    /// The user's chosen intent for "Open at Login" — tracked separately
    /// from `SMAppService.mainApp.status`, which reflects only the currently
    /// installed build: reinstalling the app re-signs it, and the OS-level
    /// registration doesn't reliably carry over. This is what lets the app
    /// reconcile the real registration against the user's actual preference
    /// on every launch instead of just the first one.
    static var openAtLoginEnabled: Bool {
        get { value(forKey: "openAtLoginEnabled", default: true) }
        set { defaults.set(newValue, forKey: "openAtLoginEnabled") }
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

    /// The two duration pickers deliberately do NOT share a list. They look
    /// like the same quantity but aren't: detection delay is a preference
    /// (aggressive is legitimate), whereas a countdown too short to be
    /// cancelled is simply a broken control — the cancel path needs ~1 s
    /// (overlay fade, you noticing, the next analyzed frame, the embedding),
    /// so the countdown floor is 3 s while detection goes down to 1 s.
    static let gracePeriodOptions: [TimeInterval] = [1, 3, 5, 10]
    /// 0 renders as "Instant": lock the moment presence lapses, no overlay.
    static let countdownOptions: [TimeInterval] = [3, 5, 10, 0]
    /// 0 renders as "Never Idle".
    static let cameraRestOptions: [TimeInterval] = [10, 20, 30, 0]
    static let cameraWakeOptions: [TimeInterval] = [1, 2, 3, 5]

    /// Camera rest is unavailable below this countdown delay: waking the
    /// camera and landing one fresh match needs about a second, which a 1 s
    /// delay can't absorb — the overlay would flash at a seated user after
    /// every typing pause. The menu disables the idle rows below it and says
    /// so, rather than accepting the setting and silently ignoring it.
    static let cameraRestMinimumGrace: TimeInterval = 3

    /// Whether camera rest can operate at the current countdown delay.
    static var cameraRestAvailable: Bool { gracePeriod >= cameraRestMinimumGrace }
}

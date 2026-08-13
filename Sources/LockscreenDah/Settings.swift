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

    /// How long the owner's face must be absent before the countdown overlay
    /// appears. Defaults to the shortest offered value: this is a security tool,
    /// and it shouldn't ship a weaker default than the one it recommends. The
    /// cost is CPU, not reliability — the analysis cadence scales with this
    /// setting (`delay/4`), so roughly four detection attempts fit inside the
    /// window at *any* value, and only the absolute recovery time shrinks.
    static var gracePeriod: TimeInterval {
        get { min(max(value(forKey: "gracePeriod", default: 1), durationBounds.min), durationBounds.max) }
        set { defaults.set(newValue, forKey: "gracePeriod") }
    }

    /// Length of the on-screen countdown before the screen locks. Exactly 0 is
    /// meaningful — "Never Countdown", lock with no countdown at all — so it survives
    /// the clamp; anything else below the floor (including a negative, which
    /// must not silently become the most aggressive setting) is clamped up.
    /// The Esc escape gesture is sized against this: three presses plus a Touch
    /// ID round trip do not fit in 0.5 s, so this floor is the shortest *offered*
    /// countdown rather than the shared duration minimum. `gracePeriod` keeps the
    /// generic duration minimum, which is deliberately lower.
    static let countdownFloor: TimeInterval = 3

    static var countdownDuration: TimeInterval {
        get {
            let stored: TimeInterval = value(forKey: "countdownDuration", default: 3)
            if stored == 0 { return 0 }
            return min(max(stored, countdownFloor), durationBounds.max)
        }
        set { defaults.set(newValue, forKey: "countdownDuration") }
    }

    /// True when the countdown is disabled entirely ("Never Countdown"):
    /// lock immediately on presence lapse, with no overlay and so no Esc.
    static var countdownDisabled: Bool { countdownDuration == 0 }

    /// Cosine-similarity threshold for "this face is the owner".
    ///
    /// Raised from 0.35 once enrollment covered turned and head-down poses:
    /// a held-out live frame scored 0.96 against a profile built that way, so
    /// the old bar sat far below anything the owner actually produces and gave
    /// that much more room to a stranger. Tightening trades one failure for the
    /// other, and the trade is deliberate — a missed match costs a lock screen,
    /// an accepted stranger costs the thing this app exists to prevent.
    /// Not raised further because the head-down pose is both the weakest scoring
    /// and the one held longest while typing, so it sets the real floor.
    /// Clamped to a sane band so a stray/tampered defaults value can't turn
    /// matching into "everyone passes" (≤ 0) or "no one ever does" (> 1).
    static var matchThreshold: Float {
        get { min(max(value(forKey: "matchThreshold", default: 0.45), 0.2), 0.9) }
        set { defaults.set(newValue, forKey: "matchThreshold") }
    }

    // MARK: - Monitoring schedule (follows system time)
    //
    // Persistence and validation only. The resolution of hours + days into
    // windows lives in `MonitoringSchedule`, which takes its calendar as a
    // parameter and so can be tested across time zones and DST.

    /// When enabled, monitoring auto-starts/pauses on the configured schedule;
    /// when disabled, monitoring is always on unless the user pauses it.
    static var scheduleEnabled: Bool {
        get { value(forKey: "scheduleEnabled", default: true) }
        set { defaults.set(newValue, forKey: "scheduleEnabled") }
    }

    /// Minutes since midnight, local time. Clamped to a real time of day: the
    /// window builder feeds these to `date(bySettingHour:)`, and an out-of-range
    /// hour returns nil there — which would silently drop the day's window and
    /// leave monitoring never starting at all.
    private static func clampMinutes(_ minutes: Int) -> Int { min(max(minutes, 0), 1439) }

    static var scheduleStartMinutes: Int {
        get { clampMinutes(value(forKey: "scheduleStartMinutes", default: 9 * 60)) }
        set { defaults.set(clampMinutes(newValue), forKey: "scheduleStartMinutes") }
    }

    static var scheduleEndMinutes: Int {
        get { clampMinutes(value(forKey: "scheduleEndMinutes", default: 20 * 60)) }
        set { defaults.set(clampMinutes(newValue), forKey: "scheduleEndMinutes") }
    }

    /// Days the schedule is active on. A stored value that is empty or entirely
    /// invalid falls back to the default rather than being honoured: "no active
    /// days" would mean monitoring never runs, which reads as configured
    /// protection but provides none.
    static var activeDays: Set<Int> {
        get {
            guard let stored = defaults.array(forKey: "activeDays") as? [Int] else {
                return ScheduleConfig.defaultActiveDays
            }
            let valid = Set(stored.filter { (1...7).contains($0) })
            return valid.isEmpty ? ScheduleConfig.defaultActiveDays : valid
        }
        set {
            let valid = newValue.filter { (1...7).contains($0) }
            guard !valid.isEmpty else { return } // never persist "never run"
            defaults.set(valid.sorted(), forKey: "activeDays")
        }
    }

    static var scheduleConfig: ScheduleConfig {
        ScheduleConfig(
            isEnabled: scheduleEnabled,
            startMinutes: scheduleStartMinutes,
            endMinutes: scheduleEndMinutes,
            activeDays: activeDays
        )
    }

    /// The live schedule. Cheap to build, so callers read it fresh rather than
    /// caching a copy that could drift from the stored settings.
    static var schedule: MonitoringSchedule { MonitoringSchedule(scheduleConfig) }

    /// Locks fired with no successful face match in between. Persisted on
    /// purpose: every iteration of a lock loop passes through a screen lock, and
    /// possibly a relaunch, so an in-memory counter would keep resetting and
    /// never notice the loop it exists to detect. Any real match clears it.
    static var consecutiveLocksWithoutMatch: Int {
        // Clamped like every other control: a stored negative would make the
        // ">= threshold" test unreachable and silently remove the only failsafe
        // protecting against a "Never Countdown" lock loop. Saturated on write so
        // it can't grow without bound either.
        get { min(max(value(forKey: "consecutiveLocksWithoutMatch", default: 0), 0), 1000) }
        set { defaults.set(min(max(newValue, 0), 1000), forKey: "consecutiveLocksWithoutMatch") }
    }

    // MARK: - Re-enrollment requirement

    /// Set when repeated Esc-rescues were confirmed by the Mac's own
    /// authentication: recognition has demonstrably stopped matching the owner,
    /// so monitoring must not silently resume on a schedule boundary or an
    /// unlock. Persisted, so quitting and relaunching can't clear it. The
    /// existing face profile stays usable until a new one is saved.
    static var reenrollmentRequired: Bool {
        get { value(forKey: "reenrollmentRequired", default: false) }
        set { defaults.set(newValue, forKey: "reenrollmentRequired") }
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
    /// 0 renders as "Never Countdown": lock the moment presence lapses, with
    /// no overlay at all. Mirrors "Never Idle" below.
    static let countdownOptions: [TimeInterval] = [3, 5, 10, 0]

}

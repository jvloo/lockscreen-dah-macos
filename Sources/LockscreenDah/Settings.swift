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
    /// meaningful — "Never Countdown", lock with no countdown at all — so it survives
    /// the clamp; anything else below the floor (including a negative, which
    /// must not silently become the most aggressive setting) is clamped up.
    /// The Esc escape gesture is sized against this: three presses plus a Touch
    /// ID round trip do not fit in 0.5 s, so this floor is the shortest *offered*
    /// countdown rather than the shared duration minimum. `gracePeriod` keeps the
    /// lower shared floor deliberately, so `cameraRestAvailable` can go false.
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

    /// Sustained typing/mouse use required before the camera goes idle.
    /// Exactly 0 means "Never Idle" (the camera always watches) and survives the
    /// clamp; any other out-of-range value is pulled back in, since a tiny or
    /// negative value would rest the camera almost immediately.
    static var cameraRestAfter: TimeInterval {
        get {
            let stored: TimeInterval = value(forKey: "cameraRestAfter", default: 10)
            if stored == 0 { return 0 }
            return min(max(stored, 1), durationBounds.max)
        }
        set { defaults.set(newValue, forKey: "cameraRestAfter") }
    }

    /// Typing pause that wakes an idle camera. Larger = the camera sleeps
    /// through natural typing pauses (more savings), but departure detection
    /// is delayed by up to this long after the last keystroke.
    /// Clamped: 0 or negative would mean the camera can never rest (every tick
    /// reads as "input has gone quiet"), and an enormous value would leave it
    /// blind for that long. Both are silently broken rather than useful.
    static var cameraWakeQuiet: TimeInterval {
        get { min(max(value(forKey: "cameraWakeQuiet", default: 2), 0.5), 60) }
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
    /// 0 renders as "Never Idle".
    static let cameraRestOptions: [TimeInterval] = [10, 20, 30, 0]
    static let cameraWakeOptions: [TimeInterval] = [1, 2, 3, 5]

    /// Camera rest is unavailable below this countdown delay. Waking from rest
    /// is an identity gate, so you must land one fresh match inside the delay
    /// or get a blackout — and the session was fully stopped, so auto-exposure
    /// has to re-converge from cold and the first frame or two are often
    /// unusable. (Session spin-up itself no longer counts against the delay;
    /// the grace clock starts at the first delivered frame.) At 1 s that leaves
    /// roughly three attempts. Set to 1 so idling is offered at every delay the
    /// menu exposes — but on watch, for two reasons documented in
    /// docs/TESTING.md: auto-exposure re-converging from a cold session start
    /// can miss those attempts and flash the overlay at a seated user, and
    /// resting the camera opens a blind window at the very setting someone picks
    /// for vigilance. Choose "Never Idle" to keep continuous coverage. Below 1 s
    /// (reachable only via `defaults write`) the menu disables the idle rows and
    /// says why, rather than accepting the setting and silently ignoring it.
    static let cameraRestMinimumGrace: TimeInterval = 1

    /// Whether camera rest can operate at the current countdown delay.
    static var cameraRestAvailable: Bool { gracePeriod >= cameraRestMinimumGrace }
}

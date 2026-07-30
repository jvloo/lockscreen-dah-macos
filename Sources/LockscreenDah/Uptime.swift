import Foundation

/// Monotonic seconds since boot, for every deadline the app *enforces*.
///
/// `Date` is wall-clock: a forward step (a manual date change, or `timed`
/// stepping rather than slewing an NTP correction) makes "now" jump, which used
/// to fire the countdown and the lock that much early — and both defensive
/// re-checks were written against the same shifted clock, so neither could
/// catch it. This can't be stepped.
///
/// Deliberately *not* used for Active Hours: that schedule is wall-clock by
/// definition, and if the system time changes the schedule should follow it.
/// The split is the point — enforced durations are monotonic, calendar times
/// stay on `Date`.
///
/// Like `DispatchTime` (which the two deadline timers are scheduled against),
/// this does not advance while the machine is asleep. That's consistent rather
/// than a gap: display sleep already stops both timers and re-anchors presence
/// on wake.
enum Uptime {
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

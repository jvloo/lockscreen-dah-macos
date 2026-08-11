import Foundation

/// A one-shot timer that fires at a monotonic deadline.
///
/// Deliberately not `Timer`: `Timer(fire: Date)` stores a wall-clock fire date,
/// so a forward system-clock step fired the countdown and the lock that much
/// early. Scheduling a *delay* off `DispatchTime` — which shares the monotonic
/// clock `Uptime` reads — can't be stepped.
///
/// Both deadlines the app enforces use this, so the conversion the whole fix
/// rests on exists once rather than being duplicated per timer.
final class DeadlineTimer {
    private var timer: DispatchSourceTimer?
    private let onFire: () -> Void

    /// `onFire` runs on the main queue.
    init(onFire: @escaping () -> Void) {
        self.onFire = onFire
    }

    deinit { timer?.cancel() }

    /// Arms (or re-arms) the timer for `deadline`, an `Uptime` instant. A
    /// deadline already in the past fires on the next main-queue pass, which is
    /// the correct outcome — the moment has simply already arrived.
    func schedule(at deadline: TimeInterval) {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + max(0, deadline - Uptime.now))
        source.setEventHandler { [onFire] in onFire() }
        source.resume()
        timer = source
    }

    func cancel() {
        timer?.cancel()
        timer = nil
    }

    var isScheduled: Bool { timer != nil }
}

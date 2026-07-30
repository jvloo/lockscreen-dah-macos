import AppKit
import AVFoundation
import CoreGraphics
import LocalAuthentication

/// Owns the presence state machine. All state transitions happen on the main thread.
final class MonitorCoordinator {
    enum State: Equatable {
        case paused
        case watching
        case alerting(deadline: TimeInterval)
        case locked
        case enrolling
    }

    private(set) var state: State = .paused {
        didSet { onStateChange?() }
    }
    var onStateChange: (() -> Void)?

    let recognizer = FaceRecognizer()
    private lazy var monitor: FaceMonitor = {
        let monitor = FaceMonitor(recognizer: recognizer)
        monitor.onResult = { [weak self] result in
            DispatchQueue.main.async { self?.handleDetection(result) }
        }
        return monitor
    }()
    private let overlay = CountdownOverlay()
    private lazy var enrollment: EnrollmentController = {
        let controller = EnrollmentController(recognizer: recognizer, monitor: monitor)
        controller.onFinished = { [weak self] in self?.enrollmentFinished() }
        controller.onProfileCommitted = { [weak self] in
            // A freshly saved profile is exactly what the requirement was
            // waiting for, and is also the condition for resuming.
            Settings.reenrollmentRequired = false
            Settings.consecutiveLocksWithoutMatch = 0 // fresh profile, clean slate
            self?.resumeAfterEnrollment = true
        }
        return controller
    }()

    private var tickTimer: Timer?
    /// Precise one-shot timer for firing the countdown exactly at the grace
    /// deadline — see `rescheduleGraceTimer()`. The 1 Hz `tickTimer` above
    /// only adjusts sampling rate and camera-rest bookkeeping now; it no
    /// longer decides when to alert, since polling once a second can report
    /// an expired grace period up to ~1 s late.
    private var graceTimer: DispatchSourceTimer?
    /// Precise one-shot timer that fires the lock at the countdown deadline.
    /// Same reasoning as `graceTimer`: the 0.25 s `tickTimer` is for redrawing
    /// the overlay, and polling for the deadline on it landed the lock a
    /// measured ~0.13 s late on average (0.27 s worst case).
    private var lockTimer: DispatchSourceTimer?
    /// The seat-continuity chain — see PresenceTracker for the model.
    private var presence = PresenceTracker()
    /// When the capture session was last asked to start. A countdown deadline
    /// can fall inside session spin-up on a short grace period, and "no frames
    /// yet" then means "too early to tell", not "camera broken" — see
    /// `handleGraceExpired`.
    private var cameraStartedAt = -Double.infinity
    /// How long a session gets to deliver its first frame before absence of
    /// frames is treated as a real failure.
    private let cameraStartupAllowance: TimeInterval = 3

    // Camera rest: while the chain is established and the keyboard/mouse are
    // in sustained use, input alone proves presence — the capture session
    // (the app's entire CPU floor) sleeps until input goes quiet. Strangers
    // are unseen while it rests; the wake-on-quiet keeps that gap bounded by
    // how long anyone can type without pausing for the wake threshold.
    private(set) var cameraResting = false {
        didSet { if oldValue != cameraResting { onStateChange?() } }
    }
    private var inputActiveSince: TimeInterval?
    private var lastCameraWake = -Double.infinity
    /// When the current rest began, so it can be capped absolutely.
    private var restStartedAt: TimeInterval?
    /// Hard ceiling on one rest, or 0 to disable the cap.
    ///
    /// **Currently disabled (0), deliberately.** With a cap the blind window is
    /// bounded, because an intruder holding a key otherwise keeps input flowing —
    /// which is exactly what keeps the camera asleep, so their own activity
    /// sustains the blindness rather than ending it. But enforcing it means
    /// reopening the camera every N seconds forever, which costs a real duty
    /// cycle (~10-18% on at 10 s versus ~0%) and re-runs auto-exposure each time.
    /// The blind window is therefore unbounded again, and the answer to that
    /// threat is the "Never Idle" setting, which removes the window entirely at a
    /// steady CPU cost the user opts into knowingly. See docs/TESTING.md.
    ///
    /// Set this above 0 to re-enable; the peek machinery below is intact.
    private let cameraRestMaxDuration: TimeInterval = 0
    /// How long a forced wake looks for the owner before it becomes a real wake.
    /// A match inside this window returns straight to rest without serving
    /// `cameraMinAwake`, so re-verifying every 10 s stays cheap — otherwise the
    /// 20 s minimum would keep the camera awake two-thirds of the time and gut
    /// the feature.
    private let cameraPeekWindow: TimeInterval = 2
    /// Set while a forced wake is looking for the owner; nil during a normal wake.
    private var peekDeadline: TimeInterval?

    /// "Never Countdown" removes the overlay, and with it the Esc gesture — the
    /// only way out when recognition has stopped matching the owner. Being locked
    /// once is harmless: you log back in. Being locked again a second later,
    /// indefinitely, is a trap with no in-app way out. So once this many locks
    /// have fired with no match in between, a minimum countdown is forced back on
    /// purely so the escape gesture exists again.
    private let lockLoopThreshold = 2
    private let minimumEscapeCountdown: TimeInterval = 3

    /// The countdown length actually used: the setting, except while a lock loop
    /// is being detected.
    private var effectiveCountdownDuration: TimeInterval {
        guard Settings.consecutiveLocksWithoutMatch >= lockLoopThreshold else {
            return Settings.countdownDuration
        }
        return max(Settings.countdownDuration, minimumEscapeCountdown)
    }
    /// Sustained input required before the camera may rest (user-configurable).
    private var cameraRestAfter: TimeInterval { Settings.cameraRestAfter }
    /// Minimum awake time between rests, so bursty typing can't thrash the session.
    private let cameraMinAwake: TimeInterval = 20
    /// Input silence that wakes the camera back up (user-configurable).
    private var cameraWakeQuiet: TimeInterval { Settings.cameraWakeQuiet }
    /// Cadence while absence is suspected / countdown running. Deliberately
    /// below the sensor's frame period (capped at 3 fps, so 0.333 s) to make
    /// sure every captured frame is actually analyzed: the previous 0.4 s
    /// rounded up to two frame periods, silently discarding every other frame
    /// already paid for, which doubled both the countdown's timing error and
    /// the time needed to cancel one.
    private let fastAnalysisInterval: TimeInterval = 0.25
    /// Steady-state cadence while the presence chain is healthy. Scales with
    /// the countdown delay — a long delay doesn't need frequent sampling — and
    /// is capped at 2.5 s so the 3-frame stranger challenge always resolves
    /// within ~8 s of a stranger facing the screen. The divisor sets how many
    /// detection attempts fit inside the delay (~4), which is what keeps one
    /// bad frame from becoming a blackout.
    private var idleAnalysisInterval: TimeInterval {
        min(max(Settings.gracePeriod / 4, fastAnalysisInterval), 2.5)
    }

    /// Whether monitoring was active when enrollment began (restored after).
    private var resumeAfterEnrollment = false

    // Esc is the escape hatch for when recognition has failed the real owner, so
    // it must exist — but a single un-checked press would also be exactly what an
    // intruder wants. It takes three presses on the *same* overlay, which then
    // asks the Mac to verify who's pressing. Scoped per overlay (the shortest
    // countdown is 3 s, ample for three presses), so nothing carries over.
    private var escPressesThisAlert = 0
    private let escPressLimit = 3
    /// Set while the Touch ID prompt is up.
    private var authenticatingEscape = false
    /// Held so an unanswered prompt can be torn down when its grace expires.
    private var escapeAuthContext: LAContext?
    /// How long the lock may be *deferred* while the owner authenticates —
    /// bounded on purpose. Cancelling the lock outright meant a prompt nobody
    /// ever answered held the machine open indefinitely behind what looks like a
    /// sleeping display, which turned the escape hatch into an off switch.
    private let escapeAuthGrace: TimeInterval = 15
    /// Verification attempts allowed per overlay. Without a cap, every press
    /// after the third re-prompted, so an intruder could keep deferring.
    private var escapeAuthAttempts = 0
    private let escapeAuthAttemptLimit = 2

    // Monitoring hours: a light timer re-derives the correct state directly
    // from elapsed wall-clock time (see resolveSchedule/lastDecisionAt) rather
    // than edge-detecting the previous tick's value — that's what lets a
    // boundary crossed while asleep/locked still resolve correctly, and lets
    // lock/unlock resolution (resumeFromLocked) share the exact same rule.
    // Between boundaries the user's manual Start/Pause always wins (a manual
    // pause at 10:00 stays paused until tomorrow's start time).
    private var scheduleTimer: Timer?
    /// Wall-clock time of the last real "start watching" / "stop watching"
    /// decision — manual (menu toggle) or schedule-driven. A schedule
    /// boundary is acted on only once it postdates this; see
    /// `resolveSchedule`. `nil` until `startPerSchedule()` stamps it at launch.
    private var lastDecisionAt: Date?

    init() {
        overlay.onEscape = { [weak self] in self?.handleEscPress() }
        observeLockAndSleepEvents()
        startScheduleTimer()
    }

    // MARK: - Public controls

    func startMonitoring() {
        // An outstanding re-enrollment outranks every automatic start — schedule
        // boundary, unlock, display wake. Recognition has already been shown not
        // to match the owner, so resuming without a fresh profile would just
        // replay the same countdown-and-Esc cycle. Only the manual menu action
        // proceeds, and it routes into enrollment instead (see AppDelegate).
        guard !Settings.reenrollmentRequired else {
            state = .paused
            return
        }
        // Stamp before the (possibly async) permission check so a denial
        // still consumes this decision — otherwise the schedule timer would
        // retry (and re-alert) every ~30s. beginWatching() stamps again on
        // success; redundant but harmless.
        lastDecisionAt = Date()
        withCameraPermission { [weak self] in self?.beginWatching() }
    }

    /// Launch entry point. No prior decision exists yet to compare a boundary
    /// against, so this always acts on the live schedule directly.
    func startPerSchedule() {
        lastDecisionAt = Date()
        guard Settings.withinMonitoringHours() else {
            state = .paused // refreshes the status line to "off hours"
            return
        }
        ScreenLocker.sessionIsLocked ? enterLockedState() : startMonitoring()
    }

    /// Called when the user changes any monitoring-hours setting: enforce the
    /// new schedule immediately, regardless of lastDecisionAt — the user just
    /// explicitly asked to apply new hours.
    func scheduleSettingsChanged() {
        // Deliberately does NOT check `scheduleEnabled`. The panel writes that
        // flag before calling this, so ticking "Always on" — the one change that
        // *expands* coverage to 24/7 — used to guard itself out and leave the app
        // paused while the UI claimed it was always on. `withinMonitoringHours()`
        // already returns true when the schedule is off, so this does the right
        // thing either way.
        guard state != .enrolling else { return }
        applySchedule(within: Settings.withinMonitoringHours())
    }

    func pause() {
        guard state != .paused else { return }
        overlay.dismiss()
        cancelEscapeAuth()
        enrollment.abort()
        stopTick()
        stopGraceTimer()
        stopLockTimer()
        monitor.stop()
        cameraResting = false
        lastDecisionAt = Date() // a real "not watching" decision — see resolveSchedule
        state = .paused
    }

    var statusDescription: String {
        switch state {
        case .paused:
            if Settings.reenrollmentRequired { return "Paused (re-enrollment needed)" }
            if Settings.scheduleEnabled, !Settings.withinMonitoringHours() {
                // Distinguish the two reasons: "off hours" on a working day is
                // expected, whereas being paused because today isn't a selected
                // day is easy to forget you configured.
                let today = Calendar.current.component(.weekday, from: Date())
                return Settings.activeDays.contains(today)
                    ? "Paused (off hours)"
                    : "Paused (\(Settings.weekdayName(today)) not active)"
            }
            return "Paused"
        // Alerting/locked keep the watching text — the overlay or lock screen
        // is what the user sees; a special status would never be read.
        case .watching, .alerting, .locked:
            if recognizer.isPresenceOnly { return "Watching for any face" }
            return cameraResting ? "Idle while typing" : "Watching for you"
        case .enrolling: return "Enrolling face…"
        }
    }

    // MARK: - State transitions

    private func beginWatching() {
        overlay.dismiss()
        presence.reset()
        lastDecisionAt = Date() // a real "watching" decision — see resolveSchedule
        cameraResting = false
        inputActiveSince = nil
        lastCameraWake = Uptime.now
        monitor.analysisInterval = idleAnalysisInterval
        cameraStartedAt = Uptime.now
        monitor.start()
        startTick(interval: 1)
        state = .watching
        rescheduleGraceTimer()
        verifyCameraStarted()
    }

    /// `monitor.start()` spins up the capture session asynchronously and can
    /// fail silently (camera busy, a device-enumeration hiccup right after
    /// sleep/wake) — confirm a few seconds later that frames are genuinely
    /// arriving, otherwise the app would sit in `.watching`, reporting
    /// "Watching for you" with the camera never having come on: a false sense
    /// of safety, exactly what the fail-closed design elsewhere avoids.
    ///
    /// `.alerting` is checked too, not just `.watching`: a grace period at or
    /// under this allowance expires first, so by the time this runs the app
    /// may already be counting down off a camera that never started.
    private func verifyCameraStarted() {
        // Bound to the session it was scheduled for. Without this, a pending
        // check from an earlier session judges a newer one: Start, Pause, Start
        // within the allowance window had the first check fire against a
        // 1-second-old session, declare a perfectly good camera broken, and
        // leave monitoring paused — failing open, the one direction this app
        // must never fail in.
        let startedAt = cameraStartedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + cameraStartupAllowance) { [weak self] in
            guard let self, self.cameraStartedAt == startedAt else { return }
            guard self.state == .watching || self.isAlerting else { return }
            guard !self.monitor.hasDeliveredFrame else { return }
            self.reportCameraFailure()
        }
    }

    private var isAlerting: Bool {
        if case .alerting = state { return true }
        return false
    }

    private func reportCameraFailure() {
        pause()
        showAlert(
            title: "Camera failed to start",
            message: "Lockscreen Dah? could not start the camera, so your screen is NOT being watched. Monitoring has been paused. Try Start Monitoring again; if it keeps failing, check whether another app has the camera open."
        )
    }

    private func beginAlert() {
        stopGraceTimer() // its job is done; lockTimer owns the next deadline
        presence.breakChain() // the countdown is the identity gate
        escPressesThisAlert = 0
        escapeAuthAttempts = 0
        cancelEscapeAuth()
        monitor.analysisInterval = fastAnalysisInterval
        overlay.show(remaining: effectiveCountdownDuration)
        // Anchored AFTER the overlay is up, not before: show() builds a window
        // per screen and does an app-activation round trip, and charging that
        // setup to the user's warning time made the lock fire early on every
        // single countdown.
        let deadline = Uptime.now + effectiveCountdownDuration
        startTick(interval: 0.25) // overlay redraw only
        state = .alerting(deadline: deadline)
        scheduleLockTimer(at: deadline)
    }

    private func cancelAlert() {
        guard case .alerting = state else { return }
        stopLockTimer()
        overlay.dismiss()
        presence.touch()
        monitor.analysisInterval = idleAnalysisInterval
        startTick(interval: 1)
        state = .watching
        rescheduleGraceTimer()
    }

    /// One Esc press on the countdown overlay. Deliberately does **not** cancel:
    /// a single un-checked keypress that dismisses a countdown is exactly the
    /// bypass an intruder would use. Three presses ask the Mac who's pressing.
    /// Dismisses any in-flight verification prompt. Called whenever the alert it
    /// belongs to is abandoned, so a stale prompt can't answer into a new state.
    private func cancelEscapeAuth() {
        escapeAuthContext?.invalidate()
        escapeAuthContext = nil
        authenticatingEscape = false
    }

    private func handleEscPress() {
        guard case .alerting(let deadline) = state, !authenticatingEscape else { return }
        escPressesThisAlert += 1

        guard escapeAuthAttempts < escapeAuthAttemptLimit else {
            // Out of attempts: say so plainly and let the countdown finish.
            overlay.setHint("Verification failed — sign in again after it locks")
            return
        }
        let remaining = escPressLimit - escPressesThisAlert
        guard remaining <= 0 else {
            // Only now reveal the gesture — a passerby sees a blank screen.
            overlay.setHint("Press Esc \(remaining) more time\(remaining == 1 ? "" : "s") to verify it's you")
            return
        }
        confirmEscape(deadline: deadline)
    }

    /// Holds the lock, verifies with the Mac's own authentication, and only then
    /// stops fighting the user. Failing or dismissing the prompt restores the
    /// countdown exactly where it was, so an intruder gains nothing and the
    /// screen still locks; the owner passes it and monitoring pauses until they
    /// re-enroll, since recognition has demonstrably stopped matching them.
    private func confirmEscape(deadline: TimeInterval) {
        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            // Nothing to verify against — leave the countdown running rather
            // than granting an unverified escape.
            overlay.setHint("Can't verify on this Mac")
            return
        }

        authenticatingEscape = true
        escapeAuthContext = context
        stopTick()
        overlay.setHint("Verifying…")
        // Deferred, never cancelled. An unanswered prompt is not consent, so the
        // lock still fires once the grace runs out.
        scheduleLockTimer(at: max(deadline, Uptime.now + escapeAuthGrace))

        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "stop Lockscreen Dah? from locking your screen"
        ) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authenticatingEscape = false
                self.escapeAuthContext = nil
                guard success else {
                    // Put the countdown back exactly where it was, dropping the
                    // deferral. A deadline already past fires at once, which is
                    // the correct outcome. Presses reset so a further attempt
                    // costs three again rather than one.
                    guard case .alerting = self.state else { return }
                    self.escapeAuthAttempts += 1
                    self.escPressesThisAlert = 0
                    self.overlay.setHint(nil)
                    self.startTick(interval: 0.25)
                    self.scheduleLockTimer(at: deadline)
                    return
                }
                Settings.reenrollmentRequired = true
                self.pause()
                self.showAlert(
                    title: "Monitoring paused",
                    message: "Face recognition isn't matching you reliably, so monitoring is paused and your screen is NOT being protected. Start Monitoring will walk you through re-enrolling your face; your current profile keeps working until the new one is saved."
                )
            }
        }
    }

    private func lockNow() {
        // Counted before the lock, since the lock itself ends this session.
        Settings.consecutiveLocksWithoutMatch += 1
        enterLockedState()
        ScreenLocker.lock()
        // Both lock APIs are best-effort — confirm the session really locked,
        // otherwise the app would sit in .locked (camera off, no unlock
        // notification ever coming) while the desktop stays exposed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.state == .locked, !ScreenLocker.sessionIsLocked else { return }
            self.pause()
            self.showAlert(
                title: "Screen lock failed",
                message: "Lockscreen Dah? could not lock the screen: the countdown finished but macOS rejected the lock request. Monitoring is paused; your screen is NOT being protected until this is resolved."
            )
        }
    }

    private func enterLockedState() {
        overlay.dismiss()
        cancelEscapeAuth()
        stopTick()
        stopGraceTimer()
        stopLockTimer()
        monitor.stop()
        cameraResting = false
        state = .locked
    }

    // MARK: - Detection handling

    private func handleDetection(_ result: DetectionResult) {
        switch state {
        case .watching:
            // Cadence is owned by handleTick: fast sampling kicks in only when
            // absence is actually suspected, not merely because the current
            // frame didn't match (head turned to a second screen is the
            // steady state, and the chain keeps absence at ~0 there).
            // Stamped with the frame's own capture instant, not "now": the
            // analysis pipeline plus the hop onto this thread is 100-400 ms,
            // and charging that to absence made the countdown that much late.
            let matched = presence.observe(result, now: result.capturedAt)
            if matched { Settings.consecutiveLocksWithoutMatch = 0 }
            // Scheduled re-check satisfied: the owner is still there, so give the
            // camera straight back rather than burning the full awake minimum.
            if matched, peekDeadline != nil {
                enterCameraRest(now: Uptime.now)
                return
            }
            // Every observation can move lastOwnerSeen forward (or leave it
            // put) — reschedule unconditionally rather than trying to detect
            // which; rescheduling to an unchanged deadline is a no-op cost.
            rescheduleGraceTimer()
        case .alerting:
            // Only a positive owner match (or Esc) dismisses the countdown —
            // an unmatched face alone can't keep the screen open.
            if result.ownerMatched {
                Settings.consecutiveLocksWithoutMatch = 0
                presence.establish()
                cancelAlert()
            }
        case .enrolling:
            enrollment.handleDetection(result)
        case .paused, .locked:
            break
        }
    }

    /// 1 s granularity is plenty against a multi-second grace period; only the
    /// countdown redraw during .alerting needs the fast 0.25 s cadence.
    private func startTick(interval: TimeInterval) {
        stopTick()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.handleTick()
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// Schedules (or reschedules) the precise one-shot timer that fires the
    /// countdown exactly `gracePeriod` seconds after presence was last
    /// confirmed. Call this every time `presence`'s `lastOwnerSeen` might
    /// have moved forward (a fresh observation, Esc-cancel, camera-rest
    /// touch) — rescheduling to the same deadline when nothing changed is
    /// harmless. No tolerance is set: unlike `tickTimer`, this one exists
    /// specifically to be on time.
    /// The instant the grace clock counts from: the later of "presence was last
    /// confirmed" and "this capture session delivered its first frame". The
    /// second term matters because `presence.reset()` stamps `beginWatching`,
    /// an instant when the camera provably was not looking yet — session
    /// spin-up to first frame is ~1 s, which a short grace period expires
    /// entirely inside. Without it, every unlock at grace 1 s blacked out a
    /// seated user before the camera had produced a usable frame.
    private var graceAnchor: TimeInterval {
        guard let firstFrame = monitor.firstFrameAt else { return presence.lastOwnerSeen }
        return max(presence.lastOwnerSeen, firstFrame)
    }

    private func rescheduleGraceTimer() {
        scheduleGraceTimer(at: graceAnchor + Settings.gracePeriod)
    }

    /// `deadline` is a monotonic uptime instant, and the timer is scheduled as a
    /// *delay* off `DispatchTime` rather than an absolute wall-clock fire date:
    /// a `Timer(fire: Date)` stores CFAbsoluteTime, so a forward clock step
    /// fired it early. See Uptime.
    private func scheduleGraceTimer(at deadline: TimeInterval) {
        graceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0, deadline - Uptime.now))
        timer.setEventHandler { [weak self] in self?.handleGraceExpired() }
        timer.resume()
        graceTimer = timer
    }

    private func stopGraceTimer() {
        graceTimer?.cancel()
        graceTimer = nil
    }

    /// Fires at the scheduled deadline. Re-verifies absence has actually
    /// reached the grace period rather than trusting the timer blindly — a
    /// safety net in case some path ever refreshes presence without also
    /// rescheduling, which would otherwise risk a premature alert.
    private func handleGraceExpired() {
        guard state == .watching else { return }
        let now = Uptime.now
        // Camera rest deliberately stops the session, which is not a failure —
        // but a countdown started from it could never be cancelled by showing
        // your face, making the lock unavoidable. Wake the camera and let the
        // fresh grace period decide instead. Reachable when the deadline is
        // pulled in under the 1 Hz rest tick (e.g. Start Countdown After is
        // lowered while resting).
        if cameraResting {
            wakeCameraFromRest(now: now)
            return
        }
        guard now - graceAnchor >= Settings.gracePeriod else {
            rescheduleGraceTimer()
            return
        }
        // Absence only means something if the camera was actually looking. A
        // session that has never delivered a frame is evidence of nothing, so
        // neither black out nor lock on it. Checked before the Instant branch
        // below so a dead camera can never lock the screen.
        if !monitor.hasDeliveredFrame {
            // Still inside session spin-up (first frame lands ~1 s in, which a
            // short grace period expires inside): too early to call it either
            // way, so defer the decision to the end of the allowance rather
            // than alerting or locking on no evidence.
            let allowanceEnd = cameraStartedAt + cameraStartupAllowance
            if now < allowanceEnd {
                scheduleGraceTimer(at: allowanceEnd)
            } else {
                reportCameraFailure()
            }
            return
        }
        // "Never Countdown": nothing to show, so lock straight from here. Note
        // this reads the *effective* duration, so a detected lock loop restores a
        // minimum countdown and with it the Esc escape gesture.
        if effectiveCountdownDuration <= 0 {
            lockNow()
            return
        }
        beginAlert()
    }

    /// Schedules the precise one-shot lock at the countdown deadline. Monotonic
    /// for the same reason as the grace timer above.
    private func scheduleLockTimer(at deadline: TimeInterval) {
        lockTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0, deadline - Uptime.now))
        timer.setEventHandler { [weak self] in self?.handleCountdownExpired() }
        timer.resume()
        lockTimer = timer
    }

    private func stopLockTimer() {
        lockTimer?.cancel()
        lockTimer = nil
    }

    private func handleCountdownExpired() {
        guard case .alerting(let deadline) = state else { return }
        if authenticatingEscape {
            // The prompt outlived its grace without an answer. Tear it down and
            // lock: silence is not authorisation.
            cancelEscapeAuth()
            lockNow()
            return
        }
        // Same defensive re-check as handleGraceExpired: never lock early.
        guard Uptime.now >= deadline else {
            scheduleLockTimer(at: deadline)
            return
        }
        lockNow()
    }

    /// The grace-period setting changed live while already watching — the
    /// currently-scheduled deadline was computed from the old value, so
    /// recompute it against the new one immediately rather than waiting for
    /// the next real presence observation to happen to trigger a reschedule.
    func gracePeriodSettingChanged() {
        guard state == .watching else { return }
        rescheduleGraceTimer()
    }

    /// Ends camera rest and restarts the capture session. Waking is an identity
    /// gate — the camera was blind, so the seat may have changed hands. Break
    /// the chain: face/body may not maintain presence again until one fresh
    /// positive match lands. The grace clock restarts from the wake (spin-up
    /// never eats into it) and sampling runs fast, so a facing owner re-matches
    /// in ~1 s; no match within the grace period means a countdown.
    private func wakeCameraFromRest(now: TimeInterval, peeking: Bool = false) {
        cameraResting = false
        restStartedAt = nil
        inputActiveSince = nil
        lastCameraWake = now
        peekDeadline = peeking ? now + cameraPeekWindow : nil
        presence.breakChain()
        presence.touch(now: now)
        monitor.analysisInterval = fastAnalysisInterval
        cameraStartedAt = now // start() resets frame-delivery liveness
        monitor.start()
        rescheduleGraceTimer()
        verifyCameraStarted() // the restart can fail like any other
    }

    /// Stops the capture session and hands presence over to input. Called both
    /// from the sustained-input path and straight from a successful peek, which
    /// deliberately bypasses `cameraMinAwake` — that guard exists to stop bursty
    /// typing thrashing the session, and a peek that already found the owner
    /// isn't thrash.
    private func enterCameraRest(now: TimeInterval) {
        cameraResting = true
        restStartedAt = now
        peekDeadline = nil
        presence.touch(now: now)
        rescheduleGraceTimer()
        monitor.stop()
    }

    private func handleTick() {
        switch state {
        case .watching:
            let now = Uptime.now
            let sinceInput = Self.secondsSinceLastInput()

            if cameraResting {
                // Keep resting only while all the conditions that permitted it
                // still hold — a live grace change to below the minimum (or
                // "Never Idle") must end the rest now, not just block the next.
                let restedFor = now - (restStartedAt ?? now)
                let hitRestCeiling = cameraRestMaxDuration > 0 && restedFor >= cameraRestMaxDuration
                let stillIdling = sinceInput < cameraWakeQuiet
                    && cameraRestAfter > 0
                    && Settings.cameraRestAvailable
                    && !hitRestCeiling
                if stillIdling {
                    // Still typing — input is the presence signal.
                    presence.touch(now: now)
                    rescheduleGraceTimer()
                    return
                }
                // Keyboard went quiet, idling was switched off, grace dropped
                // below the rest minimum, or the rest hit its ceiling. Let the
                // restarted camera deliver a frame at the fast cadence before
                // this tick's absence check could second-guess it.
                //
                // A ceiling-triggered wake is a *peek*: input is still flowing,
                // so this is a scheduled identity re-check rather than the user
                // stopping. If the owner is seen it drops straight back to rest.
                wakeCameraFromRest(now: now, peeking: hitRestCeiling)
                return
            }

            // A peek that found nobody becomes an ordinary wake — the grace
            // clock has been running since it started, so absence resolves
            // itself from here.
            if let deadline = peekDeadline, now >= deadline {
                peekDeadline = nil
            }

            // Track sustained input; rest the camera once it has proven
            // presence for a while (chain must already be established —
            // input can maintain identity, never create it).
            inputActiveSince = sinceInput < cameraWakeQuiet ? (inputActiveSince ?? now) : nil
            if let activeSince = inputActiveSince,
               presence.chainActive,
               cameraRestAfter > 0, // "Never Idle"
               Settings.cameraRestAvailable,
               now - activeSince >= cameraRestAfter,
               now - lastCameraWake >= cameraMinAwake {
                enterCameraRest(now: now)
                return
            }

            // The alert itself fires off graceTimer, not this poll — this
            // just picks the sampling rate: faster once absence is actually
            // suspected, so a real absence is confirmed (or refuted) well
            // before the grace deadline, cheaper once the chain is healthy.
            // Same anchor the deadline uses, so cadence and deadline can't disagree.
            if now - graceAnchor > Settings.gracePeriod / 2 {
                monitor.analysisInterval = fastAnalysisInterval
            } else {
                monitor.analysisInterval = idleAnalysisInterval
            }
        case .alerting(let deadline):
            // Redraw only — lockTimer owns the deadline, so this poll's
            // ~0.13 s average lag no longer delays the lock itself.
            overlay.update(remaining: max(0, deadline - Uptime.now))
        case .paused, .locked, .enrolling:
            break
        }
    }

    // MARK: - Enrollment

    func enrollFace(completion: ((Bool) -> Void)? = nil) {
        guard recognizer.hasModel else {
            showAlert(
                title: "Face model missing",
                message: "FaceEmbedding.mlmodelc was not bundled. Run scripts/fetch-model.sh and rebuild."
            )
            completion?(false)
            return
        }

        // Re-enrolling changes whose face keeps the screen unlocked — require
        // the Mac's own authentication (Touch ID / password) first.
        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            showAlert(
                title: "Authentication unavailable",
                message: authError?.localizedDescription ?? "Cannot verify your identity on this Mac."
            )
            completion?(false)
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "enroll the face that keeps your screen unlocked"
        ) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard success else {
                    completion?(false)
                    return
                }
                self?.beginEnrollment()
                completion?(true)
            }
        }
    }

    private func beginEnrollment() {
        resumeAfterEnrollment = state != .paused
        overlay.dismiss()
        stopTick()
        stopGraceTimer()
        stopLockTimer()
        state = .enrolling
        withCameraPermission { [weak self] in self?.enrollment.begin() }
    }

    /// The controller finished (saved, cancelled, or window closed) — restore
    /// whatever monitoring state enrollment interrupted.
    private func enrollmentFinished() {
        guard state == .enrolling else { return }
        if resumeAfterEnrollment {
            beginWatching()
        } else {
            monitor.stop()
            state = .paused
        }
    }

    // MARK: - Monitoring hours

    private func startScheduleTimer() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.resolveSchedule()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    /// Runs on the periodic schedule timer. Only acts once a schedule
    /// boundary has been crossed since the last real watch/pause decision
    /// (see lastDecisionAt) — between boundaries the user's manual
    /// Start/Pause always wins.
    private func resolveSchedule(now: Date = Date()) {
        guard Settings.scheduleEnabled, state != .enrolling else { return }
        guard let at = lastDecisionAt, at < Settings.mostRecentBoundary(before: now) else { return }
        applySchedule(within: Settings.withinMonitoringHours(now: now))
    }

    /// Makes the one paused/watching transition the schedule calls for,
    /// given a fresh "should we be watching right now" answer. A session
    /// that's actually locked when the schedule wants to start is parked in
    /// .locked (harmless, idempotent from .paused) rather than starting the
    /// camera behind a locked screen; resumeFromLocked resolves it at the
    /// next unlock.
    private func applySchedule(within: Bool) {
        switch state {
        case .paused where within:
            // Stamp before attempting, even though the attempt below may not
            // land (camera permission denied reverts to .paused) — otherwise
            // the timer retries (and re-alerts) every 30s indefinitely.
            // Scoped to only this branch: stamping in `default` would
            // corrupt resumeFromLocked's staleness check for an unrelated
            // .locked session sitting through an unconnected boundary.
            lastDecisionAt = Date()
            ScreenLocker.sessionIsLocked ? enterLockedState() : startMonitoring()
        case .watching where !within, .alerting where !within:
            pause() // stamps lastDecisionAt itself
        default:
            break
        }
    }

    /// Session unlocked, or the display woke from a locked state. The
    /// `screenIsUnlocked` notification is forgeable by any local process, so
    /// confirm the session is genuinely unlocked before starting the camera —
    /// and go through startMonitoring() (not beginWatching() directly) so a
    /// permission revoked while locked is caught here too, instead of
    /// silently starting a capture session that can't actually see anything.
    ///
    /// Uses the same staleness rule as resolveSchedule: if no schedule
    /// boundary has passed since our last real decision, resume whatever
    /// regime we locked from — always watching, since .locked is only ever
    /// entered from .watching/.alerting. This is what keeps a manual start
    /// outside active hours (or an entire Always On session, where
    /// mostRecentBoundary is always .distantPast) alive across lock/unlock.
    /// If a boundary DID pass — possibly several, across a multi-day gap —
    /// re-decide fresh from the live schedule.
    private func resumeFromLocked() {
        guard state == .locked, !ScreenLocker.sessionIsLocked else { return }
        guard let at = lastDecisionAt, at < Settings.mostRecentBoundary(before: Date()) else {
            startMonitoring()
            return
        }
        Settings.withinMonitoringHours() ? startMonitoring() : pause()
    }

    // MARK: - Lock / sleep observation

    private func observeLockAndSleepEvents() {
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.state != .paused, self.state != .enrolling else { return }
            self.enterLockedState()
        }
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.resumeFromLocked()
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.state != .paused, self.state != .enrolling else { return }
            self.enterLockedState()
        }
        workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Display woke without a password unlock (e.g. lock screen disabled).
            self?.resumeFromLocked()
        }
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Normally the sleep notification already moved us to .locked, so
            // this is a no-op. If it was missed we're still nominally .watching
            // over a capture session the OS may have torn down — restart from a
            // clean slate rather than measuring absence across time the camera
            // could not possibly have seen.
            guard let self, self.state == .watching else { return }
            self.beginWatching()
        }
    }

    /// Seconds since the user last touched keyboard, mouse, or trackpad.
    /// No Accessibility permission needed — this reads event *timing* only.
    /// Uses `.hidSystemState` (physical HID input) rather than
    /// `.combinedSessionState`, so synthetic events posted by other processes
    /// via CGEventPost can't fake presence and hold the screen open.
    private static func secondsSinceLastInput() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged, .mouseMoved,
            .leftMouseDown, .rightMouseDown, .scrollWheel,
        ]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? .infinity
    }

    // MARK: - Camera permission

    private func withCameraPermission(_ proceed: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            proceed()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        proceed()
                    } else {
                        self.showCameraDeniedAlert()
                    }
                }
            }
        default:
            showCameraDeniedAlert()
        }
    }

    private func showCameraDeniedAlert() {
        // Full teardown, not a bare `state = .paused`: reached from
        // beginEnrollment(), which deliberately leaves the capture session
        // running for the enrollment preview, so assigning the state directly
        // left the camera live behind a menu reading "Paused" with no path
        // back (enrollmentFinished() only fires from .enrolling).
        pause()
        let alert = NSAlert()
        alert.messageText = "Camera access needed"
        alert.informativeText = "Lockscreen Dah? needs the camera to see whether you're at your screen. Enable it in System Settings → Privacy & Security → Camera."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

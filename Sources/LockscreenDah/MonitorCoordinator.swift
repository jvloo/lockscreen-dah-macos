import AppKit
import AVFoundation
import CoreGraphics
import LocalAuthentication

/// Owns the presence state machine. All state transitions happen on the main thread.
final class MonitorCoordinator {
    enum State: Equatable {
        case paused
        case watching
        case alerting(deadline: Date)
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
        return controller
    }()

    private var tickTimer: Timer?
    /// Precise one-shot timer for firing the countdown exactly at the grace
    /// deadline — see `rescheduleGraceTimer()`. The 1 Hz `tickTimer` above
    /// only adjusts sampling rate and camera-rest bookkeeping now; it no
    /// longer decides when to alert, since polling once a second can report
    /// an expired grace period up to ~1 s late.
    private var graceTimer: Timer?
    /// Precise one-shot timer that fires the lock at the countdown deadline.
    /// Same reasoning as `graceTimer`: the 0.25 s `tickTimer` is for redrawing
    /// the overlay, and polling for the deadline on it landed the lock a
    /// measured ~0.13 s late on average (0.27 s worst case).
    private var lockTimer: Timer?
    /// The seat-continuity chain — see PresenceTracker for the model.
    private var presence = PresenceTracker()
    /// When the capture session was last asked to start. A countdown deadline
    /// can fall inside session spin-up on a short grace period, and "no frames
    /// yet" then means "too early to tell", not "camera broken" — see
    /// `handleGraceExpired`.
    private var cameraStartedAt = Date.distantPast
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
    private var inputActiveSince: Date?
    private var lastCameraWake = Date.distantPast
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

    // Failsafe: repeated Esc-cancels mean recognition is misbehaving (e.g. a
    // bad enrollment) — stop fighting the user and pause monitoring.
    private var escCancelTimes: [Date] = []
    private let escCancelLimit = 3
    private let escCancelWindow: TimeInterval = 600

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
        overlay.onCancel = { [weak self] in self?.handleEscCancel() }
        observeLockAndSleepEvents()
        startScheduleTimer()
    }

    // MARK: - Public controls

    func startMonitoring() {
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
        guard state != .enrolling, Settings.scheduleEnabled else { return }
        applySchedule(within: Settings.withinMonitoringHours())
    }

    func pause() {
        guard state != .paused else { return }
        overlay.dismiss()
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
            if Settings.scheduleEnabled, !Settings.withinMonitoringHours() {
                return "Paused (off hours)"
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
        lastCameraWake = Date()
        monitor.analysisInterval = idleAnalysisInterval
        cameraStartedAt = Date()
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
        monitor.analysisInterval = fastAnalysisInterval
        overlay.show(remaining: Settings.countdownDuration)
        // Anchored AFTER the overlay is up, not before: show() builds a window
        // per screen and does an app-activation round trip, and charging that
        // setup to the user's warning time made the lock fire early on every
        // single countdown.
        let deadline = Date().addingTimeInterval(Settings.countdownDuration)
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

    /// Esc pressed on the countdown overlay. Cancels the countdown, but three
    /// Esc-rescues inside ten minutes means recognition keeps getting you
    /// wrong — pause monitoring instead of locking you out repeatedly.
    private func handleEscCancel() {
        // Only count a strike that actually rescued a countdown, so an Esc that
        // cancelled nothing can't push the user toward the failsafe.
        guard case .alerting = state else { return }
        let now = Date()
        escCancelTimes.append(now)
        escCancelTimes.removeAll { now.timeIntervalSince($0) > escCancelWindow }
        cancelAlert()
        if escCancelTimes.count >= escCancelLimit {
            escCancelTimes.removeAll()
            pause()
            showAlert(
                title: "Monitoring paused",
                message: "You've had to Esc-cancel \(escCancelLimit) countdowns in 10 minutes, so recognition may not be matching you reliably. Re-enroll your face (menu bar → Re-enroll My Face…), then start monitoring again."
            )
        }
    }

    private func lockNow() {
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
            presence.observe(result, now: result.capturedAt)
            // Every observation can move lastOwnerSeen forward (or leave it
            // put) — reschedule unconditionally rather than trying to detect
            // which; rescheduling to an unchanged deadline is a no-op cost.
            rescheduleGraceTimer()
        case .alerting:
            // Only a positive owner match (or Esc) dismisses the countdown —
            // an unmatched face alone can't keep the screen open.
            if result.ownerMatched {
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
    private var graceAnchor: Date {
        guard let firstFrame = monitor.firstFrameAt else { return presence.lastOwnerSeen }
        return max(presence.lastOwnerSeen, firstFrame)
    }

    private func rescheduleGraceTimer() {
        scheduleGraceTimer(at: graceAnchor.addingTimeInterval(Settings.gracePeriod))
    }

    private func scheduleGraceTimer(at deadline: Date) {
        graceTimer?.invalidate()
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            self?.handleGraceExpired()
        }
        RunLoop.main.add(timer, forMode: .common)
        graceTimer = timer
    }

    private func stopGraceTimer() {
        graceTimer?.invalidate()
        graceTimer = nil
    }

    /// Fires at the scheduled deadline. Re-verifies absence has actually
    /// reached the grace period rather than trusting the timer blindly — a
    /// safety net in case some path ever refreshes presence without also
    /// rescheduling, which would otherwise risk a premature alert.
    private func handleGraceExpired() {
        guard state == .watching else { return }
        let now = Date()
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
        guard now.timeIntervalSince(graceAnchor) >= Settings.gracePeriod else {
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
            let allowanceEnd = cameraStartedAt.addingTimeInterval(cameraStartupAllowance)
            if now < allowanceEnd {
                scheduleGraceTimer(at: allowanceEnd)
            } else {
                reportCameraFailure()
            }
            return
        }
        // "Instant": no countdown to run, so lock straight from here. This also
        // takes the Esc failsafe out of play — there's no overlay to press Esc
        // on — which is the explicit trade the setting makes.
        if Settings.locksInstantly {
            lockNow()
            return
        }
        beginAlert()
    }

    /// Schedules the precise one-shot lock at the countdown deadline.
    private func scheduleLockTimer(at deadline: Date) {
        lockTimer?.invalidate()
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            self?.handleCountdownExpired()
        }
        RunLoop.main.add(timer, forMode: .common)
        lockTimer = timer
    }

    private func stopLockTimer() {
        lockTimer?.invalidate()
        lockTimer = nil
    }

    private func handleCountdownExpired() {
        guard case .alerting(let deadline) = state else { return }
        // Same defensive re-check as handleGraceExpired: never lock early.
        guard Date() >= deadline else {
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
    private func wakeCameraFromRest(now: Date) {
        cameraResting = false
        inputActiveSince = nil
        lastCameraWake = now
        presence.breakChain()
        presence.touch(now: now)
        monitor.analysisInterval = fastAnalysisInterval
        cameraStartedAt = now // start() resets frame-delivery liveness
        monitor.start()
        rescheduleGraceTimer()
        verifyCameraStarted() // the restart can fail like any other
    }

    private func handleTick() {
        switch state {
        case .watching:
            let now = Date()
            let sinceInput = Self.secondsSinceLastInput()

            if cameraResting {
                // Keep resting only while all the conditions that permitted it
                // still hold — a live grace change to below the minimum (or
                // "Never Idle") must end the rest now, not just block the next.
                let stillIdling = sinceInput < cameraWakeQuiet
                    && cameraRestAfter > 0
                    && Settings.cameraRestAvailable
                if stillIdling {
                    // Still typing — input is the presence signal.
                    presence.touch(now: now)
                    rescheduleGraceTimer()
                    return
                }
                // Keyboard went quiet, idling was switched off, or grace dropped
                // below the rest minimum. Let the restarted camera deliver a
                // frame at the fast cadence before this tick's absence check
                // could second-guess it.
                wakeCameraFromRest(now: now)
                return
            }

            // Track sustained input; rest the camera once it has proven
            // presence for a while (chain must already be established —
            // input can maintain identity, never create it).
            inputActiveSince = sinceInput < cameraWakeQuiet ? (inputActiveSince ?? now) : nil
            if let activeSince = inputActiveSince,
               presence.chainActive,
               cameraRestAfter > 0, // "Never Idle"
               Settings.cameraRestAvailable,
               now.timeIntervalSince(activeSince) >= cameraRestAfter,
               now.timeIntervalSince(lastCameraWake) >= cameraMinAwake {
                cameraResting = true
                presence.touch(now: now)
                rescheduleGraceTimer()
                monitor.stop()
                return
            }

            // The alert itself fires off graceTimer, not this poll — this
            // just picks the sampling rate: faster once absence is actually
            // suspected, so a real absence is confirmed (or refuted) well
            // before the grace deadline, cheaper once the chain is healthy.
            // Same anchor the deadline uses, so cadence and deadline can't disagree.
            if now.timeIntervalSince(graceAnchor) > Settings.gracePeriod / 2 {
                monitor.analysisInterval = fastAnalysisInterval
            } else {
                monitor.analysisInterval = idleAnalysisInterval
            }
        case .alerting(let deadline):
            // Redraw only — lockTimer owns the deadline, so this poll's
            // ~0.13 s average lag no longer delays the lock itself.
            overlay.update(remaining: max(0, deadline.timeIntervalSinceNow))
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
        // The Esc failsafe's advice was "re-enroll your face" — clear the
        // strikes now that they have, so leftover pre-enrollment strikes can't
        // trip it again and repeat advice they just followed.
        escCancelTimes.removeAll()
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

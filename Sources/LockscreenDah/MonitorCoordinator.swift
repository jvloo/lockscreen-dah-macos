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
    /// The seat-continuity chain — see PresenceTracker for the model.
    private var presence = PresenceTracker()

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
    /// Below this grace period the camera never rests: wake + session spin-up
    /// + first match takes ~1.5 s, which a 1 s grace can't absorb — the
    /// overlay would flash at the seated user after every typing pause.
    private let cameraRestMinimumGrace: TimeInterval = 3

    /// Cadence while absence is suspected / countdown running — fast return detection.
    private let fastAnalysisInterval: TimeInterval = 0.4
    /// Steady-state cadence while the presence chain is healthy. Scales with
    /// the grace period — a long grace doesn't need frequent sampling — and is
    /// capped at 2.5 s so the 3-frame stranger challenge always resolves
    /// within ~7.5 s of a stranger facing the screen.
    private var idleAnalysisInterval: TimeInterval {
        min(max(Settings.gracePeriod / 3, fastAnalysisInterval), 2.5)
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
        monitor.start()
        startTick(interval: 1)
        state = .watching
    }

    private func beginAlert() {
        presence.breakChain() // the countdown is the identity gate
        let deadline = Date().addingTimeInterval(Settings.countdownDuration)
        monitor.analysisInterval = fastAnalysisInterval
        overlay.show(remaining: Settings.countdownDuration)
        startTick(interval: 0.25)
        state = .alerting(deadline: deadline)
    }

    private func cancelAlert() {
        guard case .alerting = state else { return }
        overlay.dismiss()
        presence.touch()
        monitor.analysisInterval = idleAnalysisInterval
        startTick(interval: 1)
        state = .watching
    }

    /// Esc pressed on the countdown overlay. Cancels the countdown, but three
    /// Esc-rescues inside ten minutes means recognition keeps getting you
    /// wrong — pause monitoring instead of locking you out repeatedly.
    private func handleEscCancel() {
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
                message: "Lockscreen Dah? could not lock the screen — the countdown finished but macOS rejected the lock request. Monitoring is paused; your screen is NOT being protected until this is resolved."
            )
        }
    }

    private func enterLockedState() {
        overlay.dismiss()
        stopTick()
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
            presence.observe(
                result,
                secondsSinceInput: Self.secondsSinceLastInput()
            )
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
                    && Settings.gracePeriod >= cameraRestMinimumGrace
                if stillIdling {
                    // Still typing — input is the presence signal.
                    presence.touch(now: now)
                    return
                }
                // Wake: keyboard went quiet, idling was switched off, or grace
                // dropped below the rest minimum. Waking is an identity gate —
                // the camera was blind, so the seat may have changed hands.
                // Break the chain: face/body/input may not maintain presence
                // again until one fresh positive match lands. The grace clock
                // restarts from the wake (spin-up never eats into it) and
                // sampling runs fast, so a facing owner re-matches in ~1 s;
                // no match within the grace → countdown.
                cameraResting = false
                lastCameraWake = now
                presence.breakChain()
                presence.touch(now: now)
                monitor.analysisInterval = fastAnalysisInterval
                monitor.start()
                // Let the restarted camera deliver a frame at the fast cadence
                // before this tick's absence check could second-guess it.
                return
            }

            // Track sustained input; rest the camera once it has proven
            // presence for a while (chain must already be established —
            // input can maintain identity, never create it).
            inputActiveSince = sinceInput < cameraWakeQuiet ? (inputActiveSince ?? now) : nil
            if let activeSince = inputActiveSince,
               presence.chainActive,
               cameraRestAfter > 0, // "Never Idle"
               Settings.gracePeriod >= cameraRestMinimumGrace,
               now.timeIntervalSince(activeSince) >= cameraRestAfter,
               now.timeIntervalSince(lastCameraWake) >= cameraMinAwake {
                cameraResting = true
                presence.touch(now: now)
                monitor.stop()
                return
            }

            let absence = presence.absence(now: now)
            if absence > Settings.gracePeriod {
                beginAlert()
            } else if absence > Settings.gracePeriod / 2 {
                // Absence suspected — sample faster so a real absence is
                // confirmed (or refuted) quickly, well before grace runs out.
                monitor.analysisInterval = fastAnalysisInterval
            } else {
                // Chain healthy — ride the cheap cadence (also restores idle
                // after a fast episode without needing a positive match).
                monitor.analysisInterval = idleAnalysisInterval
            }
        case .alerting(let deadline):
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                lockNow()
            } else {
                overlay.update(remaining: remaining)
            }
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
    /// confirm the session is genuinely unlocked before starting the camera.
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
            beginWatching()
            return
        }
        Settings.withinMonitoringHours() ? beginWatching() : pause()
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
        state = .paused
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

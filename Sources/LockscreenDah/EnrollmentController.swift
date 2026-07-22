import Foundation

/// Owns the KYC-style enrollment flow: staged capture with settle countdowns,
/// candidate-profile build, automatic live verification, and the user-paced
/// button phases. Shares the coordinator's FaceMonitor/FaceRecognizer; the
/// coordinator gates entry (auth + camera permission + state) and gets
/// `onFinished` when the flow ends, whatever the outcome.
final class EnrollmentController {
    /// Enrollment is over (saved, failed-and-cancelled, or window closed).
    var onFinished: (() -> Void)?

    private let recognizer: FaceRecognizer
    private let monitor: FaceMonitor
    private let panel = EnrollmentPanel()

    // Staged capture — each stage shows an instruction, gives the user a
    // moment to settle into the pose, then collects samples.
    private struct Stage {
        let instruction: String
        let target: Int
    }
    private let stages = [
        Stage(instruction: "Look straight ahead", target: 4),
        Stage(instruction: "Turn slightly left", target: 4),
        Stage(instruction: "Turn slightly right", target: 4),
    ]
    private var totalSamples: Int { stages.reduce(0) { $0 + $1.target } }
    /// 3… 2… 1… countdown before each stage starts capturing.
    private let stageSettleTime: TimeInterval = 3

    /// User-paced KYC flow: Start begins capture, Continue advances stages,
    /// Verify runs the live post-save test, Save/Re-Enroll close it out.
    private enum Phase {
        case ready      // waiting for Start
        case capturing  // collecting samples for the current stage — no buttons
        case stageDone  // stage finished: Recapture / Continue
        case verifying  // automatic live test against the candidate — no buttons
        case succeeded  // verified: Verify (again) / Save
        case failed     // capture/verify failure: Cancel / Re-Enroll
    }
    private var phase: Phase = .ready
    private var samples: [EnrollmentSample] = []
    private var stageIndex = 0
    private var stageCollected = 0
    private var stageSettleUntil = Date.distantPast
    private var timeout: Timer?
    /// Built after the last stage, verified live, persisted only on Save.
    private var candidateProfile: FaceProfile?
    private var verifyStreak = 0
    private let verifyStreakTarget = 3

    init(recognizer: FaceRecognizer, monitor: FaceMonitor) {
        self.recognizer = recognizer
        self.monitor = monitor
        panel.onCancel = { [weak self] in self?.finish() }
        panel.onPrimary = { [weak self] in self?.handlePrimary() }
        panel.onSecondary = { [weak self] in self?.handleSecondary() }
    }

    /// Starts (or restarts, on Re-Enroll) the flow. The caller must already
    /// hold camera permission and have put the coordinator in .enrolling.
    func begin() {
        samples = []
        stageIndex = 0
        stageCollected = 0
        phase = .ready
        candidateProfile = nil
        verifyStreak = 0
        timeout?.invalidate()
        timeout = nil

        monitor.collectEnrollmentSamples = true
        monitor.analysisInterval = 0.25
        monitor.start()
        panel.show(session: monitor.session, totalSamples: totalSamples)
        panel.setInstruction(stages[0].instruction)
        panel.setStatus("Position your face in the oval.")
        panel.setPrimary(title: "Start")
        panel.setSecondary(title: nil)
        panel.setCancelVisible(true)
    }

    /// Tears the flow down without firing `onFinished` — for when the
    /// coordinator itself is pausing and will set its own state.
    func abort() {
        timeout?.invalidate()
        timeout = nil
        panel.dismiss()
        monitor.collectEnrollmentSamples = false
        samples = []
        phase = .ready
        candidateProfile = nil
    }

    private func finish() {
        abort()
        onFinished?()
    }

    // MARK: - Buttons

    /// Primary button: Start / Continue / Save / Re-Enroll depending on phase.
    private func handlePrimary() {
        switch phase {
        case .ready, .stageDone:
            startCapturingStage()
        case .succeeded:
            guard let candidateProfile else { return }
            do {
                try recognizer.commit(candidateProfile)
                finish()
            } catch {
                showFailure("Could not save the profile: \(error.localizedDescription)")
            }
        case .failed:
            begin() // Re-Enroll — already authenticated this session
        case .capturing, .verifying:
            break
        }
    }

    /// Secondary button: Recapture (stage done) / Verify again (succeeded).
    private func handleSecondary() {
        switch phase {
        case .stageDone:
            guard stageIndex > 0 else { return }
            let previousStage = stages[stageIndex - 1]
            samples.removeLast(min(previousStage.target, samples.count))
            stageIndex -= 1
            stageCollected = 0
            panel.setProgress(samples.count)
            startCapturingStage()
        case .succeeded:
            beginVerification()
        case .ready, .capturing, .verifying, .failed:
            break
        }
    }

    // MARK: - Capture

    private func startCapturingStage() {
        phase = .capturing
        stageSettleUntil = Date().addingTimeInterval(stageSettleTime)
        panel.setInstruction(stages[stageIndex].instruction)
        panel.setStatus("Get ready…")
        panel.setCountdown(Int(stageSettleTime))
        panel.setStageProgress(nil)
        panel.setPrimary(title: nil)
        panel.setSecondary(title: nil)
        panel.setCancelVisible(false)
        startStageTimeout()
    }

    /// A capture stage that can't finish within a minute is stuck (bad
    /// lighting, no face) — fail rather than sit forever. The button-gated
    /// phases deliberately never time out.
    private func startStageTimeout() {
        timeout?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
            self?.showFailure("Timed out: not enough captures. Try again with better lighting.")
        }
        RunLoop.main.add(timer, forMode: .common)
        timeout = timer
    }

    /// Any capture/build/verify failure lands here: Cancel / Re-Enroll.
    private func showFailure(_ message: String) {
        timeout?.invalidate()
        timeout = nil
        phase = .failed
        panel.setCountdown(nil)
        panel.setStageProgress(nil)
        panel.showVerifyFailure(message)
        panel.setPrimary(title: "Re-Enroll")
        panel.setSecondary(title: nil)
        panel.setCancelVisible(true)
    }

    // MARK: - Detection

    /// Fed by the coordinator with every analyzed frame while enrolling.
    func handleDetection(_ result: DetectionResult) {
        switch phase {
        case .capturing:
            handleCaptureDetection(result)
        case .verifying:
            handleVerificationDetection(result)
        case .ready, .stageDone, .succeeded, .failed:
            break // waiting for a button — nothing to capture
        }
    }

    private func handleCaptureDetection(_ result: DetectionResult) {
        guard stageIndex < stages.count else { return }
        let stage = stages[stageIndex]
        panel.setInstruction(stage.instruction)

        guard result.enrollmentSample != nil || result.faceCount > 0 else {
            panel.setStatus("Move into the oval", isProblem: true)
            return
        }

        let now = Date()
        if now < stageSettleUntil {
            let secondsLeft = Int(stageSettleUntil.timeIntervalSince(now).rounded(.up))
            panel.setCountdown(secondsLeft)
            return
        }
        panel.setCountdown(nil)

        guard let sample = result.enrollmentSample else {
            panel.setStatus("Hold still…", isProblem: true)
            return
        }

        samples.append(sample)
        stageCollected += 1
        panel.setProgress(samples.count)
        panel.setStageProgress(stageCollected * 100 / stage.target)
        panel.setStatus("Hold still…")

        if stageCollected >= stage.target {
            timeout?.invalidate()
            timeout = nil
            stageIndex += 1
            stageCollected = 0
            if stageIndex >= stages.count {
                // All poses captured — build the candidate and verify
                // automatically; nothing is saved until the user hits Save.
                do {
                    candidateProfile = try recognizer.makeCandidateProfile(samples: samples)
                    beginVerification()
                } catch {
                    showFailure(error.localizedDescription)
                }
            } else {
                phase = .stageDone
                panel.setStageProgress(nil)
                panel.setInstruction(stages[stageIndex].instruction)
                panel.setStatus("Ready for the next pose?")
                panel.setPrimary(title: "Continue")
                panel.setSecondary(title: "Recapture")
                panel.setCancelVisible(false)
            }
        }
    }

    // MARK: - Verification

    /// Live end-to-end test against the candidate profile: the user must be
    /// recognized `verifyStreakTarget` times in a row to succeed.
    private func beginVerification() {
        guard candidateProfile != nil else { return }
        phase = .verifying
        verifyStreak = 0
        panel.setCountdown(nil)
        panel.setStageProgress(nil)
        panel.setInstruction("Look at the camera")
        panel.setStatus("Verifying…")
        panel.setPrimary(title: nil)
        panel.setSecondary(title: nil)
        panel.setCancelVisible(false)

        timeout?.invalidate()
        let timer = Timer(timeInterval: 20, repeats: false) { [weak self] _ in
            guard let self, self.phase == .verifying else { return }
            self.showFailure(
                "Couldn't recognize you with the new profile. Re-enroll with better lighting; this profile was not saved."
            )
        }
        RunLoop.main.add(timer, forMode: .common)
        timeout = timer
    }

    private func handleVerificationDetection(_ result: DetectionResult) {
        guard phase == .verifying, let candidateProfile else { return }
        guard let sample = result.enrollmentSample else {
            panel.setStatus(
                result.faceCount > 0 ? "Hold still…" : "Move into the oval",
                isProblem: true
            )
            return
        }
        let similarity = recognizer.similarity(of: sample.embedding, to: candidateProfile)
        if similarity >= Settings.matchThreshold {
            verifyStreak += 1
            panel.setStatus(
                String(format: "Match %.2f ✓  (%d / %d)", similarity, verifyStreak, verifyStreakTarget)
            )
            if verifyStreak >= verifyStreakTarget {
                phase = .succeeded
                timeout?.invalidate()
                timeout = nil
                panel.showVerified(score: similarity)
                panel.setPrimary(title: "Save")
                panel.setSecondary(title: "Verify")
                panel.setCancelVisible(false)
            }
        } else {
            verifyStreak = 0
            panel.setStatus(
                String(format: "Match %.2f, below the %.2f threshold", similarity, Settings.matchThreshold),
                isProblem: true
            )
        }
    }
}

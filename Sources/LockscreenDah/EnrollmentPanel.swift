import AppKit
import AVFoundation

/// KYC-style enrollment window: live mirrored camera preview with an oval
/// face guide, stage instructions ("look straight / turn left / turn right"),
/// a get-ready countdown, capture progress, and live no-face feedback.
final class EnrollmentPanel: NSObject {
    var onCancel: (() -> Void)?
    /// Start / Continue / Save / Re-Enroll — the phase's main action.
    var onPrimary: (() -> Void)?
    /// Recapture / Verify — the phase's alternative action.
    var onSecondary: (() -> Void)?

    private var panel: NSPanel?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var instructionLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var stageBadge: CATextLayer?
    private var stageOverlayLayer: CALayer?
    private var countdownBadge: CATextLayer?
    private var countdownOverlayLayer: CALayer?
    private var primaryButton: NSButton?
    private var secondaryButton: NSButton?
    private var cancelButton: NSButton?
    private var controlsRow: NSStackView?
    // Desired visibility — the controls row is rebuilt from these on every
    // change, which (unlike isHidden + detachesHiddenViews) can never leave a
    // ghost slot that pushes visible buttons off-center.
    private var cancelShown = true
    private var secondaryShown = false
    private var primaryShown = true

    func show(session: AVCaptureSession, totalSamples: Int) {
        dismiss()
        let panel = NSPanel.floating(
            title: "Enroll Face",
            contentSize: NSSize(width: 480, height: 470)
        )
        panel.delegate = self // title-bar close = cancel everything
        panel.center()

        // Mirrored live preview, like looking into a mirror.
        let preview = NSView()
        preview.wantsLayer = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.cornerRadius = 10
        layer.masksToBounds = true
        // Mirror like a real mirror. Transform-based flip: the connection
        // doesn't exist until the session finishes configuring on its
        // background queue, so connection.isVideoMirrored set here would
        // silently no-op. Overlays (oval, countdown, %) are siblings on the
        // container layer, so they stay unflipped.
        layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        preview.layer = CALayer()
        preview.layer?.addSublayer(layer)
        previewLayer = layer

        // Oval face guide over the preview.
        let guide = CAShapeLayer()
        let ovalRect = CGRect(x: 130, y: 20, width: 180, height: 240)
        guide.path = CGPath(ellipseIn: ovalRect, transform: nil)
        guide.fillColor = NSColor.clear.cgColor
        guide.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        guide.lineWidth = 2
        guide.lineDashPattern = [8, 6]
        preview.layer?.addSublayer(guide)

        let scale = NSScreen.main?.backingScaleFactor ?? 2

        // Full-frame translucent overlay with a big centered text layer —
        // used identically for the 3…2…1… countdown and the stage %.
        // (Separate text layer because CATextLayer draws from the top of its
        // bounds.)
        func makeFullFrameOverlay() -> (CALayer, CATextLayer) {
            let overlay = CALayer()
            overlay.frame = CGRect(x: 0, y: 0, width: 440, height: 280)
            overlay.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
            overlay.cornerRadius = 10
            overlay.isHidden = true

            let text = CATextLayer()
            text.font = NSFont.monospacedDigitSystemFont(ofSize: 72, weight: .bold)
            text.fontSize = 72
            text.foregroundColor = NSColor.white.cgColor
            text.alignmentMode = .center
            let numeralHeight: CGFloat = 88
            text.frame = CGRect(x: 0, y: (280 - numeralHeight) / 2 - 8, width: 440, height: numeralHeight)
            text.contentsScale = scale
            overlay.addSublayer(text)
            return (overlay, text)
        }

        let (countdownOverlay, countdown) = makeFullFrameOverlay()
        countdown.string = "3"
        preview.layer?.addSublayer(countdownOverlay)
        countdownBadge = countdown
        countdownOverlayLayer = countdownOverlay

        let (stageOverlay, stageText) = makeFullFrameOverlay()
        stageText.string = "0%"
        // Slightly smaller than the countdown numeral.
        stageText.fontSize = 56
        stageText.frame = CGRect(x: 0, y: (280 - 68) / 2 - 6, width: 440, height: 68)
        preview.layer?.addSublayer(stageOverlay)
        stageBadge = stageText
        stageOverlayLayer = stageOverlay

        let instruction = NSTextField(labelWithString: "Look straight at the camera")
        instruction.font = .systemFont(ofSize: 19, weight: .semibold)
        instruction.alignment = .center
        instructionLabel = instruction

        let status = NSTextField(labelWithString: "Get ready…")
        status.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        statusLabel = status

        // Overall progress across all stages.
        let progress = NSProgressIndicator()
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = Double(totalSamples)
        progress.doubleValue = 0
        progress.translatesAutoresizingMaskIntoConstraints = false
        progressBar = progress

        // Primary (accent, Return key) sits rightmost, the alternative action
        // to its left, Cancel leftmost — standard macOS ordering. The whole
        // row is centered by the outer stack.
        let cancel = NSButton.rounded("Cancel", target: self, action: #selector(cancelTapped))
        cancelButton = cancel

        let secondary = NSButton.rounded("Recapture", target: self, action: #selector(secondaryTapped))
        secondaryButton = secondary

        let primary = NSButton.rounded("Start", target: self, action: #selector(primaryTapped), isDefault: true)
        primaryButton = primary

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        controlsRow = controls
        cancelShown = true
        secondaryShown = false
        primaryShown = true
        rebuildControls()

        // Full-width container with a hard centerX pin: button centering
        // that can't depend on stack-view alignment quirks.
        let controlsContainer = NSView()
        controlsContainer.translatesAutoresizingMaskIntoConstraints = false
        controlsContainer.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.centerXAnchor.constraint(equalTo: controlsContainer.centerXAnchor),
            controls.topAnchor.constraint(equalTo: controlsContainer.topAnchor),
            controls.bottomAnchor.constraint(equalTo: controlsContainer.bottomAnchor),
        ])

        let stack = NSStackView(views: [preview, instruction, status, progress, controlsContainer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            preview.widthAnchor.constraint(equalToConstant: 440),
            preview.heightAnchor.constraint(equalToConstant: 280),
            progress.widthAnchor.constraint(equalToConstant: 440),
            controlsContainer.widthAnchor.constraint(equalToConstant: 440),
        ])
        // bounds+position instead of frame — frame is undefined once a
        // transform (the mirror flip) is set on the layer.
        layer.bounds = CGRect(x: 0, y: 0, width: 440, height: 280)
        layer.position = CGPoint(x: 220, y: 140)
        panel.contentView = content
        panel.present()
        self.panel = panel
    }

    func setInstruction(_ text: String) {
        if instructionLabel?.stringValue != text {
            instructionLabel?.stringValue = text
        }
    }

    func setStatus(_ text: String, isProblem: Bool = false) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = isProblem ? .systemOrange : .secondaryLabelColor
    }

    /// Overall progress bar below the preview.
    func setProgress(_ captured: Int) {
        progressBar?.doubleValue = Double(captured)
    }

    /// Current stage's capture progress — same full-frame overlay treatment
    /// as the countdown. Pass nil to hide.
    func setStageProgress(_ percent: Int?) {
        if let percent {
            stageBadge?.string = "\(percent)%"
            stageOverlayLayer?.isHidden = false
        } else {
            stageOverlayLayer?.isHidden = true
        }
    }

    /// 3… 2… 1… full-frame translucent overlay. Pass nil to hide.
    func setCountdown(_ seconds: Int?) {
        if let seconds {
            countdownBadge?.string = "\(seconds)"
            countdownOverlayLayer?.isHidden = false
        } else {
            countdownOverlayLayer?.isHidden = true
        }
    }

    /// Shows (or hides, when nil) the phase's main action button.
    func setPrimary(title: String?) {
        if let title { primaryButton?.title = title }
        primaryShown = title != nil
        rebuildControls()
    }

    /// Shows (or hides, when nil) the phase's alternative action button.
    func setSecondary(title: String?) {
        if let title { secondaryButton?.title = title }
        secondaryShown = title != nil
        rebuildControls()
    }

    func setCancelVisible(_ visible: Bool) {
        cancelShown = visible
        rebuildControls()
    }

    /// Repopulates the row with only the buttons that should be visible.
    private func rebuildControls() {
        guard let controlsRow else { return }
        for view in controlsRow.arrangedSubviews {
            controlsRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if cancelShown, let cancelButton { controlsRow.addArrangedSubview(cancelButton) }
        if secondaryShown, let secondaryButton { controlsRow.addArrangedSubview(secondaryButton) }
        if primaryShown, let primaryButton { controlsRow.addArrangedSubview(primaryButton) }
    }

    /// Verification passed (text only — the caller sets the buttons).
    func showVerified(score: Float) {
        setInstruction("Verified: it's you ✓")
        statusLabel?.stringValue = String(format: "Match score %.2f against your new profile.", score)
        statusLabel?.textColor = .systemGreen
    }

    /// Enrollment/verification failed (text only — caller sets the buttons).
    func showVerifyFailure(_ message: String) {
        setInstruction("Enrollment failed")
        statusLabel?.stringValue = message
        statusLabel?.textColor = .systemRed
    }

    func dismiss() {
        previewLayer?.session = nil
        previewLayer = nil
        panel?.orderOut(nil)
        panel = nil
        instructionLabel = nil
        statusLabel = nil
        progressBar = nil
        stageBadge = nil
        stageOverlayLayer = nil
        countdownBadge = nil
        countdownOverlayLayer = nil
        controlsRow = nil
        primaryButton = nil
        secondaryButton = nil
        cancelButton = nil
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    @objc private func primaryTapped() {
        onPrimary?()
    }

    @objc private func secondaryTapped() {
        onSecondary?()
    }
}

extension EnrollmentPanel: NSWindowDelegate {
    /// The title-bar close button force-cancels the whole enrollment,
    /// whatever phase it's in.
    func windowWillClose(_ notification: Notification) {
        onCancel?()
    }
}

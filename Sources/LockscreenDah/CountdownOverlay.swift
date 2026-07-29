import AppKit
import AVFoundation

/// The countdown overlay: a blank black takeover of every screen with a
/// small, faded countdown in the bottom-right corner. To a passerby it reads
/// as a display that went to sleep — and it hides whatever was on screen — but
/// to the owner nearby the sudden blackout plus a soft chime is the cue to
/// come back.
///
/// Cancelling: facing the screen is the intended cancel (face match). Esc also
/// works but is deliberately not advertised on screen; clicks do nothing, so a
/// curious passerby can't reveal the desktop.
final class CountdownOverlay: NSObject {
    var onCancel: (() -> Void)?

    private var windows: [NSWindow] = []
    private var countdownLabels: [NSTextField] = []
    /// Last value passed to `show`/`update`, so a rebuild can redraw immediately.
    private var lastRemaining: TimeInterval = 0
    private var screenObserver: NSObjectProtocol?

    func show(remaining: TimeInterval) {
        dismiss()
        // A display attached (or rearranged) mid-countdown would otherwise stay
        // uncovered, mirroring or extending the desktop the overlay exists to
        // hide. Rebuilding covers the new layout — without replaying the chime
        // or restarting the fade, which would make a monitor being plugged in
        // look like a fresh countdown.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.windows.isEmpty else { return }
            self.buildWindows(remaining: self.lastRemaining, fadeIn: false)
        }
        buildWindows(remaining: remaining, fadeIn: true)
        if let chime = NSSound(named: "Tink") {
            chime.volume = 0.5
            chime.play()
        }
    }

    private func buildWindows(remaining: TimeInterval, fadeIn: Bool) {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        countdownLabels.removeAll()

        for screen in NSScreen.screens {
            let window = EscapableWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.isOpaque = true
            window.backgroundColor = .black
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.onEscape = { [weak self] in self?.onCancel?() }

            let countdown = NSTextField(labelWithString: "")
            countdown.font = .monospacedDigitSystemFont(ofSize: 42, weight: .medium)
            countdown.textColor = NSColor.white.withAlphaComponent(0.28)
            countdown.alignment = .right
            countdown.translatesAutoresizingMaskIntoConstraints = false
            countdownLabels.append(countdown)

            let content = NSView(frame: screen.frame)
            content.addSubview(countdown)
            NSLayoutConstraint.activate([
                countdown.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -44),
                countdown.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -36),
            ])
            window.contentView = content

            window.alphaValue = fadeIn ? 0 : 1
            window.orderFrontRegardless()
            windows.append(window)
        }

        // Grab key focus so stray keystrokes land on the (inert) overlay
        // instead of whatever window was exposed underneath.
        windows.first?.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        update(remaining: remaining)
        guard fadeIn else { return }
        NSAnimationContext.runAnimationGroup { context in
            // Short enough that the countdown is legible almost immediately:
            // the fade is subtracted from the warning the user actually gets,
            // and at a 1 s countdown a half-second fade ate half of it.
            context.duration = 0.2
            for window in windows {
                window.animator().alphaValue = 1
            }
        }
    }

    func update(remaining: TimeInterval) {
        lastRemaining = remaining
        let seconds = max(0, Int(remaining.rounded(.up)))
        let text = "\(seconds)"
        for label in countdownLabels where label.stringValue != text {
            label.stringValue = text
        }
    }

    func dismiss() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        countdownLabels.removeAll()
    }
}

/// Borderless windows can't become key by default; this one can, and turns
/// Esc into a cancel callback while swallowing every other event.
private final class EscapableWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onEscape?()
        }
        // Swallow everything else — keystrokes must not reach hidden windows.
    }
}

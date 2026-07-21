import AppKit

extension NSPanel {
    /// Shared construction for the app's floating utility panels
    /// (Active Hours, About, Enroll Face).
    static func floating(title: String, contentSize: NSSize = .zero) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Brings the panel to the front and focuses the app — the shared tail
    /// of every panel's show path.
    func present() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension NSButton {
    /// Standard rounded action button; `isDefault` gives it the Return key
    /// (and the accent color).
    static func rounded(
        _ title: String,
        target: AnyObject?,
        action: Selector,
        isDefault: Bool = false
    ) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        if isDefault { button.keyEquivalent = "\r" }
        return button
    }
}

import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let coordinator = MonitorCoordinator()
    private lazy var activeHoursPanel: ActiveHoursPanel = {
        let panel = ActiveHoursPanel()
        panel.onSettingsChanged = { [weak self] in self?.coordinator.scheduleSettingsChanged() }
        return panel
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = statusImage(named: "faceid")

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        coordinator.onStateChange = { [weak self] in self?.refreshStatusIcon() }

        registerLoginItemOnFirstRun()
        coordinator.startPerSchedule()
    }

    // MARK: - Status icon

    private func statusImage(named symbol: String) -> NSImage? {
        let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Lockscreen Dah?"
        )
        image?.isTemplate = true
        return image
    }

    private func refreshStatusIcon() {
        let symbol: String
        switch coordinator.state {
        case .paused: symbol = "pause.circle"
        // Alerting/locked keep the watching icon — the blackout overlay or
        // lock screen hides the menu bar anyway.
        case .watching, .alerting, .locked:
            if coordinator.recognizer.isPresenceOnly {
                // No enrolled face (or no model) — flag it at a glance.
                symbol = "exclamationmark.triangle.fill"
            } else {
                symbol = coordinator.cameraResting ? "moon.zzz.fill" : "faceid"
            }
        case .enrolling: symbol = "person.crop.circle.badge.plus"
        }
        statusItem.button?.image = statusImage(named: symbol)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: coordinator.statusDescription, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let isPaused = coordinator.state == .paused
        let toggle = NSMenuItem(
            title: isPaused ? "Start Monitoring" : "Pause Monitoring",
            action: #selector(toggleMonitoring),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.image = NSImage(
            systemSymbolName: isPaused ? "play.fill" : "pause.fill",
            accessibilityDescription: nil
        )
        menu.addItem(toggle)

        let enroll = NSMenuItem(title: "", action: #selector(enrollFace), keyEquivalent: "")
        enroll.target = self
        if !coordinator.recognizer.hasModel {
            enroll.action = nil
            enroll.title = "Face model missing (run scripts/fetch-model.sh)"
        } else if coordinator.recognizer.hasProfile {
            enroll.title = "Re-Enroll My Face"
            enroll.image = NSImage(
                systemSymbolName: "arrow.clockwise",
                accessibilityDescription: nil
            )
        } else {
            enroll.attributedTitle = NSAttributedString(
                string: "No Face Enrolled",
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.menuFont(ofSize: 0),
                ]
            )
            // Palette layers: [mark, triangle] — one color would swallow the
            // exclamation mark into the triangle fill.
            enroll.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
        }
        menu.addItem(enroll)
        menu.addItem(.separator())

        menu.addItem(settingsSubmenu())
        menu.addItem(.separator())

        let about = NSMenuItem(
            title: "About Lockscreen Dah?",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Lockscreen Dah?", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Settings submenu (stay-open option rows)

    private func settingsSubmenu() -> NSMenuItem {
        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu(title: "Settings")
        // View-backed items have no action, so auto-enablement would mark
        // them disabled and AppKit would render their views dimmed.
        settingsMenu.autoenablesItems = false

        settingsMenu.addItem(durationSubmenu(
            title: "Start Countdown After",
            options: Settings.gracePeriodOptions,
            get: { Settings.gracePeriod },
            set: { Settings.gracePeriod = $0 }
        ))
        settingsMenu.addItem(durationSubmenu(
            title: "Countdown Duration",
            options: Settings.countdownOptions,
            get: { Settings.countdownDuration },
            set: { Settings.countdownDuration = $0 }
        ))
        // Built before the idle item so its enabled state can track "Never
        // Idle" live (waking from idle is meaningless when idling is off).
        let wakeItem = durationSubmenu(
            title: "Wake From Idle After",
            options: Settings.cameraWakeOptions,
            get: { Settings.cameraWakeQuiet },
            set: { Settings.cameraWakeQuiet = $0 }
        )
        wakeItem.isEnabled = Settings.cameraRestAfter > 0
        settingsMenu.addItem(durationSubmenu(
            title: "Idle When Typing For",
            options: Settings.cameraRestOptions,
            get: { Settings.cameraRestAfter },
            set: { [weak wakeItem] in
                Settings.cameraRestAfter = $0
                wakeItem?.isEnabled = $0 > 0
            },
            rowLabel: { $0 == 0 ? "Never Idle" : ($0 == 1 ? "1 second" : "\(Int($0)) seconds") },
            valueLabel: { $0 == 0 ? "Never" : "\(Int($0))s" }
        ))
        settingsMenu.addItem(wakeItem)
        let hoursTitle = Settings.scheduleEnabled
            ? "Active Hours (\(Settings.formatMinutes(Settings.scheduleStartMinutes))–\(Settings.formatMinutes(Settings.scheduleEndMinutes)))…"
            : "Active Hours (always on)…"
        let hours = NSMenuItem(title: hoursTitle, action: #selector(showActiveHours), keyEquivalent: "")
        hours.target = self
        settingsMenu.addItem(hours)
        settingsMenu.addItem(.separator())

        // Tight layout: aligns with the native submenu rows above it, which
        // have no checkmark gutter.
        let loginView = StayOpenOptionView(title: "Open at Login", layout: .tight)
        loginView.isChecked = SMAppService.mainApp.status == .enabled
        loginView.onClick = { [weak self, weak loginView] in
            self?.toggleLaunchAtLogin()
            loginView?.isChecked = SMAppService.mainApp.status == .enabled
        }
        let loginItem = NSMenuItem()
        loginItem.view = loginView
        settingsMenu.addItem(loginItem)

        settings.submenu = settingsMenu
        return settings
    }

    /// A submenu of stay-open duration options; the parent title shows the
    /// chosen value and refreshes live when an option is clicked. Optional
    /// label closures cover non-duration options (e.g. 0 = "Never Idle").
    private func durationSubmenu(
        title: String,
        options: [TimeInterval],
        get: @escaping () -> TimeInterval,
        set: @escaping (TimeInterval) -> Void,
        rowLabel: ((TimeInterval) -> String)? = nil,
        valueLabel: ((TimeInterval) -> String)? = nil
    ) -> NSMenuItem {
        let row = rowLabel ?? { $0 == 1 ? "1 second" : "\(Int($0)) seconds" }
        let value = valueLabel ?? { "\(Int($0))s" }
        let parent = NSMenuItem(title: "\(title) \(value(get()))", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false

        var views: [(StayOpenOptionView, TimeInterval)] = []
        for option in options {
            let view = StayOpenOptionView(title: row(option))
            view.isChecked = option == get()
            view.onClick = { [weak parent] in
                set(option)
                for (optionView, optionValue) in views {
                    optionView.isChecked = optionValue == get()
                }
                parent?.title = "\(title) \(value(get()))"
            }
            views.append((view, option))
            let item = NSMenuItem()
            item.view = view
            submenu.addItem(item)
        }

        parent.submenu = submenu
        return parent
    }

    // MARK: - Actions

    @objc private func showActiveHours() {
        activeHoursPanel.show()
    }

    @objc private func toggleMonitoring() {
        if coordinator.state == .paused {
            coordinator.startMonitoring()
        } else {
            coordinator.pause()
        }
    }

    @objc private func enrollFace() {
        coordinator.enrollFace()
    }

    @objc private func showAbout() {
        AboutPanel.shared.show()
    }

    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not update login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Login item

    private func registerLoginItemOnFirstRun() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // Only meaningful when running from a stable location (build.sh installs
        // to /Applications). Failure is fine — the menu toggle remains.
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: key)
    }
}

/// Menu-item row backed by a custom view: clicking applies the option and
/// keeps the menu open (a plain NSMenuItem always dismisses on click). The
/// menu still closes on hover-away or clicking elsewhere, as usual.
final class StayOpenOptionView: NSView {
    enum Layout {
        /// Checkmark gutter like a native checkable menu (all-custom submenus).
        case standard
        /// No gutter — title aligns with native, non-checkable sibling rows;
        /// the checkmark squeezes into the leading padding.
        case tight
    }

    var onClick: (() -> Void)?

    var isChecked = false { didSet { needsDisplay = true } }
    private var isHighlighted = false { didSet { needsDisplay = true } }

    private let title: String
    private let indent: Bool
    private let layout: Layout
    private static let font = NSFont.menuFont(ofSize: 13)

    /// Draw with the same vibrant blending as native menu text — without this
    /// the labels look washed out next to real menu items.
    override var allowsVibrancy: Bool { true }

    init(title: String, indent: Bool = false, layout: Layout = .standard) {
        self.title = title
        self.indent = indent
        self.layout = layout
        let textWidth = (title as NSString)
            .size(withAttributes: [.font: Self.font]).width
        super.init(frame: NSRect(x: 0, y: 0, width: max(220, textWidth + 64), height: 22))
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
    }

    override func mouseUp(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            let highlight = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 5, dy: 1),
                xRadius: 4, yRadius: 4
            )
            NSColor.controlAccentColor.setFill()
            highlight.fill()
        }

        let textColor: NSColor = isHighlighted ? .white : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: textColor,
        ]

        let checkX: CGFloat
        let titleX: CGFloat
        switch layout {
        case .standard:
            checkX = 11 + (indent ? 12 : 0)
            titleX = checkX + 18
        case .tight:
            // Title aligns with native rows; the checkmark sits at the
            // trailing end like a toggle indicator.
            checkX = bounds.width - 24
            titleX = 15 + (indent ? 12 : 0)
        }
        if isChecked {
            ("✓" as NSString).draw(
                at: NSPoint(x: checkX, y: 3),
                withAttributes: attributes
            )
        }
        (title as NSString).draw(
            at: NSPoint(x: titleX, y: 3),
            withAttributes: attributes
        )
    }
}

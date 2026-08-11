import AppKit

/// Owns the menu-bar presence: the status item, its icon, its menu, and the
/// actions those items invoke. Split out of `AppDelegate`, which now does only
/// app lifecycle — menu construction is presentation and has no business sitting
/// next to launch sequencing.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let coordinator: MonitorCoordinator
    private let statusItem: NSStatusItem
    private lazy var activeHoursPanel: ActiveHoursPanel = {
        let panel = ActiveHoursPanel()
        panel.onSettingsChanged = { [weak self] in self?.coordinator.scheduleSettingsChanged() }
        return panel
    }()

    init(coordinator: MonitorCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshStatusIcon()

        coordinator.onStateChange = { [weak self] in self?.refreshStatusIcon() }
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
        // Not the pause icon: nothing is being watched and the user didn't
        // choose that, so it has to look like a problem rather than a setting.
        case .cameraUnavailable: symbol = "video.slash.fill"
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

        let isPaused = coordinator.state == .paused || coordinator.state == .cameraUnavailable
        // Recognition already proved unreliable, so the way back is through a
        // fresh profile — say that on the button rather than offering a plain
        // Start that would silently do nothing.
        let needsReenrollment = isPaused && Settings.reenrollmentRequired
        let toggleTitle: String
        if needsReenrollment {
            toggleTitle = "Re-Enroll to Resume"
        } else {
            toggleTitle = isPaused ? "Start Monitoring" : "Pause Monitoring"
        }
        let toggle = NSMenuItem(
            title: toggleTitle,
            action: #selector(toggleMonitoring),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.image = NSImage(
            systemSymbolName: needsReenrollment ? "arrow.clockwise" : (isPaused ? "play.fill" : "pause.fill"),
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

        // The idle pair is built first so the countdown-delay rows below can
        // refresh their availability live: camera rest can't operate under a
        // short delay, and these rows say so rather than silently ignoring it.
        let idleTitle = "Idle When Typing For"
        let idleValueLabel: (TimeInterval) -> String = { $0 == 0 ? "Never" : "\(Int($0))s" }
        let wakeItem = durationSubmenu(
            title: "Wake From Idle After",
            options: Settings.cameraWakeOptions,
            get: { Settings.cameraWakeQuiet },
            set: { Settings.cameraWakeQuiet = $0 }
        )
        let idleItem = durationSubmenu(
            title: idleTitle,
            options: Settings.cameraRestOptions,
            get: { Settings.cameraRestAfter },
            set: { [weak wakeItem] in
                Settings.cameraRestAfter = $0
                wakeItem?.isEnabled = $0 > 0 && Settings.cameraRestAvailable
            },
            rowLabel: { $0 == 0 ? "Never Idle" : "\(Int($0)) seconds" },
            valueLabel: idleValueLabel
        )
        let refreshIdleAvailability = { [weak idleItem, weak wakeItem] in
            let available = Settings.cameraRestAvailable
            idleItem?.isEnabled = available
            idleItem?.title = available
                ? "\(idleTitle) \(idleValueLabel(Settings.cameraRestAfter))"
                : "\(idleTitle) (needs \(Int(Settings.cameraRestMinimumGrace))s+)"
            wakeItem?.isEnabled = available && Settings.cameraRestAfter > 0
        }
        refreshIdleAvailability()

        settingsMenu.addItem(durationSubmenu(
            title: "Start Countdown After",
            options: Settings.gracePeriodOptions,
            get: { Settings.gracePeriod },
            set: { [weak self] in
                Settings.gracePeriod = $0
                // The scheduled countdown deadline (if already watching) was
                // computed from the old grace period — recompute it now
                // rather than waiting for the next real presence observation.
                self?.coordinator.gracePeriodSettingChanged()
                // This setting gates camera rest, so the rows below it can
                // change availability from under the open menu.
                refreshIdleAvailability()
            }
        ))
        settingsMenu.addItem(durationSubmenu(
            title: "Countdown Duration",
            options: Settings.countdownOptions,
            get: { Settings.countdownDuration },
            set: { Settings.countdownDuration = $0 },
            rowLabel: { $0 == 0 ? "Never Countdown" : "\(Int($0)) seconds" },
            valueLabel: { $0 == 0 ? "Never" : "\(Int($0))s" }
        ))
        settingsMenu.addItem(idleItem)
        settingsMenu.addItem(wakeItem)
        let hoursTitle: String
        if Settings.scheduleEnabled {
            let span = "\(Settings.formatMinutes(Settings.scheduleStartMinutes))–\(Settings.formatMinutes(Settings.scheduleEndMinutes))"
            hoursTitle = "Active Hours (\(span), \(Weekday.describe(Settings.activeDays)))…"
        } else {
            hoursTitle = "Active Hours (always on)…"
        }
        let hours = NSMenuItem(title: hoursTitle, action: #selector(showActiveHours), keyEquivalent: "")
        hours.target = self
        settingsMenu.addItem(hours)
        settingsMenu.addItem(.separator())

        // Tight layout: aligns with the native submenu rows above it, which
        // have no checkmark gutter.
        let loginView = StayOpenOptionView(title: "Open at Login", layout: .tight)
        loginView.isChecked = LoginItem.isRegistered
        loginView.onClick = { [weak self, weak loginView] in
            self?.toggleLaunchAtLogin()
            loginView?.isChecked = LoginItem.isRegistered
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

        // A value chosen from an earlier build's list (say a 15 s idle delay that
        // is no longer offered) is still in effect, so it gets its own row rather
        // than leaving every row unticked — which reads as "nothing is set".
        // Settings are never rewritten behind the user's back to force a match.
        var options = options
        if !options.contains(get()) {
            let never = options.filter { $0 == 0 } // 0 renders as "Never", stays last
            options = (options.filter { $0 != 0 } + [get()]).sorted() + never
        }

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
        let isOff = coordinator.state == .paused || coordinator.state == .cameraUnavailable
        guard isOff else {
            coordinator.pause()
            return
        }
        // The only route past an outstanding re-enrollment requirement. The
        // existing profile stays in use until the new one is saved, so a
        // cancelled enrollment leaves you no worse off.
        if Settings.reenrollmentRequired {
            coordinator.enrollFace()
        } else {
            coordinator.startMonitoring()
        }
    }

    @objc private func enrollFace() {
        coordinator.enrollFace()
    }

    @objc private func showAbout() {
        AboutPanel.shared.show()
    }

    private func toggleLaunchAtLogin() {
        guard let error = LoginItem.toggle() else { return }
        let alert = NSAlert()
        alert.messageText = "Could not update login item"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

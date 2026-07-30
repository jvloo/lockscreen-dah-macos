import AppKit

/// Compact settings panel for the monitoring schedule: an "Always on"
/// checkbox, hour:minute pickers for start/end, and the weekdays it runs on.
/// Edits are local until Save — Cancel discards them.
final class ActiveHoursPanel: NSObject {
    /// Fired after Save so the coordinator can enforce the new schedule.
    var onSettingsChanged: (() -> Void)?

    private var panel: NSPanel?
    private var alwaysOnCheckbox: NSButton?
    private var startPicker: NSDatePicker?
    private var endPicker: NSDatePicker?
    private var allDaysCheckbox: NSButton?
    /// Keyed by `Calendar` weekday number (1 = Sunday).
    private var dayCheckboxes: [Int: NSButton] = [:]

    func show() {
        if let panel {
            refreshControls()
            panel.present()
            return
        }

        let panel = NSPanel.floating(title: "Active Hours & Days")

        // Checked = ignore the schedule entirely.
        let alwaysOn = NSButton(
            checkboxWithTitle: "Always on",
            target: self,
            action: #selector(toggleAlwaysOn)
        )
        alwaysOnCheckbox = alwaysOn

        let startLabel = NSTextField(labelWithString: "Start:")
        let endLabel = NSTextField(labelWithString: "End:")
        for label in [startLabel, endLabel] {
            label.font = .systemFont(ofSize: 13)
        }

        let start = makePicker(minutes: Settings.scheduleStartMinutes)
        let end = makePicker(minutes: Settings.scheduleEndMinutes)
        startPicker = start
        endPicker = end

        let grid = NSGridView(views: [
            [startLabel, start],
            [endLabel, end],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .leading
        // Labels vertically centered against the pickers; the input column
        // fills the remaining width so pickers end flush with the Save button.
        grid.column(at: 0).width = 60
        grid.column(at: 1).xPlacement = .fill
        grid.rowAlignment = .none
        for row in 0..<grid.numberOfRows {
            grid.row(at: row).yPlacement = .center
        }

        let allDays = NSButton(
            checkboxWithTitle: "All days",
            target: self,
            action: #selector(toggleAllDays)
        )
        allDaysCheckbox = allDays

        // Monday-first, which is how a work week reads — Calendar numbers
        // Sunday as 1, so display order is explicit rather than 1...7.
        var dayButtons: [NSView] = []
        for weekday in Settings.weekdayDisplayOrder {
            let box = NSButton(
                checkboxWithTitle: Settings.weekdayName(weekday),
                target: self,
                action: #selector(toggleDay)
            )
            box.tag = weekday
            dayCheckboxes[weekday] = box
            dayButtons.append(box)
        }
        let dayRow = NSStackView(views: dayButtons)
        dayRow.orientation = .horizontal
        dayRow.spacing = 8
        dayRow.alignment = .centerY

        let daysLabel = NSTextField(labelWithString: "Days:")
        daysLabel.font = .systemFont(ofSize: 13)

        // Everything hangs off the same leading edge.
        let stack = NSStackView(views: [alwaysOn, grid, daysLabel, dayRow, allDays])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton.rounded("Cancel", target: self, action: #selector(cancelTapped))
        let save = NSButton.rounded("Save", target: self, action: #selector(saveTapped), isDefault: true)

        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            // Inputs stretch to the same right edge as the Save button.
            grid.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 18),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        panel.contentView = content
        refreshControls()
        var size = content.fittingSize
        size.width = max(size.width, 430) // wide enough for seven day checkboxes
        panel.setContentSize(size)
        panel.center()
        panel.present()
        self.panel = panel
    }

    private func makePicker(minutes: Int) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.dateValue = Self.date(fromMinutes: minutes)
        return picker
    }

    /// Resets the controls to the persisted settings (used on every open, so
    /// a previous Cancel leaves no stale edits behind).
    private func refreshControls() {
        let alwaysOn = !Settings.scheduleEnabled
        alwaysOnCheckbox?.state = alwaysOn ? .on : .off
        startPicker?.isEnabled = !alwaysOn
        endPicker?.isEnabled = !alwaysOn
        startPicker?.dateValue = Self.date(fromMinutes: Settings.scheduleStartMinutes)
        endPicker?.dateValue = Self.date(fromMinutes: Settings.scheduleEndMinutes)

        let days = Settings.activeDays
        for (weekday, box) in dayCheckboxes {
            box.state = days.contains(weekday) ? .on : .off
        }
        allDaysCheckbox?.state = days.count == 7 ? .on : .off
        setDayControlsEnabled(!alwaysOn)
    }

    private func setDayControlsEnabled(_ enabled: Bool) {
        allDaysCheckbox?.isEnabled = enabled
        dayCheckboxes.values.forEach { $0.isEnabled = enabled }
    }

    private var checkedDays: Set<Int> {
        Set(dayCheckboxes.filter { $0.value.state == .on }.keys)
    }

    // MARK: - Actions

    @objc private func toggleAlwaysOn() {
        // Local UI state only — nothing persists until Save.
        let alwaysOn = alwaysOnCheckbox?.state == .on
        startPicker?.isEnabled = !alwaysOn
        endPicker?.isEnabled = !alwaysOn
        setDayControlsEnabled(!alwaysOn)
    }

    @objc private func toggleAllDays() {
        let all = allDaysCheckbox?.state == .on
        // Unticking "All days" would otherwise leave every day selected and the
        // checkbox contradicting them, so fall back to the default work week.
        let target = all ? Set(1...7) : Settings.defaultActiveDays
        for (weekday, box) in dayCheckboxes {
            box.state = target.contains(weekday) ? .on : .off
        }
    }

    @objc private func toggleDay(_ sender: NSButton) {
        // At least one day must stay selected: an empty set would mean
        // monitoring never runs, which reads as "protected" but isn't.
        if checkedDays.isEmpty {
            sender.state = .on
            NSSound.beep()
            return
        }
        allDaysCheckbox?.state = checkedDays.count == 7 ? .on : .off
    }

    @objc private func saveTapped() {
        let alwaysOn = alwaysOnCheckbox?.state == .on

        // Only validate what the user can actually edit: when "Always on" is
        // ticked the schedule controls are disabled, and the stored hours/days
        // are left untouched so they're still there if it's unticked later.
        if !alwaysOn {
            guard let startPicker, let endPicker else { return }
            let start = Self.minutes(from: startPicker.dateValue)
            let end = Self.minutes(from: endPicker.dateValue)

            // Equal start and end has no single honest reading — a whole day, or
            // none of it? Reject rather than silently picking one.
            guard start != end else {
                reject(
                    "Start and end can't be the same time.",
                    "Choose different times, or tick \u{201C}Always on\u{201D} to monitor around the clock."
                )
                return
            }
            guard !checkedDays.isEmpty else {
                reject(
                    "Choose at least one day.",
                    "With no days selected, monitoring would never run — which looks configured but protects nothing."
                )
                return
            }

            Settings.scheduleStartMinutes = start
            Settings.scheduleEndMinutes = end
            Settings.activeDays = checkedDays
        }

        Settings.scheduleEnabled = !alwaysOn
        onSettingsChanged?()
        panel?.orderOut(nil)
    }

    /// Refuses the Save and explains why, leaving the panel open with the edits
    /// intact so the user can correct them.
    private func reject(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        if let panel {
            alert.beginSheetModal(for: panel, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    @objc private func cancelTapped() {
        panel?.orderOut(nil)
    }

    // MARK: - Conversions

    private static func date(fromMinutes minutes: Int) -> Date {
        Calendar.current.date(
            bySettingHour: minutes / 60,
            minute: minutes % 60,
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private static func minutes(from date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

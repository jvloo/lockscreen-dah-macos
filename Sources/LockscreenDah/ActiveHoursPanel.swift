import AppKit

/// Compact settings panel for Active Hours: an "Always on" checkbox and
/// hour:minute pickers for start/end. Edits are local until Save — Cancel
/// discards them.
final class ActiveHoursPanel: NSObject {
    /// Fired after Save so the coordinator can enforce the new schedule.
    var onSettingsChanged: (() -> Void)?

    private var panel: NSPanel?
    private var alwaysOnCheckbox: NSButton?
    private var startPicker: NSDatePicker?
    private var endPicker: NSDatePicker?

    func show() {
        if let panel {
            refreshControls()
            panel.present()
            return
        }

        let panel = NSPanel.floating(title: "Active Hours")

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

        // Everything hangs off the same leading edge.
        let stack = NSStackView(views: [alwaysOn, grid])
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
        size.width = max(size.width, 330) // breathing room beyond the tight fit
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
    }

    // MARK: - Actions

    @objc private func toggleAlwaysOn() {
        // Local UI state only — nothing persists until Save.
        let alwaysOn = alwaysOnCheckbox?.state == .on
        startPicker?.isEnabled = !alwaysOn
        endPicker?.isEnabled = !alwaysOn
    }

    @objc private func saveTapped() {
        Settings.scheduleEnabled = alwaysOnCheckbox?.state == .off
        if let startPicker {
            Settings.scheduleStartMinutes = Self.minutes(from: startPicker.dateValue)
        }
        if let endPicker {
            Settings.scheduleEndMinutes = Self.minutes(from: endPicker.dateValue)
        }
        onSettingsChanged?()
        panel?.orderOut(nil)
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

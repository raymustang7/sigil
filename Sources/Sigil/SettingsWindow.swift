import AppKit

/// Sigil's Settings window: appearance and hint budget, laid out as a labelled grid so further
/// settings can be added as rows. Edits write straight through `SigilSettings`, which clamps and
/// persists them. Appearance applies immediately; the budget on the next hint-mode activation.
final class SettingsWindowController: NSObject {
    private let settings: SigilSettings
    private var window: NSWindow?
    private var budgetField: NSTextField!
    private var budgetStepper: NSStepper!
    private var appearanceControl: NSSegmentedControl!
    /// Segment order for the appearance switcher.
    private let appearanceModes: [AppearanceMode] = [.system, .light, .dark]

    init(settings: SigilSettings = .shared) {
        self.settings = settings
        super.init()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        refresh()
        // Sigil is an accessory (menu-bar) app, so it must activate to bring a window forward.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Construction

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sigil Settings"
        window.isReleasedWhenClosed = false

        let content = NSView()
        let grid = makeGrid()
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        window.center()
        return window
    }

    private func makeGrid() -> NSGridView {
        let range = SigilSettings.hintBudgetRange

        let appearanceLabel = NSTextField(labelWithString: "Appearance:")
        appearanceLabel.alignment = .right

        let appearance = NSSegmentedControl(
            labels: appearanceModes.map(Self.title(for:)),
            trackingMode: .selectOne,
            target: self,
            action: #selector(appearanceChanged(_:))
        )
        appearanceControl = appearance

        let appearanceCaption = NSTextField(wrappingLabelWithString:
            "Colour scheme for hints and Sigil's windows. System follows your Mac's Light/Dark setting.")
        appearanceCaption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        appearanceCaption.textColor = .secondaryLabelColor
        appearanceCaption.preferredMaxLayoutWidth = 300
        appearanceCaption.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true

        let label = NSTextField(labelWithString: "Hint budget:")
        label.alignment = .right

        let field = NSTextField(string: "")
        field.alignment = .right
        field.target = self
        field.action = #selector(fieldChanged(_:))
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        budgetField = field

        let stepper = NSStepper()
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = 50
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
        budgetStepper = stepper

        let control = NSStackView(views: [field, stepper])
        control.orientation = .horizontal
        control.spacing = 4

        let caption = NSTextField(wrappingLabelWithString:
            "Maximum hints shown at once (\(range.lowerBound)–\(range.upperBound), default \(SigilSettings.defaultHintBudget)). " +
            "Shared fairly across visible windows; higher values add a little scan time. " +
            "Applies on the next activation.")
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.preferredMaxLayoutWidth = 300
        caption.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true

        let reset = NSButton(title: "Reset to Default", target: self, action: #selector(resetBudget(_:)))
        reset.bezelStyle = .rounded

        let grid = NSGridView(views: [
            [appearanceLabel, appearance],
            [NSGridCell.emptyContentView, appearanceCaption],
            [label, control],
            [NSGridCell.emptyContentView, caption],
            [NSGridCell.emptyContentView, reset],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        // Breathing room between the appearance group and the budget group.
        grid.row(at: 2).topPadding = 12
        return grid
    }

    private static func title(for mode: AppearanceMode) -> String {
        switch mode {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    // MARK: - Actions

    @objc private func appearanceChanged(_ sender: NSSegmentedControl) {
        guard appearanceModes.indices.contains(sender.selectedSegment) else { return }
        settings.appearanceMode = appearanceModes[sender.selectedSegment]
        refresh()
    }

    @objc private func fieldChanged(_ sender: NSTextField) {
        // Non-numeric input is ignored and the field snaps back to the stored value.
        if let value = Int(sender.stringValue.trimmingCharacters(in: .whitespaces)) {
            settings.hintBudget = value
        }
        refresh()
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        settings.hintBudget = sender.integerValue
        refresh()
    }

    @objc private func resetBudget(_ sender: Any?) {
        settings.resetHintBudget()
        refresh()
    }

    private func refresh() {
        appearanceControl.selectedSegment = appearanceModes.firstIndex(of: settings.appearanceMode) ?? 0
        budgetField.stringValue = String(settings.hintBudget)
        budgetStepper.integerValue = settings.hintBudget
    }
}

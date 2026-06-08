import AppKit

/// Owns the global keyboard tap and routes each keystroke to whichever feature mode is active,
/// or starts a mode when its activation hotkey is pressed.
final class InputCoordinator {
    private let inputTap = InputTap()
    private let hintMode = HintModeController()
    private let switcher = WindowSwitcherController()
    private let visualMode = VisualModeController()

    /// Forwarded from Visual mode: `true` when it turns on, `false` when it turns off.
    var onVisualModeActiveChange: ((Bool) -> Void)? {
        didSet { visualMode.onActiveChange = onVisualModeActiveChange }
    }

    /// Forwarded from Visual mode: the current typed query (empty when cleared).
    var onVisualQueryChange: ((String) -> Void)? {
        didSet { visualMode.onQueryChange = onVisualQueryChange }
    }

    /// Forwarded from Visual mode: the current number of matching elements.
    var onVisualMatchesChange: ((Int) -> Void)? {
        didSet { visualMode.onMatchesChange = onVisualMatchesChange }
    }

    /// Leave Visual mode (used by the menu-bar "Exit Visual Mode" item).
    func exitVisualMode() {
        visualMode.exit()
    }

    /// Starts intercepting input. Returns `false` if the event tap could not be created
    /// (Accessibility permission missing).
    @discardableResult
    func start() -> Bool {
        inputTap.onKeyDown = { [weak self] stroke in
            self?.route(stroke) ?? false
        }
        return inputTap.start()
    }

    func stop() {
        inputTap.stop()
    }

    /// Returns `true` to consume the event.
    private func route(_ stroke: KeyStroke) -> Bool {
        if hintMode.isActive { return hintMode.handle(stroke) }
        if switcher.isActive { return switcher.handle(stroke) }
        if visualMode.isActive { return visualMode.handle(stroke) }

        if hintMode.isActivationHotkey(stroke) {
            hintMode.activate()
            return true
        }
        if switcher.isActivationHotkey(stroke) {
            switcher.activate()
            return true
        }
        if visualMode.isActivationHotkey(stroke) {
            visualMode.activate()
            return true
        }
        return false
    }
}

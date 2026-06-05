import AppKit

/// Drives the window-switcher mode: hotkey → enumerate windows → live-filter as the user types
/// → press a number to focus the matching window.
final class WindowSwitcherController {
    private enum State {
        case idle
        /// Window list being gathered off-thread; swallow keys until it's ready.
        case activating
        case active
    }

    private let overlay = SwitcherOverlayController()
    private let scanQueue = DispatchQueue(label: "com.sigil.switcher", qos: .userInteractive)

    private var state: State = .idle
    private var allEntries: [WindowEntry] = []
    private var results: [WindowEntry] = []
    private var query = ""

    /// Numbered selection caps the visible list at the digits 1–9.
    private let maxResults = 9

    var isActive: Bool { state != .idle }

    /// Ctrl + Shift + Space.
    func isActivationHotkey(_ stroke: KeyStroke) -> Bool {
        stroke.keyCode == KeyStroke.space
            && stroke.hasControl
            && stroke.hasShift
            && !stroke.hasCommand
            && !stroke.hasOption
    }

    func activate() {
        Log.write("hotkey: Ctrl+Shift+Space received — entering window switcher")
        state = .activating
        query = ""
        // Enumerating windows touches the AX APIs of every app; keep it off the run loop that
        // services the event tap.
        scanQueue.async { [weak self] in
            let entries = WindowSwitcher.allWindows()
            DispatchQueue.main.async {
                guard let self, self.state == .activating else { return }
                self.allEntries = entries
                self.refresh()
                self.state = .active
            }
        }
    }

    // MARK: - Key handling

    func handle(_ stroke: KeyStroke) -> Bool {
        switch state {
        case .idle:
            return false
        case .activating:
            if stroke.keyCode == KeyStroke.escape { cancel() }
            return true
        case .active:
            return handleActiveKey(stroke)
        }
    }

    private func handleActiveKey(_ stroke: KeyStroke) -> Bool {
        switch stroke.keyCode {
        case KeyStroke.escape:
            cancel()
            return true

        case KeyStroke.returnKey, KeyStroke.enterKey:
            if let first = results.first { select(first) }
            return true

        case KeyStroke.delete:
            guard !query.isEmpty else { return true }
            if stroke.hasCommand {
                query = ""
            } else if stroke.hasOption {
                deleteLastWord()
            } else {
                query.removeLast()
            }
            refresh()
            return true

        default:
            guard let character = stroke.characters.first, stroke.characters.count == 1 else {
                return true
            }

            // Digits 1–9 select the corresponding result.
            if let digit = character.wholeNumberValue, digit >= 1, digit <= 9 {
                let index = digit - 1
                if index < results.count { select(results[index]) }
                return true
            }

            // Any other printable character extends the query.
            if character.isLetter || character.isNumber || character.isPunctuation || character == " " {
                query += character.lowercased()
                refresh()
            }
            return true
        }
    }

    /// Drop the trailing run of whitespace, then the trailing word (Option+Delete).
    private func deleteLastWord() {
        while let last = query.last, last == " " { query.removeLast() }
        while let last = query.last, last != " " { query.removeLast() }
    }

    // MARK: - Lifecycle

    private func refresh() {
        results = Array(WindowSwitcher.filter(allEntries, query: query).prefix(maxResults))
        overlay.show(query: query, results: results)
    }

    private func select(_ entry: WindowEntry) {
        reset()
        // Tear the overlay down before focusing so the Space switch isn't fighting our panel.
        DispatchQueue.main.async {
            WindowSwitcher.focus(entry)
        }
    }

    private func cancel() {
        reset()
    }

    private func reset() {
        overlay.hide()
        allEntries = []
        results = []
        query = ""
        state = .idle
    }
}

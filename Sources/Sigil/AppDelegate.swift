import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = InputCoordinator()
    private let activator = AccessibilityActivator()
    private var statusItem: NSStatusItem?
    /// Lets the user leave the (sticky) Visual mode from the menu; enabled only while engaged.
    private var exitVisualItem: NSMenuItem?
    /// Shows the live Visual-mode query inside the dropdown (kept out of the menu-bar item so the
    /// bar item never grows wide enough for macOS to hide it next to the notch).
    private var visualQueryItem: NSMenuItem?
    /// Shows the current match count (and a "keep typing…" prompt) beneath the query.
    private var visualMatchesItem: NSMenuItem?
    private var permissionTimer: Timer?

    // Menu-bar presentation state.
    private var isRunning = true
    private var visualActive = false
    private var visualQuery = ""
    private var visualMatchCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        coordinator.onVisualModeActiveChange = { [weak self] active in
            guard let self else { return }
            self.visualActive = active
            if !active { self.visualQuery = "" }
            self.exitVisualItem?.isEnabled = active
            self.refreshStatusPresentation()
            self.refreshQueryMenuItem()
        }
        coordinator.onVisualQueryChange = { [weak self] query in
            guard let self else { return }
            self.visualQuery = query
            self.refreshStatusPresentation()
            self.refreshQueryMenuItem()
        }
        coordinator.onVisualMatchesChange = { [weak self] count in
            guard let self else { return }
            self.visualMatchCount = count
            self.refreshQueryMenuItem()
        }

        // Trigger the Accessibility prompt on first launch.
        Permissions.ensureTrusted(prompt: true)
        attemptStart()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
        activator.stop()
    }

    // MARK: - Startup / permission gating

    private func attemptStart() {
        Log.write("attemptStart: AXIsProcessTrusted=\(Permissions.isTrusted)")
        if coordinator.start() {
            Log.write("coordinator.start succeeded — event tap active")
            permissionTimer?.invalidate()
            permissionTimer = nil
            // Now that we're trusted, proactively wake up Chromium/Electron accessibility.
            activator.start()
            updateStatusUI(running: true)
            return
        }

        Log.write("coordinator.start FAILED — CGEventTap not created (process not trusted?)")
        updateStatusUI(running: false)
        // Poll until the user grants Accessibility access, then start without a relaunch.
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard Permissions.isTrusted else { return }
            self?.attemptStart()
        }
    }

    // MARK: - Status bar UI

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⌘"
        item.button?.toolTip = "Sigil — press Control + Space to show hints"

        let menu = NSMenu()
        let status = NSMenuItem(title: "Sigil", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let queryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        queryItem.isEnabled = false
        queryItem.isHidden = true
        menu.addItem(queryItem)
        visualQueryItem = queryItem
        let matchesItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        matchesItem.isEnabled = false
        matchesItem.isHidden = true
        menu.addItem(matchesItem)
        visualMatchesItem = matchesItem
        let exitVisual = NSMenuItem(
            title: "Exit Visual Mode",
            action: #selector(exitVisualMode),
            keyEquivalent: ""
        )
        exitVisual.isEnabled = false
        menu.addItem(exitVisual)
        exitVisualItem = exitVisual
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Open Accessibility Settings…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Sigil", action: #selector(quit), keyEquivalent: "q"))

        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        // Keep "Exit Visual Mode" disabled until the mode is actually engaged, regardless of the
        // menu's automatic enabling.
        menu.autoenablesItems = false

        item.menu = menu
        statusItem = item
        refreshStatusPresentation()
    }

    private func updateStatusUI(running: Bool) {
        isRunning = running
        if let status = statusItem?.menu?.items.first {
            status.title = running
                ? "Sigil — active (Ctrl + Space)"
                : "Sigil — needs Accessibility access"
        }
        refreshStatusPresentation()
    }

    /// Render the menu-bar item. Idle/hint use the adaptive "⌘" title; while Visual mode is engaged
    /// we draw a *fixed-size* "⌘" with a small eye badged on it — the eye's mere presence signals
    /// the mode is on. The live query is shown in the dropdown menu (see `refreshQueryMenuItem`),
    /// not here — drawing it inline grew the item wide enough for macOS to hide it beside the notch.
    private func refreshStatusPresentation() {
        guard let button = statusItem?.button else { return }
        if visualActive {
            button.title = ""
            // A filled eye signals an in-progress query; the outline eye is the idle "watching" state.
            button.image = makeVisualIndicatorImage(filled: !visualQuery.isEmpty)
            button.toolTip = visualQuery.isEmpty
                ? "Sigil — Visual mode (type an element's text)"
                : "Sigil — Visual mode: \(visualQuery)"
        } else {
            button.image = nil
            button.title = isRunning ? "⌘" : "⌘⚠︎"
            button.toolTip = "Sigil — press Control + Space to show hints"
        }
    }

    /// Update the dropdown's query + match-count lines: visible only while Visual mode is engaged.
    private func refreshQueryMenuItem() {
        if let item = visualQueryItem {
            item.isHidden = !visualActive
            item.title = visualQuery.isEmpty ? "Query: (type an element's text)" : "Query: \(visualQuery)"
        }
        if let item = visualMatchesItem {
            // Only meaningful once something is typed.
            item.isHidden = !visualActive || visualQuery.isEmpty
            item.title = matchesSummary(count: visualMatchCount)
        }
    }

    private func matchesSummary(count: Int) -> String {
        switch count {
        case 0: return "No matches"
        case 1: return "1 match — press ↵ to go"
        case 2: return "2 matches — press 1 or 2, or keep typing"
        default: return "\(count) matches — keep typing…"
        }
    }

    /// A fixed-width "⌘" with a small eye badged on its top-right corner — the "watching" indicator
    /// for Visual mode. Rendered as a *template* image so the menu bar tints it for light/dark and
    /// the highlighted (menu-open) state automatically; there is no fixed colour.
    private func makeVisualIndicatorImage(filled: Bool) -> NSImage {
        let font = statusItem?.button?.font ?? NSFont.menuBarFont(ofSize: 0)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]

        let glyph = NSAttributedString(string: "⌘", attributes: attrs)
        let glyphSize = glyph.size()

        let eye = eyeBadgeImage(pointSize: 6, filled: filled)
        let eyeSize = eye?.size ?? .zero
        let overhang: CGFloat = 2
        let size = NSSize(
            width: ceil(glyphSize.width + eyeSize.width * 0.5) + overhang,
            height: ceil(glyphSize.height) + overhang
        )

        let image = NSImage(size: size)
        image.lockFocus()
        glyph.draw(at: .zero)
        if let eye {
            // Badge the eye on the glyph's top-right corner (~half of it overhanging).
            let origin = CGPoint(
                x: glyphSize.width - eyeSize.width * 0.5,
                y: glyphSize.height - eyeSize.height * 0.6
            )
            eye.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// An `eye` (outline) or `eye.fill` SF Symbol at the given point size. Returned as-is (a
    /// template symbol), so its alpha composites into the indicator and the menu bar handles the
    /// final colour. Filled signals an in-progress query; outline is the idle "watching" state.
    private func eyeBadgeImage(pointSize: CGFloat, filled: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        return NSImage(systemSymbolName: filled ? "eye.fill" : "eye", accessibilityDescription: "Visual mode active")?
            .withSymbolConfiguration(config)
    }

    @objc private func exitVisualMode() {
        coordinator.exitVisualMode()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

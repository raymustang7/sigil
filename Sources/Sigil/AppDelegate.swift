import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = InputCoordinator()
    private let activator = AccessibilityActivator()
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

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

        item.menu = menu
        statusItem = item
    }

    private func updateStatusUI(running: Bool) {
        statusItem?.button?.title = running ? "⌘" : "⌘⚠︎"
        if let status = statusItem?.menu?.items.first {
            status.title = running
                ? "Sigil — active (Ctrl + Space)"
                : "Sigil — needs Accessibility access"
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

import AppKit
import ApplicationServices

/// Chromium-based apps (Chrome, Edge, Brave) and Electron apps (VS Code, Slack, Discord,
/// Cursor) keep their web/renderer accessibility tree **disabled** by default for performance.
/// They build it only when an assistive technology asks, via the `AXManualAccessibility`
/// attribute — and crucially the tree is constructed **asynchronously**. Enabling it in the
/// same run-loop tick as a scan therefore yields an empty tree and no hints.
///
/// This watcher flips the flag *ahead of time*: for every regular app at launch, and again
/// whenever an app launches or activates, so the tree is ready by the time the user invokes
/// hints on any visible window. We track PIDs to avoid redundant writes.
///
/// `AXManualAccessibility` is preferred over `AXEnhancedUserInterface` because the latter can
/// cause some apps to resize their windows; the former is the dedicated Chromium opt-in and is
/// a no-op for apps that don't recognise it.
final class AccessibilityActivator {
    private var enabledPIDs = Set<pid_t>()
    private var observer: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?

    func start() {
        // Hints cover every visible window across apps, so each app's web/renderer tree must be
        // built ahead of time — not just the frontmost one. Wake all regular apps at launch, and
        // newly launched ones below, so their trees are ready when the user invokes hints.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            enable(for: app)
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.enable(for: app)
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.enable(for: app)
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        }
        observer = nil
        launchObserver = nil
    }

    private func enable(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, !enabledPIDs.contains(pid) else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AX.setBool(appElement, "AXManualAccessibility", true)
        enabledPIDs.insert(pid)
    }
}

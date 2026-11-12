import AppKit
import ApplicationServices

/// A target the user can jump to: either a specific window (current Space, with a real title)
/// or a whole app (when its windows live on other Spaces, where titles aren't available).
struct WindowEntry {
    let appName: String
    let title: String
    let pid: pid_t
    /// The specific window to raise, or nil for an app-level entry (just activate the app).
    let window: AXUIElement?
    let isMinimized: Bool

    /// What to show as the primary label — the window title, or the app name when untitled.
    var displayTitle: String { title.isEmpty ? appName : title }
}

/// Enumerates, filters, and focuses jump targets by name.
///
/// The Accessibility API only exposes windows on the *current* Space, so those are listed
/// individually with their titles. Windows on other Spaces can't be titled without Screen
/// Recording permission, so each such app is collapsed into a single app-name entry.
enum WindowSwitcher {
    static func allWindows() -> [WindowEntry] {
        var entries: [WindowEntry] = []
        var pidsWithCurrentSpaceWindow = Set<pid_t>()

        let regularApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier > 0
        }

        for app in regularApps {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.5)
            let appName = app.localizedName ?? ""

            for window in AX.windows(appElement) {
                let title = AX.string(window, kAXTitleAttribute as String) ?? ""
                let minimized = AX.bool(window, kAXMinimizedAttribute as String) ?? false
                // An untitled, minimized window has no identity the user could search for.
                if title.isEmpty && minimized { continue }
                entries.append(WindowEntry(
                    appName: appName,
                    title: title,
                    pid: pid,
                    window: window,
                    isMinimized: minimized
                ))
                pidsWithCurrentSpaceWindow.insert(pid)
            }
        }

        // Apps with real windows somewhere but nothing shown on the current Space get a single
        // app-name entry so the user can still jump to them.
        let pidsWithWindows = pidsWithRealWindows()
        for app in regularApps {
            let pid = app.processIdentifier
            guard !pidsWithCurrentSpaceWindow.contains(pid),
                  pidsWithWindows.contains(pid) else { continue }
            entries.append(WindowEntry(
                appName: app.localizedName ?? "",
                title: "",
                pid: pid,
                window: nil,
                isMinimized: false
            ))
        }
        return entries
    }

    /// PIDs of processes that own at least one normal on-screen-or-offscreen window, across all
    /// Spaces. Owner PID and layer are available without Screen Recording permission.
    private static func pidsWithRealWindows() -> Set<pid_t> {
        var pids = Set<pid_t>()
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return pids
        }
        for info in infoList {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            pids.insert(pid)
        }
        return pids
    }

    /// Substring filter, case-insensitive. Window-title matches rank above app-name-only
    /// matches. An empty query returns everything unchanged.
    static func filter(_ entries: [WindowEntry], query: String) -> [WindowEntry] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return entries }

        var titleMatches: [WindowEntry] = []
        var appMatches: [WindowEntry] = []
        for entry in entries {
            if entry.title.lowercased().contains(needle) {
                titleMatches.append(entry)
            } else if entry.appName.lowercased().contains(needle) {
                appMatches.append(entry)
            }
        }
        return titleMatches + appMatches
    }

    /// Brings a target to the foreground: activates its app, then raises the specific window
    /// when one is known. Switches Spaces and un-minimizes as needed.
    static func focus(_ entry: WindowEntry) {
        if let window = entry.window, entry.isMinimized {
            AX.setBool(window, kAXMinimizedAttribute as String, false)
        }
        if let app = NSRunningApplication(processIdentifier: entry.pid) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        if let window = entry.window {
            AX.perform(window, kAXRaiseAction as String)
            AX.setBool(window, kAXMainAttribute as String, true)
        }
        Log.write("switcher: focus \(entry.appName)")
    }
}

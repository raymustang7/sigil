import Cocoa
import ApplicationServices

/// Snapshot and restore of the Claude desktop app (Electron). Reads the current page URL from
/// the Accessibility tree (AXWebArea.AXURL) and restores via the app's `claude://` deep links.
enum ClaudeWorkspace {
    static let bundleID = "com.anthropic.claudefordesktop"

    struct LiveWindow {
        var element: AXUIElement
        var bounds: ScreenRect
        var url: String?
        var title: String?
        var minimized: Bool
    }

    static func runningApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static func liveWindows() -> [LiveWindow] {
        guard let app = runningApp() else { return [] }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        // Electron only builds a full accessibility tree when asked.
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        var windowsRef: AnyObject?
        AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &windowsRef)
        let windows = windowsRef as? [AXUIElement] ?? []
        var out: [LiveWindow] = []
        for w in windows {
            guard let bounds = bounds(of: w) else { continue }
            // Skip tiny/utility windows.
            if bounds.w < 200 || bounds.h < 200 { continue }
            let title = attr(w, kAXTitleAttribute) as? String
            // The window holds several web areas: the Electron shell (file://...) and the actual
            // claude.ai page. Collect them all and keep the first https one.
            var areas: [(depth: Int, url: String?)] = []
            var budget = 20000
            collectWebAreas(w, 0, &areas, &budget)
            var url = areas.first { $0.url?.hasPrefix("https://") == true }?.url
            if url == nil, let doc = attr(w, kAXDocumentAttribute) as? String { url = doc }
            out.append(LiveWindow(element: w, bounds: bounds, url: url, title: title, minimized: WindowAX.isMinimized(w)))
        }
        return out
    }

    /// Visible (non-minimized) Claude windows on `display`.
    static func snapshot(display: WorkspaceDisplay, displays: [WorkspaceDisplay]) -> [ClaudeWindowState] {
        liveWindows()
            .filter { !$0.minimized && WorkspaceDisplays.display(containing: $0.bounds, in: displays)?.key == display.key }
            .map { ClaudeWindowState(bounds: $0.bounds, url: $0.url, title: $0.title) }
    }

    /// Restore saved Claude windows on `display`. For each saved window, an existing Claude window
    /// on that display is un-minimized, placed, raised and navigated via deep link to the saved
    /// page. Claude windows on the display beyond the snapshot are minimized.
    static func restore(_ saved: [ClaudeWindowState], on display: WorkspaceDisplay, displays: [WorkspaceDisplay]) {
        if saved.isEmpty {
            for w in liveWindows() where !w.minimized && WorkspaceDisplays.display(containing: w.bounds, in: displays)?.key == display.key {
                WindowAX.setMinimized(w.element, true)
            }
            return
        }
        if runningApp() == nil {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: cfg)
                WindowAX.waitForWindows(bundleID: bundleID, timeout: 8)
            }
        }
        // Visible windows on this display first, then minimized ones, then anything else.
        let live = liveWindows().sorted { a, b in
            func score(_ w: LiveWindow) -> Int {
                (WorkspaceDisplays.display(containing: w.bounds, in: displays)?.key == display.key ? 2 : 0) + (w.minimized ? 0 : 1)
            }
            return score(a) > score(b)
        }

        for (i, state) in saved.enumerated() {
            guard i < live.count else { break }
            let w = live[i]
            WindowAX.setMinimized(w.element, false)
            setBounds(w.element, state.bounds)
            AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
            guard let url = state.url, let deep = deepLink(for: url), w.url != url else { continue }
            Thread.sleep(forTimeInterval: 0.15)
            // Deep links navigate the frontmost Claude window; give it a beat before the next one.
            NSWorkspace.shared.open(deep)
            if i < saved.count - 1 { Thread.sleep(forTimeInterval: 0.5) }
        }
        for w in live.dropFirst(saved.count) where !w.minimized && WorkspaceDisplays.display(containing: w.bounds, in: displays)?.key == display.key {
            WindowAX.setMinimized(w.element, true)
        }
    }

    /// https://claude.ai/chat/<id>  ->  claude://claude.ai/chat/<id>
    static func deepLink(for pageURL: String) -> URL? {
        guard var comps = URLComponents(string: pageURL) else { return nil }
        if comps.scheme == "claude" { return comps.url }
        guard let host = comps.host, host.hasSuffix("claude.ai") || host.hasSuffix("claude.com") else { return nil }
        comps.scheme = "claude"
        return comps.url
    }

    // MARK: - AX helpers

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(e, name as CFString, &v)
        return v
    }

    private static func bounds(of w: AXUIElement) -> ScreenRect? {
        guard let posVal = attr(w, kAXPositionAttribute), let sizeVal = attr(w, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return ScreenRect(x: Int(pos.x), y: Int(pos.y), w: Int(size.width), h: Int(size.height))
    }

    private static func setBounds(_ w: AXUIElement, _ r: ScreenRect) {
        var pos = CGPoint(x: r.x, y: r.y)
        var size = CGSize(width: r.w, height: r.h)
        if let pv = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
        if let sv = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv) }
    }

    private static func collectWebAreas(_ e: AXUIElement, _ depth: Int, _ out: inout [(depth: Int, url: String?)], _ budget: inout Int) {
        budget -= 1
        if budget <= 0 || depth > 60 { return }
        if (attr(e, kAXRoleAttribute) as? String) == "AXWebArea" {
            let raw = attr(e, kAXURLAttribute)
            let url = (raw as? URL)?.absoluteString ?? (raw as? String)
            out.append((depth, url))
        }
        guard let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for k in kids { collectWebAreas(k, depth + 1, &out, &budget) }
    }
}

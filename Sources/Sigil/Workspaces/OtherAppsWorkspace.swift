import Cocoa
import ApplicationServices

struct AppWindowState: Codable {
    var bundleID: String
    var appName: String
    var bounds: ScreenRect
    var title: String?
}

/// Generic window-layout snapshot/restore for every app we have no deeper adapter for.
/// Captures which apps have windows on a display, where, and in what z-order; restores by
/// launching the app if needed, moving its windows back, and re-raising them in order.
enum OtherAppsWorkspace {
    /// Apps handled by dedicated adapters, plus ourselves.
    static let excluded: Set<String> = [ChromeWorkspace.bundleID, ClaudeWorkspace.bundleID, Bundle.main.bundleIdentifier ?? "com.rishierish.sigil"]

    /// Windows on `display` from apps without a dedicated adapter, front-most first.
    static func snapshot(display: WorkspaceDisplay, displays: [WorkspaceDisplay]) -> [AppWindowState] {
        allWindows(display: display, displays: displays).filter { !excluded.contains($0.bundleID) }
    }

    /// Every visible (non-minimized, non-hidden) window on `display` from any regular app,
    /// front-most first. This is the display's visibility stack.
    static func allWindows(display: WorkspaceDisplay, displays: [WorkspaceDisplay]) -> [AppWindowState] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = Bundle.main.bundleIdentifier
        var out: [AppWindowState] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"],
                  w >= 100, h >= 100,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  let bid = app.bundleIdentifier, bid != me
            else { continue }
            let rect = ScreenRect(x: Int(x), y: Int(y), w: Int(w), h: Int(h))
            guard WorkspaceDisplays.display(containing: rect, in: displays)?.key == display.key else { continue }
            out.append(AppWindowState(bundleID: bid, appName: app.localizedName ?? bid, bounds: rect,
                                      title: info[kCGWindowName as String] as? String))
        }
        return out
    }

    static func restore(_ saved: [AppWindowState], on display: WorkspaceDisplay, displays: [WorkspaceDisplay]) {
        // Launch anything missing first so windows have time to appear.
        let needed = Set(saved.map(\.bundleID))
        var launched: [String] = []
        for bid in needed where NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: cfg)
                launched.append(bid)
            }
        }
        for bid in launched { WindowAX.waitForWindows(bundleID: bid, timeout: 6) }

        func onThisDisplay(_ w: AXUIElement) -> Bool {
            WindowAX.bounds(of: w).flatMap { WorkspaceDisplays.display(containing: $0, in: displays)?.key } == display.key
        }

        // Per app: AX windows not yet assigned, preferring visible ones already on this display.
        var pools: [String: [AXUIElement]] = [:]
        func pool(_ bid: String) -> [AXUIElement] {
            if let p = pools[bid] { return p }
            var wins: [AXUIElement] = []
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bid) {
                for w in WindowAX.windows(of: app.processIdentifier) {
                    guard let r = WindowAX.bounds(of: w), r.w >= 100, r.h >= 100 else { continue }
                    wins.append(w)
                }
            }
            func score(_ w: AXUIElement) -> Int {
                (onThisDisplay(w) ? 2 : 0) + (WindowAX.isMinimized(w) ? 0 : 1)
            }
            wins.sort { score($0) > score($1) }
            pools[bid] = wins
            return wins
        }

        // Back to front, so the saved front-most window ends up on top.
        var frontApp: NSRunningApplication?
        var used = Set<AXUIElement>()
        for state in saved.reversed() {
            var wins = pool(state.bundleID)
            guard !wins.isEmpty else { continue }
            let w = wins.removeFirst()
            pools[state.bundleID] = wins
            used.insert(w)
            WindowAX.setMinimized(w, false)
            WindowAX.setBounds(w, state.bounds)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            frontApp = NSRunningApplication.runningApplications(withBundleIdentifier: state.bundleID).first
        }

        // Everything else visible on this display that the snapshot doesn't include gets minimized.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier, !excluded.contains(bid) else { continue }
            for w in WindowAX.windows(of: app.processIdentifier) where !used.contains(w) {
                guard let r = WindowAX.bounds(of: w), r.w >= 100, r.h >= 100, onThisDisplay(w), !WindowAX.isMinimized(w) else { continue }
                WindowAX.setMinimized(w, true)
            }
        }
        frontApp?.activate()
    }

    /// Re-raise windows so the display's stack matches `stack` (front-most first), across all apps.
    /// Each saved window is matched to the live window of the same app whose bounds are closest.
    static func applyStack(_ stack: [AppWindowState], displays: [WorkspaceDisplay]) {
        var frontApp: NSRunningApplication?
        var used = Set<AXUIElement>()
        for state in stack.reversed() {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: state.bundleID).first else { continue }
            app.unhide()
            var best: (AXUIElement, Int)?
            for w in WindowAX.windows(of: app.processIdentifier) where !used.contains(w) && !WindowAX.isMinimized(w) {
                guard let r = WindowAX.bounds(of: w) else { continue }
                let d = abs(r.x - state.bounds.x) + abs(r.y - state.bounds.y) + abs(r.w - state.bounds.w) + abs(r.h - state.bounds.h)
                if best == nil || d < best!.1 { best = (w, d) }
            }
            guard let (w, _) = best else { continue }
            used.insert(w)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            frontApp = app
        }
        frontApp?.activate()
    }
}

enum WindowAX {
    static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(e, name as CFString, &v)
        return v
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        let ax = AXUIElementCreateApplication(pid)
        var ref: AnyObject?
        AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &ref)
        return (ref as? [AXUIElement]) ?? []
    }

    /// Poll until the app has at least one sizeable window (or the timeout passes).
    static func waitForWindows(bundleID: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let has = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { app in
                windows(of: app.processIdentifier).contains { w in
                    if let r = bounds(of: w) { return r.w >= 100 && r.h >= 100 }
                    return false
                }
            }
            if has { Thread.sleep(forTimeInterval: 0.2); return }  // brief settle for content to lay out
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    static func isMinimized(_ w: AXUIElement) -> Bool {
        (attr(w, kAXMinimizedAttribute) as? Bool) ?? false
    }

    static func setMinimized(_ w: AXUIElement, _ value: Bool) {
        guard isMinimized(w) != value else { return }
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    static func bounds(of w: AXUIElement) -> ScreenRect? {
        guard let posVal = attr(w, kAXPositionAttribute), let sizeVal = attr(w, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return ScreenRect(x: Int(pos.x), y: Int(pos.y), w: Int(size.width), h: Int(size.height))
    }

    static func setBounds(_ w: AXUIElement, _ r: ScreenRect) {
        var pos = CGPoint(x: r.x, y: r.y)
        var size = CGSize(width: r.w, height: r.h)
        if let pv = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
        if let sv = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv) }
        // Some apps clamp position until size is set; apply position again.
        if let pv = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
    }
}

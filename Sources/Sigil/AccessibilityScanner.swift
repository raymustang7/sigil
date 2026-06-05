import AppKit
import ApplicationServices
import CoreGraphics

/// A single actionable UI element discovered on screen.
struct ScannedElement {
    let element: AXUIElement
    /// Bounds in Accessibility (top-left origin) global coordinates.
    let frame: CGRect
    let role: String
    /// Web content often reports `AXPress` success without dispatching a DOM click. For elements
    /// under an `AXWebArea`, prefer a coordinate click first.
    let prefersSyntheticClick: Bool
}

/// Walks the Accessibility tree of the frontmost application and collects elements a user
/// would plausibly want to click, focus, or activate.
final class AccessibilityScanner {
    /// Roles we always treat as actionable targets.
    private let actionableRoles: Set<String> = [
        kAXButtonRole as String,
        "AXLink",
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXPopUpButtonRole as String,
        kAXMenuButtonRole as String,
        kAXMenuItemRole as String,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
        kAXSliderRole as String,
        kAXDisclosureTriangleRole as String,
        kAXIncrementorRole as String,
        "AXStepper",
        "AXSegmentedControl",
        "AXColorWell",
        kAXRowRole as String,
        kAXTabGroupRole as String,
        "AXMenuBarItem",
        "AXDockItem",
    ]

    /// Container/structural roles we never label, even if they happen to support AXPress —
    /// labelling them produces giant, useless overlays. We still recurse through them.
    private let excludedRoles: Set<String> = [
        kAXGroupRole as String,
        kAXScrollAreaRole as String,
        kAXWindowRole as String,
        kAXSplitGroupRole as String,
        kAXListRole as String,
        kAXTableRole as String,
        kAXOutlineRole as String,
        kAXToolbarRole as String,
        kAXApplicationRole as String,
        kAXSplitterRole as String,
        kAXScrollBarRole as String,
        kAXSheetRole as String,
        kAXDrawerRole as String,
        "AXLayoutArea",
        "AXLayoutItem",
        kAXGrowAreaRole as String,
        kAXRulerRole as String,
        kAXUnknownRole as String,
        kAXStaticTextRole as String,
        kAXImageRole as String,
        kAXMenuBarRole as String,
    ]

    private let maxResults = 250
    private let maxVisited = 12000
    private let maxDepth = 70
    private let minSize: CGFloat = 4

    /// Scan an application's windows for actionable elements.
    ///
    /// Safe to call off the main thread: the caller captures `pid` on the main thread and this
    /// method only touches the thread-safe AXUIElement C APIs. Keeping it off-main is essential
    /// — a slow scan must never block the run loop that services the event tap.
    /// - Parameters:
    ///   - pid: process id of the target application (captured on the main thread).
    ///   - axBounds: visible screen bounds (AX coordinates) used to cull off-screen items.
    /// Roles whose children are huge, mostly-offscreen collections; we walk only visible rows.
    private let collectionRoles: Set<String> = [
        kAXTableRole as String,
        kAXOutlineRole as String,
        kAXListRole as String,
    ]

    /// Batched attribute fetch, ordered: role, position, size, enabled.
    private let scanAttributes = [
        kAXRoleAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
        kAXEnabledAttribute as String,
    ]

    /// Scan every visible window on screen — across all applications — for actionable elements,
    /// plus the frontmost app's menu bar and the Dock.
    ///
    /// Visibility comes from the window server's on-screen list (front-to-back z-order): a window
    /// is included only if some part of it is not covered by the windows in front of it. The AX
    /// tree reports occluded windows as on-screen, so it cannot determine visibility on its own.
    ///
    /// - Parameters:
    ///   - frontmostPID: process id of the frontmost app (for the menu bar), captured on main.
    ///   - axBounds: visible screen bounds (AX coordinates) used to cull off-screen items.
    func scanVisibleWindows(frontmostPID: pid_t, axBounds: CGRect) -> [ScannedElement] {
        var results: [ScannedElement] = []
        var visited = 0

        // One AX application element (and one window list) per process, reused across that
        // process's visible windows.
        var appCache: [pid_t: AXUIElement] = [:]
        var windowsCache: [pid_t: [AXUIElement]] = [:]

        func appElement(for pid: pid_t) -> AXUIElement {
            if let cached = appCache[pid] { return cached }
            let element = AXUIElementCreateApplication(pid)
            // Bound worst-case latency: a single unresponsive control can otherwise stall the
            // whole scan for seconds. Normal AX replies are well under this.
            AXUIElementSetMessagingTimeout(element, 0.4)
            // Nudge Chromium/Electron apps (Chrome, VS Code, Slack, Discord, Cursor) into
            // exposing their full web/render accessibility tree. Best-effort.
            AX.setBool(element, "AXManualAccessibility", true)
            appCache[pid] = element
            return element
        }

        for window in visibleOnScreenWindows() {
            let app = appElement(for: window.ownerPID)
            let axWindows = windowsCache[window.ownerPID] ?? AX.windows(app)
            windowsCache[window.ownerPID] = axWindows

            guard let axWindow = matchWindow(axWindows, to: window.bounds) else { continue }
            traverse(axWindow, axBounds: axBounds, depth: 0, isInsideWebArea: false,
                     visited: &visited, results: &results)
            if results.count >= maxResults { break }
        }

        // The app menu bar lives off the application element, not under any window.
        if let menuBar = axElement(appElement(for: frontmostPID), kAXMenuBarAttribute as String) {
            traverse(menuBar, axBounds: axBounds, depth: 0, isInsideWebArea: false,
                     visited: &visited, results: &results)
        }

        // The Dock is a separate app/process, so include it as an explicit scan root.
        if let dock = dockElement() {
            AXUIElementSetMessagingTimeout(dock, 0.4)
            traverse(dock, axBounds: axBounds, depth: 0, isInsideWebArea: false,
                     visited: &visited, results: &results)
        }

        return dedupe(results)
    }

    /// A normal application window currently on screen, in AX/Quartz global coordinates.
    private struct OnScreenWindow {
        let ownerPID: pid_t
        let bounds: CGRect
    }

    /// Smallest uncovered fragment (per side) that still counts a window as visible. Guards
    /// against treating the 1–2px gaps left by window shadows as "visible area".
    private let minVisibleSliver: CGFloat = 6

    /// On-screen normal windows that have any uncovered area, front-to-back. Built from the
    /// window server's list so it reflects true z-order and occlusion.
    private func visibleOnScreenWindows() -> [OnScreenWindow] {
        let selfPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var candidates: [OnScreenWindow] = []
        for info in infoList {
            // Normal app windows sit on layer 0; the menu bar, Dock, status items, and our own
            // overlay live on other layers and are handled (or excluded) separately.
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { continue }

            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
            guard alpha > 0.01 else { continue }

            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != selfPID else { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = cgRect(fromWindowBounds: boundsDict),
                  bounds.width >= 40, bounds.height >= 40 else { continue }

            candidates.append(OnScreenWindow(ownerPID: pid, bounds: bounds))
        }

        // `candidates` is front-to-back. Keep a window if part of it is not covered by the
        // windows already seen (which are in front of it), then add it to the cover set.
        var visible: [OnScreenWindow] = []
        var covers: [CGRect] = []
        for window in candidates {
            if hasUncoveredArea(window.bounds, covers: covers) {
                visible.append(window)
            }
            covers.append(window.bounds)
        }
        return visible
    }

    /// Whether `rect` has any region (larger than a shadow sliver) not covered by `covers`.
    private func hasUncoveredArea(_ rect: CGRect, covers: [CGRect]) -> Bool {
        var fragments = [rect]
        for cover in covers where cover.intersects(rect) {
            fragments = fragments.flatMap { subtract($0, cover) }
            if fragments.isEmpty { return false }
        }
        return fragments.contains { $0.width >= minVisibleSliver && $0.height >= minVisibleSliver }
    }

    /// The parts of `rect` not covered by `cover` (0–4 axis-aligned sub-rects).
    private func subtract(_ rect: CGRect, _ cover: CGRect) -> [CGRect] {
        let c = rect.intersection(cover)
        if c.isNull || c.isEmpty { return [rect] }
        var pieces: [CGRect] = []
        if c.minY > rect.minY {
            pieces.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: c.minY - rect.minY))
        }
        if c.maxY < rect.maxY {
            pieces.append(CGRect(x: rect.minX, y: c.maxY, width: rect.width, height: rect.maxY - c.maxY))
        }
        if c.minX > rect.minX {
            pieces.append(CGRect(x: rect.minX, y: c.minY, width: c.minX - rect.minX, height: c.height))
        }
        if c.maxX < rect.maxX {
            pieces.append(CGRect(x: c.maxX, y: c.minY, width: rect.maxX - c.maxX, height: c.height))
        }
        return pieces
    }

    /// Decode a `kCGWindowBounds` dictionary into a rect (global, top-left origin — same space
    /// as AX coordinates).
    private func cgRect(fromWindowBounds dict: [String: Any]) -> CGRect? {
        var rect = CGRect.zero
        return CGRectMakeWithDictionaryRepresentation(dict as CFDictionary, &rect) ? rect : nil
    }

    /// Find the AX window whose frame best matches a window-server window's bounds. Position is
    /// part of the match so multiple same-size windows of one app disambiguate correctly.
    private func matchWindow(_ axWindows: [AXUIElement], to bounds: CGRect) -> AXUIElement? {
        var best: AXUIElement?
        var bestDelta = CGFloat.greatestFiniteMagnitude
        for window in axWindows {
            guard let frame = AX.frame(window) else { continue }
            let delta = abs(frame.minX - bounds.minX) + abs(frame.minY - bounds.minY)
                + abs(frame.width - bounds.width) + abs(frame.height - bounds.height)
            if delta < bestDelta {
                bestDelta = delta
                best = window
            }
        }
        // Accept only a close match; AX/CG frames for the same window agree within a few px.
        return bestDelta <= 12 ? best : nil
    }

    /// The Dock's application element (a separate process, `com.apple.dock`).
    private func dockElement() -> AXUIElement? {
        let dockApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        guard let pid = dockApps.first?.processIdentifier else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    private func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = AX.copyValue(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func traverse(
        _ element: AXUIElement,
        axBounds: CGRect,
        depth: Int,
        isInsideWebArea: Bool,
        visited: inout Int,
        results: inout [ScannedElement]
    ) {
        if visited >= maxVisited || results.count >= maxResults || depth > maxDepth { return }
        visited += 1

        // One IPC for role + frame + enabled instead of four.
        let values = AX.multiAttributes(element, scanAttributes)
        let role = values[0] as? String ?? ""
        let frame = Self.frame(position: values[1], size: values[2])
        let enabled = (values[3] as? Bool) ?? true
        let nextIsInsideWebArea = isInsideWebArea || role == "AXWebArea"

        if let frame {
            let onScreen = frame.intersects(axBounds)
            if onScreen,
               frame.width >= minSize,
               frame.height >= minSize,
               enabled,
               !excludedRoles.contains(role),
               actionableRoles.contains(role) {
                results.append(ScannedElement(
                    element: element,
                    frame: frame,
                    role: role,
                    prefersSyntheticClick: nextIsInsideWebArea
                ))
            }

            // Prune entire off-screen subtrees: a child laid out off-screen (e.g. a scrolled-away
            // row) cannot contain anything visible.
            if !onScreen, frame.width >= 1, frame.height >= 1 {
                return
            }
        }

        for child in childrenForTraversal(element, role: role) {
            traverse(
                child,
                axBounds: axBounds,
                depth: depth + 1,
                isInsideWebArea: nextIsInsideWebArea,
                visited: &visited,
                results: &results
            )
            if results.count >= maxResults { return }
        }
    }

    /// For big collection containers, walk only the visible rows/children; otherwise all children.
    private func childrenForTraversal(_ element: AXUIElement, role: String) -> [AXUIElement] {
        if collectionRoles.contains(role) {
            if let rows = AX.copyValue(element, "AXVisibleRows") as? [AXUIElement], !rows.isEmpty {
                return rows
            }
            if let visible = AX.copyValue(element, kAXVisibleChildrenAttribute as String) as? [AXUIElement], !visible.isEmpty {
                return visible
            }
        }
        return AX.children(element)
    }

    /// Decode an AX position + size pair (each a batched attribute value) into a rect.
    private static func frame(position: AnyObject?, size: AnyObject?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    /// Drop elements whose bounds coincide (common when a control and its accessible wrapper
    /// report identical frames), keeping the first (innermost-by-scan) occurrence.
    private func dedupe(_ elements: [ScannedElement]) -> [ScannedElement] {
        var seen = Set<String>()
        var output: [ScannedElement] = []
        for element in elements {
            let f = element.frame
            let key = "\(Int(f.minX.rounded()))|\(Int(f.minY.rounded()))|\(Int(f.width.rounded()))|\(Int(f.height.rounded()))"
            if seen.insert(key).inserted {
                output.append(element)
            }
        }
        return output
    }
}

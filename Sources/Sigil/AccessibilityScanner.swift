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
    /// Human-readable accessible name (title → description → string value), whitespace-collapsed.
    /// Empty when the element exposes no usable text. Used by Visual mode to match typed text.
    let label: String
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

    /// Collection bounds. There is no result cap any more: the hint budget is applied *after*
    /// collection by `HintBudget.allocate`, so what bounds a scan is node count and time.
    private let maxVisited = 12000
    /// One window (or the menu bar / Dock) may not consume the whole node budget by itself.
    private let maxVisitedPerSource = 6000
    private let scanDeadline: TimeInterval = 1.5
    private let maxDepth = 70
    private let minSize: CGFloat = 4

    /// Per-scan collection state shared by every traversal of that scan.
    private struct CollectionLimits {
        let maxVisited: Int
        let maxVisitedPerSource: Int
        let deadline: DispatchTime
        var visited = 0
        var sourceVisited = 0
        /// Set once any bound trips; later sources are skipped and the log says so.
        var tripped = false

        mutating func beginSource() { sourceVisited = 0 }

        /// Whether traversal must stop. Marks `tripped` as a side effect when a bound is hit.
        mutating func exhausted() -> Bool {
            if visited >= maxVisited || sourceVisited >= maxVisitedPerSource || DispatchTime.now() >= deadline {
                tripped = true
                return true
            }
            return false
        }
    }

    private func makeLimits() -> CollectionLimits {
        CollectionLimits(
            maxVisited: maxVisited,
            maxVisitedPerSource: maxVisitedPerSource,
            deadline: .now() + scanDeadline
        )
    }

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

    /// Batched attribute fetch, ordered: role, position, size, enabled, title, description, value.
    /// Title/description/value drive Visual mode's text matching; folding them into the existing
    /// single round-trip keeps them nearly free.
    private let scanAttributes = [
        kAXRoleAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
        kAXEnabledAttribute as String,
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXValueAttribute as String,
    ]

    /// Scan every visible window on screen — across all applications — for actionable elements,
    /// plus the frontmost app's menu bar and the Dock, and keep at most `budget` of them.
    ///
    /// Visibility comes from the window server's on-screen list (front-to-back z-order): a window
    /// is included only if some part of it is not covered by the windows in front of it. The AX
    /// tree reports occluded windows as on-screen, so it cannot determine visibility on its own.
    ///
    /// Candidates are collected per window first, then the budget is shared across windows by
    /// `HintBudget.allocate` (equal share, leftovers passed on), so a busy front window can no
    /// longer starve the ones behind it. The menu bar and Dock are small and always wanted, so
    /// their items come off the top. Inside a trimmed window, native controls are kept before
    /// web-page content.
    ///
    /// - Parameters:
    ///   - frontmostPID: process id of the frontmost app (for the menu bar), captured on main.
    ///   - axBounds: visible screen bounds (AX coordinates) used to cull off-screen items.
    ///   - budget: maximum number of elements to return (the user's hint budget).
    func scanVisibleWindows(frontmostPID: pid_t, axBounds: CGRect, budget: Int) -> [ScannedElement] {
        let start = DispatchTime.now()
        var limits = makeLimits()

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

        // 1. Collect candidates per source.
        let windows = visibleOnScreenWindows()
        var perWindow: [[ScannedElement]] = []
        var windowsReached = 0
        for window in windows {
            if limits.exhausted() { break }
            let app = appElement(for: window.ownerPID)
            let axWindows = windowsCache[window.ownerPID] ?? AX.windows(app)
            windowsCache[window.ownerPID] = axWindows
            guard let axWindow = matchWindow(axWindows, to: window.bounds) else { continue }

            var candidates: [ScannedElement] = []
            limits.beginSource()
            traverse(axWindow, axBounds: axBounds, depth: 0, isInsideWebArea: false,
                     limits: &limits, results: &candidates)
            perWindow.append(candidates)
            windowsReached += 1
        }

        // The app menu bar lives off the application element, not under any window.
        var menuBarItems: [ScannedElement] = []
        if !limits.exhausted(), let menuBar = axElement(appElement(for: frontmostPID), kAXMenuBarAttribute as String) {
            limits.beginSource()
            traverse(menuBar, axBounds: axBounds, depth: 0, isInsideWebArea: false,
                     limits: &limits, results: &menuBarItems)
        }

        // The Dock is a separate app/process, so include it as an explicit scan root.
        var dockItems: [ScannedElement] = []
        if !limits.exhausted(), let dock = dockElement() {
            AXUIElementSetMessagingTimeout(dock, 0.4)
            limits.beginSource()
            traverse(dock, axBounds: axBounds, depth: 0, isInsideWebArea: false,
                     limits: &limits, results: &dockItems)
        }

        // 2. Dedupe identical frames across every source, keeping the first occurrence.
        var groups = dedupe(groups: perWindow + [menuBarItems, dockItems])
        let dock = groups.removeLast()
        let menuBar = groups.removeLast()

        // 3. Native controls before web content inside each window.
        let ordered = groups.map { Self.nativeFirst($0) }

        // 4. Menu bar and Dock off the top; equal share with leftovers across windows.
        let fixed = menuBar + dock
        let reserved = min(max(budget, 0), fixed.count)
        let grants = HintBudget.allocate(demands: ordered.map(\.count), budget: max(budget, 0) - reserved)

        var output: [ScannedElement] = []
        for (candidates, grant) in zip(ordered, grants) {
            output.append(contentsOf: candidates.prefix(grant))
        }
        output.append(contentsOf: fixed.prefix(reserved))

        // 5. One line of accounting per scan.
        let candidateCount = ordered.reduce(0) { $0 + $1.count } + fixed.count
        let trimmed = zip(ordered, grants).filter { $0.count > $1 }.count
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        Log.write(String(
            format: "scan: windows=%d/%d candidates=%d hints=%d trimmed=%d budget=%d visited=%d%@ in %.0fms",
            windowsReached, windows.count, candidateCount, output.count, trimmed, budget, limits.visited,
            limits.tripped ? " limit-hit" : "", elapsedMs
        ))
        return output
    }

    /// Scan only the frontmost app's focused window (plus that app's menu bar) — the user's
    /// current context. Used by Visual mode so typed text matches what's actually in front, never
    /// elements from background apps or other/covered windows of the same app. At most `budget`
    /// elements are returned, menu bar items first.
    func scanFocusedContext(frontmostPID: pid_t, axBounds: CGRect, budget: Int) -> [ScannedElement] {
        var limits = makeLimits()

        let app = AXUIElementCreateApplication(frontmostPID)
        AXUIElementSetMessagingTimeout(app, 0.4)
        AX.setBool(app, "AXManualAccessibility", true)

        var windowItems: [ScannedElement] = []
        if let window = focusedWindow(app) {
            limits.beginSource()
            traverse(window, axBounds: axBounds, depth: 0, isInsideWebArea: false,
                     limits: &limits, results: &windowItems)
        }
        var menuBarItems: [ScannedElement] = []
        if !limits.exhausted(), let menuBar = axElement(app, kAXMenuBarAttribute as String) {
            limits.beginSource()
            traverse(menuBar, axBounds: axBounds, depth: 0, isInsideWebArea: false,
                     limits: &limits, results: &menuBarItems)
        }

        let groups = dedupe(groups: [windowItems, menuBarItems])
        let window = Self.nativeFirst(groups[0]), menuBar = groups[1]
        let reserved = min(max(budget, 0), menuBar.count)
        return Array(window.prefix(max(budget, 0) - reserved)) + Array(menuBar.prefix(reserved))
    }

    /// Stable partition: elements outside web areas first, then web content, each in scan order.
    private static func nativeFirst(_ elements: [ScannedElement]) -> [ScannedElement] {
        elements.filter { !$0.prefersSyntheticClick } + elements.filter { $0.prefersSyntheticClick }
    }

    /// The window the user is actually working in: focused, else main, else the first window.
    private func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        axElement(app, kAXFocusedWindowAttribute as String)
            ?? axElement(app, kAXMainWindowAttribute as String)
            ?? AX.windows(app).first
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
        limits: inout CollectionLimits,
        results: inout [ScannedElement]
    ) {
        if depth > maxDepth || limits.exhausted() { return }
        limits.visited += 1
        limits.sourceVisited += 1

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
                    prefersSyntheticClick: nextIsInsideWebArea,
                    label: Self.label(title: values[4], description: values[5], value: values[6])
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
                limits: &limits,
                results: &results
            )
            if limits.tripped { return }
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

    /// Pick the best accessible name from a batched (title, description, value) triple and
    /// normalise it: trim, and collapse runs of whitespace/newlines to single spaces. Title is
    /// preferred; description is the usual home of icon-button labels; a string value is the last
    /// resort. Non-string values (slider numbers, checkbox booleans) are ignored.
    private static func label(title: AnyObject?, description: AnyObject?, value: AnyObject?) -> String {
        for candidate in [title, description, value] {
            guard let text = candidate as? String else { continue }
            let collapsed = text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !collapsed.isEmpty { return collapsed }
        }
        return ""
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
    /// report identical frames), keeping the first occurrence across all groups in order. Runs
    /// before budget allocation so duplicates never consume budget.
    private func dedupe(groups: [[ScannedElement]]) -> [[ScannedElement]] {
        var seen = Set<String>()
        return groups.map { group in
            group.filter { element in
                let f = element.frame
                let key = "\(Int(f.minX.rounded()))|\(Int(f.minY.rounded()))|\(Int(f.width.rounded()))|\(Int(f.height.rounded()))"
                return seen.insert(key).inserted
            }
        }
    }
}

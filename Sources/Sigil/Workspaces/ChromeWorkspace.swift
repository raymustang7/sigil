import Cocoa

/// Snapshot and restore of Google Chrome windows via AppleScriptRunner.
enum ChromeWorkspace {
    static let bundleID = "com.google.Chrome"

    struct LiveWindow {
        var id: Int
        var bounds: ScreenRect
        var tabURLs: [String]
        var activeIndex: Int  // 1-based
    }

    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func liveWindows() throws -> [LiveWindow] {
        guard isRunning() else { return [] }
        // Field/record separators as AppleScript character literals (ASCII 9 / 10).
        let script = """
        tell application "Google Chrome"
            set fs to (ASCII character 9)
            set rs to (ASCII character 10)
            set out to ""
            repeat with w in windows
                if visible of w and minimized of w is false then
                    set b to bounds of w
                    set out to out & "W" & fs & (id of w) & fs & (item 1 of b) & fs & (item 2 of b) & fs & (item 3 of b) & fs & (item 4 of b) & fs & (active tab index of w) & rs
                    repeat with t in tabs of w
                        set out to out & "T" & fs & (URL of t) & rs
                    end repeat
                end if
            end repeat
            return out
        end tell
        """
        let text = try AppleScriptRunner.run(script).stringValue ?? ""
        var windows: [LiveWindow] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if parts.first == "W", parts.count >= 7,
               let id = Int(parts[1]), let x1 = Int(parts[2]), let y1 = Int(parts[3]),
               let x2 = Int(parts[4]), let y2 = Int(parts[5]), let active = Int(parts[6]) {
                windows.append(LiveWindow(id: id, bounds: ScreenRect(x: x1, y: y1, w: x2 - x1, h: y2 - y1), tabURLs: [], activeIndex: active))
            } else if parts.first == "T", parts.count >= 2, !windows.isEmpty {
                windows[windows.count - 1].tabURLs.append(parts[1])
            }
        }
        return windows
    }

    static func snapshot(display: WorkspaceDisplay, displays: [WorkspaceDisplay]) throws -> [ChromeWindowState] {
        try liveWindows()
            .filter { WorkspaceDisplays.display(containing: $0.bounds, in: displays)?.key == display.key }
            .map { w in
                let active = (w.activeIndex >= 1 && w.activeIndex <= w.tabURLs.count) ? w.tabURLs[w.activeIndex - 1] : nil
                return ChromeWindowState(bounds: w.bounds, tabURLs: w.tabURLs, activeURL: active)
            }
    }

    /// Bring the Chrome windows on `display` to `saved`. Existing windows on that display are
    /// reused in order; missing ones are created. Missing tabs are opened (never closed), then the
    /// saved active tab is selected.
    static func restore(_ saved: [ChromeWindowState], on display: WorkspaceDisplay, displays: [WorkspaceDisplay]) throws {
        guard !saved.isEmpty else { return }
        if !isRunning() {
            try AppleScriptRunner.run("tell application \"Google Chrome\" to launch")
            WindowAX.waitForWindows(bundleID: bundleID, timeout: 8)
        }
        let live = try liveWindows().filter { WorkspaceDisplays.display(containing: $0.bounds, in: displays)?.key == display.key }

        for (i, state) in saved.enumerated() {
            let windowID: Int
            if i < live.count {
                windowID = live[i].id
            } else {
                windowID = try makeWindow(bounds: state.bounds)
            }
            try syncTabs(windowID: windowID, state: state)
        }
        // Chrome windows on this display beyond the snapshot are minimized.
        for extra in live.dropFirst(saved.count) {
            try AppleScriptRunner.run("tell application \"Google Chrome\" to set minimized of window id \(extra.id) to true")
        }
    }

    private static func makeWindow(bounds: ScreenRect) throws -> Int {
        let script = """
        tell application "Google Chrome"
            set w to make new window
            set bounds of w to {\(bounds.x), \(bounds.y), \(bounds.x + bounds.w), \(bounds.y + bounds.h)}
            return id of w
        end tell
        """
        let r = try AppleScriptRunner.run(script)
        return Int(r.int32Value)
    }

    private static func syncTabs(windowID: Int, state: ChromeWindowState) throws {
        let urlList = "{" + state.tabURLs.map(AppleScriptRunner.quote).joined(separator: ", ") + "}"
        let activeURL = AppleScriptRunner.quote(state.activeURL ?? state.tabURLs.first ?? "")
        let b = state.bounds
        // Tabs are matched by exact URL. Missing ones are opened; existing tabs are never closed.
        let script = """
        tell application "Google Chrome"
            set w to window id \(windowID)
            set minimized of w to false
            set wanted to \(urlList)
            set wantedActive to \(activeURL)
            -- open missing
            repeat with u in wanted
                set found to false
                repeat with t in tabs of w
                    if (URL of t) is (u as string) then
                        set found to true
                        exit repeat
                    end if
                end repeat
                if not found then
                    make new tab at end of tabs of w with properties {URL:(u as string)}
                end if
            end repeat
            -- activate
            set n to count of tabs of w
            repeat with i from 1 to n
                if (URL of tab i of w) is wantedActive then
                    set active tab index of w to i
                    exit repeat
                end if
            end repeat
            set bounds of w to {\(b.x), \(b.y), \(b.x + b.w), \(b.y + b.h)}
        end tell
        """
        try AppleScriptRunner.run(script)
    }
}

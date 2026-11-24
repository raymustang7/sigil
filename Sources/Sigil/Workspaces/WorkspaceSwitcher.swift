import Foundation

/// Orchestrates snapshot and restore across apps for one display.
enum WorkspaceSwitcher {
    /// Serial queue for snapshot/restore work (AppleScript and AX calls are kept off the main thread).
    static let queue = DispatchQueue(label: "com.rishierish.sigil.switch", qos: .userInitiated)

    static func snapshot(name: String, display: WorkspaceDisplay, id: UUID = UUID()) throws -> Workspace {
        let displays = WorkspaceDisplays.all()
        let chrome = try ChromeWorkspace.snapshot(display: display, displays: displays)
        let claude = ClaudeWorkspace.snapshot(display: display, displays: displays)
        let others = OtherAppsWorkspace.snapshot(display: display, displays: displays)
        let stack = OtherAppsWorkspace.allWindows(display: display, displays: displays)
        return Workspace(id: id, name: name, displayKey: display.key,
                         chromeWindows: chrome, claudeWindows: claude, otherWindows: others,
                         stack: stack, savedAt: Date())
    }

    /// Re-snapshot the workspace currently active on `display` (only when the user opted in).
    static func refreshActive(on display: WorkspaceDisplay) {
        guard SigilSettings.shared.resaveWorkspaceOnLeave, let active = WorkspaceStore.shared.activeWorkspace(for: display.key) else { return }
        if let updated = try? snapshot(name: active.name, display: display, id: active.id) {
            WorkspaceStore.shared.upsert(updated)
        }
    }

    static func switchTo(_ ws: Workspace, on display: WorkspaceDisplay) throws {
        let displays = WorkspaceDisplays.all()
        refreshActive(on: display)
        // 1. Each adapter opens/places its own windows and minimizes the ones not in the snapshot.
        var chromeError: Error?
        do { try ChromeWorkspace.restore(ws.chromeWindows, on: display, displays: displays) } catch { chromeError = error }
        ClaudeWorkspace.restore(ws.claudeWindows, on: display, displays: displays)
        OtherAppsWorkspace.restore(ws.otherWindows ?? [], on: display, displays: displays)
        // 2. Rebuild the visibility stack across all apps.
        if let stack = ws.stack { OtherAppsWorkspace.applyStack(stack, displays: displays) }
        WorkspaceStore.shared.setActive(ws.id, for: display.key)
        if let chromeError { throw chromeError }
    }
}

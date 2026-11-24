import AppKit

/// Owns the "Workspaces" submenu of Sigil's menu-bar menu: per display, the saved workspaces
/// (click to switch), plus save / update / delete. The submenu is rebuilt each time it opens so
/// it always reflects the current displays and store.
///
/// Snapshots and restores talk to other apps over AppleScript and Accessibility, which can block
/// for seconds. They run on `WorkspaceSwitcher.queue`, never on the main thread: Sigil's keyboard
/// event tap lives there, and stalling it would freeze typing system-wide.
final class WorkspaceMenuController: NSObject, NSMenuDelegate {
    let menuItem = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")

    private let store: WorkspaceStore
    private let transition = WorkspaceTransition()
    /// True while a snapshot or switch is in flight; further actions are ignored until it ends.
    private var busy = false

    init(store: WorkspaceStore = .shared) {
        self.store = store
        super.init()
        let submenu = NSMenu(title: "Workspaces")
        submenu.autoenablesItems = false
        submenu.delegate = self
        menuItem.submenu = submenu
    }

    private final class Payload {
        let workspace: Workspace?
        let display: WorkspaceDisplay
        init(workspace: Workspace?, display: WorkspaceDisplay) {
            self.workspace = workspace
            self.display = display
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for display in WorkspaceDisplays.all() {
            menu.addItem(disabled(display.name))

            let active = store.activeWorkspace(for: display.key)
            let workspaces = store.workspaces(for: display.key)
            if workspaces.isEmpty {
                menu.addItem(disabled("   No workspaces yet"))
            }
            for ws in workspaces {
                let item = action("   " + ws.name, #selector(switchWorkspace(_:)), Payload(workspace: ws, display: display))
                item.state = ws.id == active?.id ? .on : .off
                item.toolTip = "\(ws.chromeWindows.count) Chrome, \(ws.claudeWindows.count) Claude, \(ws.otherWindows?.count ?? 0) other window(s). Saved \(ws.savedAt.formatted())"
                menu.addItem(item)
            }

            menu.addItem(action("   Save Current as New Workspace…", #selector(saveNew(_:)), Payload(workspace: nil, display: display)))
            if let active {
                menu.addItem(action("   Update “\(active.name)” Snapshot", #selector(updateActive(_:)), Payload(workspace: active, display: display)))
            }
            if !workspaces.isEmpty {
                let delete = NSMenuItem(title: "   Delete…", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for ws in workspaces {
                    sub.addItem(action(ws.name, #selector(deleteWorkspace(_:)), Payload(workspace: ws, display: display)))
                }
                delete.submenu = sub
                menu.addItem(delete)
            }
            menu.addItem(.separator())
        }
        // No trailing separator after the last display.
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, _ payload: Payload?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = payload
        item.isEnabled = !busy
        return item
    }

    // MARK: - Actions

    @objc private func switchWorkspace(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? Payload, let ws = p.workspace, !busy else { return }
        busy = true
        transition.show(on: p.display, title: ws.name)
        WorkspaceSwitcher.queue.async {
            var failure: Error?
            do { try WorkspaceSwitcher.switchTo(ws, on: p.display) } catch { failure = error }
            DispatchQueue.main.async {
                self.busy = false
                self.transition.dismiss()
                if let failure {
                    Log.write("workspace switch to \(ws.name) failed: \(failure)")
                    self.showAlert("Could not switch to “\(ws.name)”", "\(failure)")
                }
            }
        }
    }

    @objc private func saveNew(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? Payload, !busy else { return }
        let suggested = "Workspace \(store.workspaces(for: p.display.key).count + 1)"
        guard let name = askName(title: "Name this workspace", defaultName: suggested) else { return }
        snapshot(name: name, id: UUID(), display: p.display, failureTitle: "Could not save workspace") { ws in
            self.store.setActive(ws.id, for: p.display.key)
            if ws.claudeWindows.contains(where: { $0.url == nil }) {
                self.showAlert("Saved, but Claude's current chat could not be read",
                               "Make sure Accessibility access is granted, then use “Update Snapshot”.")
            }
        }
    }

    @objc private func updateActive(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? Payload, let ws = p.workspace, !busy else { return }
        snapshot(name: ws.name, id: ws.id, display: p.display, failureTitle: "Could not update snapshot") { _ in }
    }

    @objc private func deleteWorkspace(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? Payload, let ws = p.workspace else { return }
        store.delete(id: ws.id)
    }

    /// Snapshot `display` off the main thread, store the result, then run `then` on the main thread.
    private func snapshot(
        name: String, id: UUID, display: WorkspaceDisplay, failureTitle: String,
        then: @escaping (Workspace) -> Void
    ) {
        busy = true
        WorkspaceSwitcher.queue.async {
            let result = Result { try WorkspaceSwitcher.snapshot(name: name, display: display, id: id) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let ws):
                    self.store.upsert(ws)
                    then(ws)
                case .failure(let error):
                    Log.write("workspace snapshot failed: \(error)")
                    self.showAlert(failureTitle, "\(error)")
                }
            }
        }
    }

    // MARK: - Dialogs

    private func askName(title: String, defaultName: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

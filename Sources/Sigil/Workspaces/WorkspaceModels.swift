import Foundation

/// A rectangle in global top-left-origin screen coordinates (the convention both
/// the Accessibility API and Chrome's AppleScript `bounds` use).
struct ScreenRect: Codable, Equatable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    var centerX: Int { x + w / 2 }
    var centerY: Int { y + h / 2 }

    func contains(_ px: Int, _ py: Int) -> Bool {
        px >= x && px < x + w && py >= y && py < y + h
    }
}

struct ChromeWindowState: Codable {
    var bounds: ScreenRect
    var tabURLs: [String]
    var activeURL: String?
}

struct ClaudeWindowState: Codable {
    var bounds: ScreenRect
    var url: String?
    var title: String?
}

struct Workspace: Codable, Identifiable {
    var id: UUID
    var name: String
    var displayKey: String
    var chromeWindows: [ChromeWindowState]
    var claudeWindows: [ClaudeWindowState]
    /// Every other app's windows on this display, front-most first. Optional for older files.
    var otherWindows: [AppWindowState]?
    /// The display's full visibility stack across all apps, front-most first.
    var stack: [AppWindowState]?
    var savedAt: Date
}

struct StoreFile: Codable {
    var workspaces: [Workspace] = []
    /// displayKey -> id of the workspace currently active on that display
    var active: [String: UUID] = [:]
}

/// Saved workspaces, persisted as JSON in `~/Library/Application Support/Sigil/workspaces.json`.
/// Mutated from the main thread (menu actions) and from `WorkspaceSwitcher.queue`, so every
/// access goes through a lock.
final class WorkspaceStore {
    static let shared = WorkspaceStore(
        directory: applicationSupport.appendingPathComponent("Sigil", isDirectory: true),
        legacyFile: applicationSupport.appendingPathComponent("WorkspaceManager/workspaces.json")
    )

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private var data = StoreFile()
    private let url: URL
    private let lock = NSLock()

    /// - Parameter legacyFile: the standalone Workspace Manager app's store. If Sigil has no
    ///   store of its own yet, this one is copied in once so existing workspaces carry over.
    ///   The original is left untouched.
    init(directory: URL, legacyFile: URL? = nil) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("workspaces.json")
        if let legacyFile, !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.copyItem(at: legacyFile, to: url)
        }
        load()
    }

    private func load() {
        guard let raw = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? dec.decode(StoreFile.self, from: raw) { data = d }
    }

    /// Caller must hold `lock`.
    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let raw = try? enc.encode(data) { try? raw.write(to: url, options: .atomic) }
    }

    func workspaces(for displayKey: String) -> [Workspace] {
        lock.lock(); defer { lock.unlock() }
        return data.workspaces.filter { $0.displayKey == displayKey }.sorted { $0.name < $1.name }
    }

    func activeWorkspace(for displayKey: String) -> Workspace? {
        lock.lock(); defer { lock.unlock() }
        guard let id = data.active[displayKey] else { return nil }
        return data.workspaces.first { $0.id == id }
    }

    func upsert(_ ws: Workspace) {
        lock.lock(); defer { lock.unlock() }
        if let i = data.workspaces.firstIndex(where: { $0.id == ws.id }) {
            data.workspaces[i] = ws
        } else {
            data.workspaces.append(ws)
        }
        save()
    }

    func delete(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        data.workspaces.removeAll { $0.id == id }
        for (k, v) in data.active where v == id { data.active.removeValue(forKey: k) }
        save()
    }

    func setActive(_ id: UUID?, for displayKey: String) {
        lock.lock(); defer { lock.unlock() }
        if let id { data.active[displayKey] = id } else { data.active.removeValue(forKey: displayKey) }
        save()
    }
}

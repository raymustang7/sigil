import XCTest
@testable import Sigil

final class WorkspaceTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SigilWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func workspace(_ name: String, display: String = "d1") -> Workspace {
        Workspace(id: UUID(), name: name, displayKey: display, chromeWindows: [], claudeWindows: [],
                  otherWindows: nil, stack: nil, savedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Store

    func testStorePersistsAcrossInstances() {
        let store = WorkspaceStore(directory: dir)
        let b = workspace("B"), a = workspace("A"), other = workspace("C", display: "d2")
        [b, a, other].forEach(store.upsert)
        store.setActive(a.id, for: "d1")

        let reloaded = WorkspaceStore(directory: dir)
        XCTAssertEqual(reloaded.workspaces(for: "d1").map(\.name), ["A", "B"])
        XCTAssertEqual(reloaded.workspaces(for: "d2").map(\.name), ["C"])
        XCTAssertEqual(reloaded.activeWorkspace(for: "d1")?.id, a.id)
        XCTAssertNil(reloaded.activeWorkspace(for: "d2"))
    }

    func testUpsertReplacesById() {
        let store = WorkspaceStore(directory: dir)
        var ws = workspace("Old")
        store.upsert(ws)
        ws.name = "New"
        store.upsert(ws)
        XCTAssertEqual(store.workspaces(for: "d1").map(\.name), ["New"])
    }

    func testDeleteClearsActive() {
        let store = WorkspaceStore(directory: dir)
        let ws = workspace("A")
        store.upsert(ws)
        store.setActive(ws.id, for: "d1")
        store.delete(id: ws.id)
        XCTAssertTrue(store.workspaces(for: "d1").isEmpty)
        XCTAssertNil(WorkspaceStore(directory: dir).activeWorkspace(for: "d1"))
    }

    func testImportsLegacyStoreOnceAndLeavesItUntouched() throws {
        let legacyDir = dir.appendingPathComponent("legacy", isDirectory: true)
        let legacy = WorkspaceStore(directory: legacyDir)
        legacy.upsert(workspace("Imported"))
        let legacyFile = legacyDir.appendingPathComponent("workspaces.json")
        let sigilDir = dir.appendingPathComponent("sigil", isDirectory: true)

        let store = WorkspaceStore(directory: sigilDir, legacyFile: legacyFile)
        XCTAssertEqual(store.workspaces(for: "d1").map(\.name), ["Imported"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))

        // Once Sigil has its own store, the legacy file is never read again.
        store.delete(id: store.workspaces(for: "d1")[0].id)
        let again = WorkspaceStore(directory: sigilDir, legacyFile: legacyFile)
        XCTAssertTrue(again.workspaces(for: "d1").isEmpty)
    }

    func testMissingLegacyStoreStartsEmpty() {
        let store = WorkspaceStore(directory: dir, legacyFile: dir.appendingPathComponent("nope.json"))
        XCTAssertTrue(store.workspaces(for: "d1").isEmpty)
    }

    // MARK: - Geometry / links

    func testDisplayContainingUsesWindowCentre() {
        let left = WorkspaceDisplay(key: "L", name: "Left", frame: ScreenRect(x: 0, y: 0, w: 1000, h: 800))
        let right = WorkspaceDisplay(key: "R", name: "Right", frame: ScreenRect(x: 1000, y: 0, w: 1000, h: 800))
        let straddling = ScreenRect(x: 900, y: 100, w: 400, h: 300) // centre x = 1100
        XCTAssertEqual(WorkspaceDisplays.display(containing: straddling, in: [left, right])?.key, "R")
        // Off every display falls back to the first one.
        let offscreen = ScreenRect(x: 5000, y: 5000, w: 10, h: 10)
        XCTAssertEqual(WorkspaceDisplays.display(containing: offscreen, in: [left, right])?.key, "L")
    }

    func testClaudeDeepLink() {
        XCTAssertEqual(ClaudeWorkspace.deepLink(for: "https://claude.ai/chat/abc")?.absoluteString,
                       "claude://claude.ai/chat/abc")
        XCTAssertEqual(ClaudeWorkspace.deepLink(for: "claude://claude.ai/chat/abc")?.absoluteString,
                       "claude://claude.ai/chat/abc")
        XCTAssertNil(ClaudeWorkspace.deepLink(for: "https://example.com/chat/abc"))
        XCTAssertNil(ClaudeWorkspace.deepLink(for: "file:///Applications/Claude.app/index.html"))
    }

    func testAppleScriptQuoteEscapes() {
        XCTAssertEqual(AppleScriptRunner.quote(#"a"b\c"#), #""a\"b\\c""#)
    }

    // MARK: - Setting

    func testResaveOnLeaveDefaultsOffAndPersists() {
        let suite = "WorkspaceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(SigilSettings(defaults: defaults).resaveWorkspaceOnLeave)
        SigilSettings(defaults: defaults).resaveWorkspaceOnLeave = true
        XCTAssertTrue(SigilSettings(defaults: defaults).resaveWorkspaceOnLeave)
    }
}

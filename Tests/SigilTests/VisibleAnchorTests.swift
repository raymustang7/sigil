import XCTest
@testable import Sigil

/// Frames recorded from WhatsApp (22 Nov): its chat rows report a frame that starts 100pt
/// underneath the left sidebar, so hints anchored at the reported left edge drew in the sidebar.
final class VisibleAnchorTests: XCTestCase {
    private let row = CGRect(x: 3497.5, y: 330, width: 420, height: 69)
    private let sidebarLabel = CGRect(x: 3450, y: 349, width: 136.5, height: 28)
    private let sidebar = CGRect(x: 3440, y: 213, width: 156.5, height: 944)

    /// Replays a sequence of hit-test answers keyed by probe order, recording the probe points.
    private final class Probe {
        var answers: [(CGPoint) -> VisibleAnchor.Hit]
        var points: [CGPoint] = []
        init(_ answers: [(CGPoint) -> VisibleAnchor.Hit]) { self.answers = answers }
        func callAsFunction(_ point: CGPoint) -> VisibleAnchor.Hit {
            points.append(point)
            return answers.isEmpty ? .unavailable : answers.removeFirst()(point)
        }
    }

    func testWhatsAppRowUnderSidebarStartsWhereTheSidebarEnds() {
        let probe = Probe([{ _ in .element(self.sidebarLabel) }, { _ in .element(self.sidebar) }, { _ in .target }])
        let clipped = VisibleAnchor.visibleFrame(row, hitTest: probe.callAsFunction)
        XCTAssertEqual(clipped, CGRect(x: sidebar.maxX, y: row.minY, width: row.maxX - sidebar.maxX, height: row.height))
        XCTAssertEqual(probe.points.map(\.y), [row.midY, row.midY, row.midY])
    }

    func testUnobscuredElementIsUnchanged() {
        XCTAssertEqual(VisibleAnchor.visibleFrame(row) { _ in .target }, row)
    }

    func testHitOnADescendantCountsAsVisible() {
        let childText = CGRect(x: row.minX + 2, y: row.minY + 10, width: 100, height: 20)
        XCTAssertEqual(VisibleAnchor.visibleFrame(row) { _ in .element(childText) }, row)
    }

    func testHitOnAnEnclosingContainerCountsAsVisible() {
        // Some controls aren't hit-testable themselves, so the hit lands on their container.
        let container = row.insetBy(dx: -20, dy: -20)
        XCTAssertEqual(VisibleAnchor.visibleFrame(row) { _ in .element(container) }, row)
    }

    func testHitTestFailureLeavesFrameUnchanged() {
        XCTAssertEqual(VisibleAnchor.visibleFrame(row) { _ in .unavailable }, row)
    }

    func testFullyCoveredElementKeepsItsFrame() {
        // Never drop or invent a position: if nothing visible is found, fall back to the report.
        let cover = CGRect(x: row.minX - 10, y: row.minY, width: row.width + 5, height: row.height)
        XCTAssertEqual(VisibleAnchor.visibleFrame(row) { _ in .element(cover) }, row)
    }

    func testGivesUpAfterTheProbeLimit() {
        // Narrow occluders one after another never reveal the element within the probe limit.
        let probe = Probe((0..<10).map { _ in { p in .element(CGRect(x: p.x - 4, y: 0, width: 20, height: 2000)) } })
        XCTAssertEqual(VisibleAnchor.visibleFrame(row, hitTest: probe.callAsFunction), row)
        XCTAssertEqual(probe.points.count, VisibleAnchor.maxProbes)
    }
}

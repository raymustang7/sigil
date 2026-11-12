import AppKit
import XCTest
@testable import Sigil

/// Routing of hint boxes to displays, exercised on the recorded 3-display layout that exposed
/// the single-overlay bug: an ultrawide main display at the origin, the laptop to its right
/// (offset upward), and a small Dell to its left.
final class HintRoutingTests: XCTestCase {
    let ultrawide = ScreenInfo(
        displayID: 3,
        cocoaFrame: CGRect(x: 0, y: 0, width: 3440, height: 1440),
        axFrame: CGRect(x: 0, y: 0, width: 3440, height: 1440)
    )
    let laptop = ScreenInfo(
        displayID: 1,
        cocoaFrame: CGRect(x: 3440, y: 283, width: 1512, height: 982),
        axFrame: CGRect(x: 3440, y: 175, width: 1512, height: 982)
    )
    let dell = ScreenInfo(
        displayID: 2,
        cocoaFrame: CGRect(x: -1366, y: 168, width: 1366, height: 768),
        axFrame: CGRect(x: -1366, y: 504, width: 1366, height: 768)
    )

    lazy var geometry = Geometry(
        primaryHeight: 1440,
        unionCocoaFrame: CGRect(x: -1366, y: 0, width: 6318, height: 1440),
        axBounds: CGRect(x: -1366, y: 0, width: 6318, height: 1440),
        screens: [ultrawide, laptop, dell]
    )

    private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ label: String = "AA") -> HintBox {
        HintBox(cocoaRect: CGRect(x: x, y: y, width: w, height: h), label: label)
    }

    private func onlyKey(_ routed: [CGDirectDisplayID: [HintBox]], file: StaticString = #filePath, line: UInt = #line) -> CGDirectDisplayID? {
        XCTAssertEqual(routed.count, 1, "expected exactly one display, got \(routed.keys.sorted())", file: file, line: line)
        return routed.keys.first
    }

    func testLaptopBoxRoutesToLaptop() {
        let routed = geometry.route([box(3524, 1191, 28, 28)])
        XCTAssertEqual(onlyKey(routed), 1)
        XCTAssertEqual(routed[1]?.map(\.label), ["AA"])
    }

    func testMainDisplayBoxRoutesToMain() {
        XCTAssertEqual(onlyKey(geometry.route([box(6, 1334, 34, 34)])), 3)
    }

    func testDellBoxRoutesToDell() {
        XCTAssertEqual(onlyKey(geometry.route([box(-1000, 500, 40, 20)])), 2)
    }

    /// Menu-bar items sit flush with the top edge: cocoa maxY == screen maxY.
    func testTopEdgeItemRoutesToItsDisplay() {
        XCTAssertEqual(onlyKey(geometry.route([box(100, 1418, 60, 22)])), 3)
    }

    /// Left edge exactly on the seam between ultrawide and laptop → the display to the right.
    func testAnchorOnSeamRoutesToRightDisplay() {
        XCTAssertEqual(onlyKey(geometry.route([box(3440, 1000, 50, 20)])), 1)
    }

    /// Straddles the seam; the top-left corner decides.
    func testStraddlingBoxRoutesByTopLeft() {
        XCTAssertEqual(onlyKey(geometry.route([box(3400, 1000, 100, 20)])), 3)
    }

    /// Anchor hangs off every display; the display with the largest overlap wins.
    func testOffscreenAnchorFallsBackToLargestOverlap() {
        XCTAssertEqual(onlyKey(geometry.route([box(-1400, 200, 100, 20)])), 2)
    }

    func testBoxOverlappingNoDisplayIsDropped() {
        XCTAssertTrue(geometry.route([box(-2000, 2000, 10, 10)]).isEmpty)
    }

    func testNoScreensRoutesNothing() {
        let empty = Geometry(primaryHeight: 1440, unionCocoaFrame: .zero, axBounds: .zero, screens: [])
        XCTAssertTrue(empty.route([box(3524, 1191, 28, 28)]).isEmpty)
    }

    func testEveryOnScreenBoxLandsOnExactlyOneDisplay() {
        let boxes = [
            box(3524, 1191, 28, 28, "AA"), box(6, 1334, 34, 34, "AB"), box(-1000, 500, 40, 20, "AC"),
            box(100, 1418, 60, 22, "AD"), box(3440, 1000, 50, 20, "AE"), box(3400, 1000, 100, 20, "AF"),
            box(-1400, 200, 100, 20, "AG"),
        ]
        let routed = geometry.route(boxes)
        XCTAssertEqual(routed.values.reduce(0) { $0 + $1.count }, 7)
        XCTAssertEqual(Set(routed.values.flatMap { $0.map(\.label) }), Set(boxes.map(\.label)))
    }

    func testSnapshotHasOneEntryPerScreen() {
        let snapshot = Geometry.snapshot()
        XCTAssertEqual(snapshot.screens.count, NSScreen.screens.count)
        for screen in snapshot.screens {
            XCTAssertEqual(snapshot.cocoaGlobalRect(fromAX: screen.axFrame), screen.cocoaFrame)
        }
        XCTAssertEqual(Set(snapshot.screens.map(\.displayID)).count, snapshot.screens.count, "display IDs must be unique")
    }
}

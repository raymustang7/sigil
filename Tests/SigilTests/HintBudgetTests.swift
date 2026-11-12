import XCTest
@testable import Sigil

/// Equal share with leftovers passed on, checked against the recorded scans that exposed the
/// front-to-back starvation and against the simulated heavy loads from the design discussion.
final class HintBudgetTests: XCTestCase {
    /// Run 1 (12 Nov): Claude 38, Chrome A 204, Chrome B 32, Chrome C 92, replayed at the old cap.
    func testRun1At250() {
        XCTAssertEqual(HintBudget.allocate(demands: [38, 204, 32, 92], budget: 250), [38, 90, 32, 90])
    }

    func testCursorHypothetical() {
        XCTAssertEqual(HintBudget.allocate(demands: [900, 150, 150], budget: 800), [500, 150, 150])
    }

    func testWithinBudgetUnchanged() {
        XCTAssertEqual(HintBudget.allocate(demands: [74, 48, 32, 92], budget: 800), [74, 48, 32, 92])
    }

    func testZeroBudgetGivesZeros() {
        XCTAssertEqual(HintBudget.allocate(demands: [10, 20], budget: 0), [0, 0])
        XCTAssertEqual(HintBudget.allocate(demands: [10, 20], budget: -5), [0, 0])
    }

    /// Share rounds down to zero; the last units still go out one per window, earlier first.
    func testMoreWindowsThanBudgetHandsOutSingles() {
        let result = HintBudget.allocate(demands: Array(repeating: 5, count: 150), budget: 100)
        XCTAssertEqual(result.count, 150)
        XCTAssertEqual(result.reduce(0, +), 100)
        XCTAssertEqual(Set(result), [0, 1])
        XCTAssertEqual(Array(result.prefix(100)), Array(repeating: 1, count: 100))
    }

    func testEmptyDemands() {
        XCTAssertEqual(HintBudget.allocate(demands: [], budget: 800), [])
    }

    func testNeverExceedsDemandOrBudget() {
        let demands = [900, 60, 80, 20, 40, 150]
        let result = HintBudget.allocate(demands: demands, budget: 800)
        XCTAssertEqual(result, [450, 60, 80, 20, 40, 150])
        XCTAssertEqual(result.reduce(0, +), 800)
    }
}

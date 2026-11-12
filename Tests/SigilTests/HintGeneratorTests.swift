import XCTest
@testable import Sigil

final class HintGeneratorTests: XCTestCase {
    let letters = Array("ASDFGHJKLQWERTYUIOPZXCVBNM")

    func testAlphabetRule() {
        XCTAssertEqual(HintGenerator.alphabet(forCount: 676), letters)
        let extended = HintGenerator.alphabet(forCount: 677)
        XCTAssertEqual(extended.count, 35)
        XCTAssertEqual(Array(extended.prefix(26)), letters)
        XCTAssertEqual(String(extended.suffix(9)), "123456789")
    }

    func test676LabelsAreLetterOnlyTwoChars() {
        let labels = HintGenerator().generate(count: 676)
        XCTAssertEqual(labels.count, 676)
        XCTAssertEqual(Set(labels).count, 676)
        XCTAssertTrue(labels.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isLetter) })
    }

    func test1225LabelsUniquePrefixFreeTwoChars() {
        let labels = HintGenerator().generate(count: 1225)
        XCTAssertEqual(labels.count, 1225)
        XCTAssertEqual(Set(labels).count, 1225)
        XCTAssertTrue(labels.allSatisfy { $0.count == 2 })
        XCTAssertTrue(labels.contains { $0.contains(where: \.isNumber) })
        let set = Set(labels)
        for label in labels where set.contains(String(label.prefix(1))) {
            XCTFail("\(label) has a shorter label as prefix")
        }
    }

    func testSmallCountsUnchanged() {
        let labels = HintGenerator().generate(count: 10)
        XCTAssertEqual(labels.count, 10)
        XCTAssertTrue(labels.allSatisfy { $0.count == 1 && $0.allSatisfy(\.isLetter) })
    }

    /// Below the letter limit, digits must never appear even though the extended alphabet exists.
    func test300LabelsHaveNoDigits() {
        XCTAssertFalse(HintGenerator().generate(count: 300).contains { $0.contains(where: \.isNumber) })
    }
}

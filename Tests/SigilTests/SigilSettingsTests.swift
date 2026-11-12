import XCTest
@testable import Sigil

final class SigilSettingsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "SigilSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultIs800() {
        XCTAssertEqual(SigilSettings(defaults: defaults).hintBudget, 800)
        XCTAssertEqual(SigilSettings.defaultHintBudget, 800)
        XCTAssertEqual(SigilSettings.hintBudgetRange, 100...1225)
    }

    func testPersistsAcrossInstances() {
        SigilSettings(defaults: defaults).hintBudget = 450
        XCTAssertEqual(SigilSettings(defaults: defaults).hintBudget, 450)
        XCTAssertEqual(defaults.integer(forKey: SigilSettings.hintBudgetKey), 450)
    }

    func testClampsOutOfRange() {
        let settings = SigilSettings(defaults: defaults)
        settings.hintBudget = 50
        XCTAssertEqual(settings.hintBudget, 100)
        settings.hintBudget = 5000
        XCTAssertEqual(settings.hintBudget, 1225)
        // A corrupt stored value is clamped on read too.
        defaults.set(-3, forKey: SigilSettings.hintBudgetKey)
        XCTAssertEqual(SigilSettings(defaults: defaults).hintBudget, 100)
    }

    func testResetRestoresDefault() {
        let settings = SigilSettings(defaults: defaults)
        settings.hintBudget = 300
        settings.resetHintBudget()
        XCTAssertEqual(settings.hintBudget, 800)
        XCTAssertNil(defaults.object(forKey: SigilSettings.hintBudgetKey))
    }

    func testOnChangeFires() {
        let settings = SigilSettings(defaults: defaults)
        var fired = 0
        settings.onChange = { fired += 1 }
        settings.hintBudget = 600
        settings.hintBudget = 600   // unchanged value: no event
        settings.resetHintBudget()
        XCTAssertEqual(fired, 2)
    }
}

import XCTest
@testable import CCBar

final class UpdateCheckerTests: XCTestCase {
    // MARK: - numericComponents

    func testNumericComponentsVariantForms() {
        XCTAssertEqual(UpdateChecker.numericComponents(of: "v1.0.2"), [1, 0, 2])
        XCTAssertEqual(UpdateChecker.numericComponents(of: "1.0.2"), [1, 0, 2])
        XCTAssertEqual(UpdateChecker.numericComponents(of: "1.0"), [1, 0])
        XCTAssertEqual(UpdateChecker.numericComponents(of: "V2.3.4"), [2, 3, 4])
    }

    func testNumericComponentsSuffixTruncated() {
        XCTAssertEqual(UpdateChecker.numericComponents(of: "1.0.2-beta.1"), [1, 0, 2])
    }

    func testNumericComponentsInvalid() {
        XCTAssertNil(UpdateChecker.numericComponents(of: ""))
        XCTAssertNil(UpdateChecker.numericComponents(of: "abc"))
        XCTAssertNil(UpdateChecker.numericComponents(of: "v.1.0"))
    }

    // MARK: - isNewer

    func testNewerVersion() {
        XCTAssertTrue(UpdateChecker.isNewer(tag: "v1.0.2", than: "1.0.1"))
        XCTAssertTrue(UpdateChecker.isNewer(tag: "v1.1.0", than: "1.0.9"))
        XCTAssertTrue(UpdateChecker.isNewer(tag: "v2.0.0", than: "1.9.9"))
    }

    func testSameOrOlderVersionNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer(tag: "v1.0.1", than: "1.0.1"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: "v1.0.0", than: "1.0.1"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: "v0.9.9", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: "v1.0", than: "1.0.0"))
    }

    func testIsNewerMalformedTagTreatsAsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer(tag: "invalid", than: "1.0.1"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: "", than: "1.0.1"))
    }
}

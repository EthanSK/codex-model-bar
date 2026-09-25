import XCTest
@testable import CodexModelBarCore

final class ComposerCleanupTests: XCTestCase {
    func testUnavailableInputDoesNotClaimTheRecentDigitWasLeftInDraft() {
        XCTAssertEqual(ComposerText.cleanupState("3", before: "draft", after: nil), .unverified)
        XCTAssertEqual(ComposerText.cleanupState("3", before: "", after: nil), .unverified)
        XCTAssertEqual(ComposerText.cleanupState("3", before: "draft", after: ""), .unverified)
    }

    func testOnlyAnExactReadableInsertionCanBeReportedAsRemaining() {
        XCTAssertEqual(ComposerText.cleanupState("3", before: "draft", after: "draft3"), .remaining)
        XCTAssertEqual(ComposerText.cleanupState("3", before: "draft", after: "draft"), .restored)
        XCTAssertEqual(ComposerText.cleanupState("opus", before: "draft", after: "draftopus"), .remaining)
        XCTAssertEqual(ComposerText.cleanupState("opus", before: "draft", after: "draft opus edited"), .unverified)
    }
}

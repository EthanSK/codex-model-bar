import XCTest
@testable import CodexModelBar
import CodexModelBarCore

final class ModelSwitchResultTests: XCTestCase {
    func testConfirmedSolDoesNotBecomeFailedWhenTheDraftReadChanges() {
        let sol = CurrentSelection(modelID: "gpt-6-sol", effort: "high")
        let result = ModelSwitcher.searchResult(confirmed: sol, cleanup: .unverified, query: "gpt-6-sol")
        guard case .switched(let selection) = result else { return XCTFail("The model was confirmed: \(result)") }
        XCTAssertEqual(selection, sol)
    }

    func testUnconfirmedModelStillFailsWithoutInventingLeftoverSearch() {
        let result = ModelSwitcher.searchResult(confirmed: nil, cleanup: .unverified, query: "gpt-6-sol")
        guard case .failed(_, let searchLeft) = result else { return XCTFail("Must not claim a switch succeeded") }
        XCTAssertNil(searchLeft)
    }

    func testProvenRemainingSearchIsReportedEvenAfterModelConfirmation() {
        let result = ModelSwitcher.searchResult(confirmed: CurrentSelection(modelID: "gpt-6-sol", effort: "high"),
                                                cleanup: .remaining, query: "gpt-6-sol")
        guard case .failed(_, let searchLeft) = result else { return XCTFail("Must report the observed leftover") }
        XCTAssertEqual(searchLeft, "gpt-6-sol")
    }
}

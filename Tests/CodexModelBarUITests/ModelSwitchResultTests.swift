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

    // Replays the 2026-09-25 installed-log cases: the original input already showed the
    // requested model when a click or key press arrived during confirmation.
    private func proves(replaced: Bool = false, focused: Bool = true, userInteracted: Bool = true,
                        readOriginal: Bool = true, model: String = "claude-opus-5-5") -> Bool {
        CodexUI.provesSelection(sameContext: true, replaced: replaced, focused: focused, userInteracted: userInteracted,
                                readOriginalAfterUserInput: readOriginal,
                                selection: CurrentSelection(modelID: model, effort: "high"),
                                modelID: "claude-opus-5-5", effort: nil)
    }

    func testAnAppliedSwitchOnTheOriginalInputIsConfirmedAfterAClick() {
        XCTAssertTrue(proves())
        XCTAssertTrue(proves(focused: false), "The original input's own button is the evidence, not focus")
    }

    func testReasoningStepsStillStopOnUserInput() {
        XCTAssertFalse(proves(readOriginal: false))
        XCTAssertTrue(proves(userInteracted: false, readOriginal: false))
    }

    func testAReplacementInputStillNeedsFocusAndNoUserInput() {
        XCTAssertFalse(proves(replaced: true))
        XCTAssertFalse(proves(replaced: true, focused: false, userInteracted: false))
        XCTAssertTrue(proves(replaced: true, userInteracted: false))
    }

    func testADifferentModelIsNeverConfirmed() {
        XCTAssertFalse(proves(model: "gpt-6-sol"))
    }
}

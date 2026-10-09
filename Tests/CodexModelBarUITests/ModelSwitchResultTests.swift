import XCTest
@testable import CodexModelBar
import CodexModelBarCore

final class ModelSwitchResultTests: XCTestCase {
    // Intermediate reasoning and the combined Astra action still use composer confirmation.
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

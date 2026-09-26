import XCTest
@testable import CodexModelBar
import CodexModelBarCore

final class DropdownModelPickerTests: XCTestCase {
    private let models = [CodexModel(id: "gpt-6-sol", displayName: "GPT-6-Sol"),
                          CodexModel(id: "gpt-6-astra", displayName: "GPT-6-Astra"),
                          CodexModel(id: "claude-opus-5-5", displayName: "Opus 5.5")]

    private func choose(_ titles: [String], enabled: [Bool]? = nil) -> DropdownModelPicker.Choice? {
        DropdownModelPicker.choice(titles: titles, enabled: enabled ?? titles.map { _ in true },
                                   current: "gpt-6-sol", target: "gpt-6-astra", models: models)
    }

    func testDropdownOpensModelSubmenuInsteadOfSelectingAnEffort() {
        XCTAssertEqual(choose(["Select model", "High", "Fast"]), .openModels(0))
        XCTAssertEqual(choose(["Low", "Medium", "High", "Extra High", "GPT-6 Sol", "Speed"]), .openModels(4))
        XCTAssertEqual(choose(["Model GPT-6 Sol", "Effort High", "Speed Standard"]), .openModels(0))
        XCTAssertEqual(choose(["Model 6 Sol", "Effort High"]), .openModels(0))
    }

    func testSubmenuChoosesExactModelIncludingWorkModeLabels() {
        XCTAssertEqual(choose(["GPT-6 Astra", "GPT-6 Sol", "Opus 5.5"]), .select(0))
        XCTAssertEqual(choose(["6 Astra", "6 Sol", "Opus 5.5"]), .select(0))
    }

    func testDisabledMissingAndAmbiguousTargetsAreNotSelected() {
        XCTAssertNil(choose(["GPT-6 Astra"], enabled: [false]))
        XCTAssertNil(choose(["GPT-6 Astra", "GPT-6 Astra"]))
        XCTAssertNil(choose(["GPT-6 Astra High", "Explain GPT-6 Astra", "Astra"]))
        XCTAssertNil(choose(["Effort High", "Speed Standard", "Opus 5.5"]))
        XCTAssertNil(choose(["Model GPT-6 Sol"], enabled: [false]))
    }
}

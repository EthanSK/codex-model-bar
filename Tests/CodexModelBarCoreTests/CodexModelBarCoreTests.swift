import XCTest
@testable import CodexModelBarCore

/// The real catalogue seen on Codex desktop 26.917 (model/list), used as fixtures.
private let catalogue: [CodexModel] = [
    CodexModel(id: "gpt-6-astra", displayName: "GPT-6-Astra"),
    CodexModel(id: "gpt-6-sol", displayName: "GPT-6-Sol"),
    CodexModel(id: "gpt-6-luna", displayName: "GPT-6-Luna"),
    CodexModel(id: "gpt-5.6-sol", displayName: "GPT-5.6-Sol"),
    CodexModel(id: "gpt-5.6-terra", displayName: "GPT-5.6-Terra"),
    CodexModel(id: "gpt-5.6-luna", displayName: "GPT-5.6-Luna"),
    CodexModel(id: "gpt-5.5", displayName: "GPT-5.5"),
    CodexModel(id: "claude-opus-5-5", displayName: "Opus 5.5"),
    CodexModel(id: "claude-fable-5-1", displayName: "Fable 5.1"),
]

final class CurrentModelMatcherTests: XCTestCase {
    private func id(_ title: String) -> String? {
        CurrentModelMatcher.model(forTitle: title, among: catalogue)?.id
    }

    func testComposerButtonTitles() {
        // Composer button titles are "<UI name> <effort>".
        XCTAssertEqual(id("Opus 5.5 Extra High"), "claude-opus-5-5")
        XCTAssertEqual(id("GPT-6 Sol Medium"), "gpt-6-sol")        // UI turns GPT-6-Sol into "GPT-6 Sol"
        XCTAssertEqual(id("GPT-5.6 Sol High"), "gpt-5.6-sol")
        XCTAssertEqual(id("GPT-5.5 Low"), "gpt-5.5")
        XCTAssertEqual(id("Fable 5.1"), "claude-fable-5-1")         // title with no effort suffix
    }

    func testComposerReasoningTitles() {
        func effort(_ title: String) -> String? {
            CurrentModelMatcher.selection(forButtonTitle: title, among: catalogue).effort
        }
        XCTAssertEqual(effort("Opus 5.5 Extra High"), "xhigh")
        XCTAssertEqual(effort("GPT-6 Sol Medium"), "medium")
        XCTAssertEqual(effort("GPT-6 Astra Ultra"), "ultra")
        XCTAssertEqual(effort("GPT-6 Sol Max"), "max")
        XCTAssertNil(effort("Fable 5.1"))
        XCTAssertNil(effort("Some other button"))
        XCTAssertEqual(CurrentModelMatcher.label(forEffort: "xhigh"), "Extra High")
    }

    func testMenuItemTitles() {
        // Recent items carry a 1…3 index; search hits carry the model description.
        XCTAssertEqual(id("1 Opus 5.5 Extra High Standard"), "claude-opus-5-5")
        XCTAssertEqual(id("2 GPT-6 Sol Extra High Standard"), "gpt-6-sol")
        XCTAssertEqual(id("GPT-5.6 Sol Older coding model for complex work."), "gpt-5.6-sol")
        XCTAssertEqual(id("GPT-6 Sol Workhorse model for coding and everyday work."), "gpt-6-sol")
    }

    func testNoFalsePositives() {
        // Other popup buttons in the window must never look like the model button.
        XCTAssertNil(id("Change permissions"))
        XCTAssertNil(id("Chat actions"))
        XCTAssertNil(id("Switch mode, current mode: Codex"))
        XCTAssertNil(id(""))
        // "GPT-6 Sol" must not match a model called "GPT-6 Solar"; word boundary needed.
        let tricky = [CodexModel(id: "a", displayName: "GPT-6-Sol"), CodexModel(id: "b", displayName: "GPT-6-Solar")]
        XCTAssertEqual(CurrentModelMatcher.model(forTitle: "GPT-6 Solar High", among: tricky)?.id, "b")
        XCTAssertEqual(CurrentModelMatcher.model(forTitle: "GPT-6 Sol High", among: tricky)?.id, "a")
    }

    func testLongestNameWins() {
        let models = [CodexModel(id: "short", displayName: "GPT-6"), CodexModel(id: "long", displayName: "GPT-6-Sol")]
        XCTAssertEqual(CurrentModelMatcher.model(forTitle: "GPT-6 Sol Medium", among: models)?.id, "long")
        XCTAssertEqual(CurrentModelMatcher.model(forTitle: "GPT-6 Medium", among: models)?.id, "short")
    }
}

final class CodexModelParsingTests: XCTestCase {
    func testModelListResult() {
        let result: [String: Any] = [
            "data": [
                ["id": "gpt-6-sol", "model": "gpt-6-sol", "displayName": "GPT-6-Sol",
                 "description": "Workhorse model", "hidden": false, "isDefault": false],
                ["id": "secret", "model": "secret", "displayName": "", "hidden": true],
                ["displayName": "No slug"],   // dropped: no id/model
            ],
            "nextCursor": "abc",
        ]
        let page = CodexModelParsing.parseModelListResult(result)
        XCTAssertEqual(page.nextCursor, "abc")
        XCTAssertEqual(page.models.count, 2)
        XCTAssertEqual(page.models[0], CodexModel(id: "gpt-6-sol", displayName: "GPT-6-Sol", description: "Workhorse model"))
        XCTAssertEqual(page.models[1].displayName, "secret")   // empty name falls back to slug
        XCTAssertTrue(page.models[1].hidden)
        XCTAssertNil(CodexModelParsing.parseModelListResult(["data": [], "nextCursor": NSNull()]).nextCursor)
    }

    func testModelsCache() {
        let json = """
        {"models":[{"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list"},
                   {"slug":"gpt-reserve","display_name":"GPT-Reserve","visibility":"hide"}]}
        """
        let models = CodexModelParsing.parseModelsCache(Data(json.utf8))
        XCTAssertEqual(models.map(\.id), ["gpt-5.5", "gpt-reserve"])
        XCTAssertEqual(models.map(\.hidden), [false, true])
        XCTAssertTrue(CodexModelParsing.parseModelsCache(Data("nope".utf8)).isEmpty)
    }

    func testReasoningLevelsAndOlderCachedModels() throws {
        let result: [String: Any] = ["data": [[
            "model": "gpt-6-sol", "displayName": "GPT-6-Sol",
            "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "medium"],
                                           ["reasoningEffort": "high"]],
            "defaultReasoningEffort": "medium",
        ]]]
        let model = try XCTUnwrap(CodexModelParsing.parseModelListResult(result).models.first)
        XCTAssertEqual(model.supportedEfforts, ["low", "medium", "high"])
        XCTAssertEqual(model.defaultEffort, "medium")

        let cache = Data("""
            {"models":[{"slug":"claude-opus-5-5","display_name":"Opus 5.5",
            "supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}],
            "default_reasoning_level":"high"}]}
            """.utf8)
        XCTAssertEqual(CodexModelParsing.parseModelsCache(cache).first?.supportedEfforts, ["low", "high"])
        let old = Data("""
            [{"id":"gpt-6-sol","displayName":"GPT-6-Sol","description":"","hidden":false}]
            """.utf8)
        XCTAssertEqual(try JSONDecoder().decode([CodexModel].self, from: old).first?.supportedEfforts, [])
    }
}

final class BarPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 2056, height: 1329)
    private let visible = CGRect(x: 0, y: 70, width: 2056, height: 1226)   // Dock below, menu bar above

    func testBelowWhenThereIsRoom() {
        // Ethan's real window: CG bounds 120,212,1818×985 on a 1329pt-high display.
        let window = CoordinateConversion.cocoaRect(fromCGBounds: CGRect(x: 120, y: 212, width: 1818, height: 985),
                                                    primaryScreenHeight: screen.height)
        XCTAssertEqual(window, CGRect(x: 120, y: 132, width: 1818, height: 985))
        let result = BarPlacement.place(window: window, visibleFrame: visible, height: 30, contentWidth: 700)
        XCTAssertEqual(result.slot, .below)
        XCTAssertEqual(result.frame, CGRect(x: 679, y: 102, width: 700, height: 30))
    }

    func testAboveWhenWindowTouchesTheDock() {
        let window = CGRect(x: 100, y: 70, width: 1200, height: 900)
        let result = BarPlacement.place(window: window, visibleFrame: visible, height: 30, contentWidth: 700)
        XCTAssertEqual(result.slot, .above)
        XCTAssertEqual(result.frame, CGRect(x: 350, y: 970, width: 700, height: 30))
    }

    func testInsideTopWhenMaximised() {
        let result = BarPlacement.place(window: visible, visibleFrame: visible, height: 30, contentWidth: 700)
        XCTAssertEqual(result.slot, .insideTop)
        XCTAssertEqual(result.frame.width, 700)
        XCTAssertEqual(result.frame.midX, visible.midX)
        XCTAssertEqual(result.frame.maxY, visible.maxY - 6)
    }

    func testBarNeverWiderThanWindow() {
        let small = CGRect(x: 0, y: 70, width: 500, height: 1226)
        let result = BarPlacement.place(window: small, visibleFrame: visible, height: 30, contentWidth: 700)
        XCTAssertEqual(result.frame.width, 500)
    }

    func testBarStaysOnScreenWhenCodexWindowIsPartlyOffScreen() {
        let window = CGRect(x: -200, y: 120, width: 900, height: 800)
        let result = BarPlacement.place(window: window, visibleFrame: visible, height: 30, contentWidth: 600)
        XCTAssertEqual(result.frame.minX, visible.minX)
        XCTAssertEqual(result.frame.width, 600)
    }
}

/// The bar only deletes search letters it can prove it typed; these pin that rule.
final class ComposerTextTests: XCTestCase {
    func testPlaceholderCountsAsEmpty() {
        // Observed Accessibility value of an empty Codex message box.
        XCTAssertEqual(ComposerText.visibleText(value: "\nDo anything", placeholder: "Do anything"), "")
        XCTAssertEqual(ComposerText.visibleText(value: "fix the bug", placeholder: "Do anything"), "fix the bug")
    }

    func testOnlyAddedAtEndMiddleAndEmpty() {
        XCTAssertTrue(ComposerText.onlyAdded("gpt-6-sol", before: "", after: "gpt-6-sol"))
        XCTAssertTrue(ComposerText.onlyAdded("opus", before: "hello world", after: "hello worldopus"))
        XCTAssertTrue(ComposerText.onlyAdded("opus", before: "hello world", after: "hello opusworld"))
    }

    func testOnlyAddedRejectsAnyOtherChange() {
        // A lost keystroke: fewer letters arrived than were typed.
        XCTAssertFalse(ComposerText.onlyAdded("opus", before: "", after: "ops"))
        // The user also typed: extra letters besides the search.
        XCTAssertFalse(ComposerText.onlyAdded("sol", before: "but were", after: "but wersole x"))
        // Same length, but the user's text changed.
        XCTAssertFalse(ComposerText.onlyAdded("ab", before: "xy", after: "abxz"))
        XCTAssertFalse(ComposerText.onlyAdded("", before: "x", after: "x"))
    }
}

/// Titles of the `/model` menu entries seen on Codex desktop 26.917.
final class ModelMenuTitleTests: XCTestCase {
    let models = [
        CodexModel(id: "gpt-6-sol", displayName: "GPT-6-Sol"),
        CodexModel(id: "claude-opus-5-5", displayName: "Opus 5.5"),
        CodexModel(id: "claude-fable-5-1", displayName: "Fable 5.1"),
    ]

    func testRecentAndMatchingEntries() {
        XCTAssertEqual(CurrentModelMatcher.model(forTitle: "1 Opus 5.5 Extra High Standard", among: models)?.id, "claude-opus-5-5")
        XCTAssertEqual(CurrentModelMatcher.model(forTitle: "2 GPT-6 Sol Max Standard", among: models)?.id, "gpt-6-sol")
        XCTAssertEqual(CurrentModelMatcher.model(forTitle: "Fable 5.1 Claude Fable 5.1, running through your Claude Code CLI.", among: models)?.id, "claude-fable-5-1")
    }
}

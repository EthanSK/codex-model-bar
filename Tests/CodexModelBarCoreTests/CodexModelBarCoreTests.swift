import XCTest
@testable import CodexModelBarCore

final class StatusPlacementTests: XCTestCase {
    func testNoticeStaysRightOfTheBarWithoutMovingIt() {
        let screen = CGRect(x: -1700, y: -300, width: 1700, height: 1100)
        for bar in [CGRect(x: -1450, y: 100, width: 700, height: 30),
                    CGRect(x: -1450, y: 100, width: 180, height: 178)] {
            let notice = BarPlacement.status(beside: bar, visibleFrame: screen,
                                             contentSize: CGSize(width: 150, height: 26))
            XCTAssertEqual(notice.minX, bar.maxX + 6)
            XCTAssertEqual(notice.midY, bar.midY)
            XCTAssertFalse(notice.intersects(bar))
            XCTAssertTrue(screen.contains(notice))
        }
    }

    func testRightScreenEdgeUsesSpaceAboveOrBelowWithoutCoveringTheSlider() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        for bar in [CGRect(x: 820, y: 100, width: 180, height: 178),
                    CGRect(x: 820, y: 600, width: 180, height: 178)] {
            let notice = BarPlacement.status(beside: bar, visibleFrame: screen,
                                             contentSize: CGSize(width: 900, height: 26))
            XCTAssertEqual(notice.width, 320)
            XCTAssertEqual(notice.maxX, screen.maxX)
            XCTAssertTrue(screen.contains(notice))
            XCTAssertFalse(notice.intersects(bar))
        }
    }

    func testLimitedRightSpaceTruncatesOnlyTheNotice() {
        let notice = BarPlacement.status(beside: CGRect(x: 200, y: 200, width: 680, height: 30),
                                         visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                         contentSize: CGSize(width: 280, height: 26))
        XCTAssertEqual(notice.minX, 886)
        XCTAssertEqual(notice.width, 114)
    }

    func testNoticeAvoidsCodexAndFlowWhenBothUsualSidesAreBlocked() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let bar = CGRect(x: 10, y: 100, width: 200, height: 200)
        let codex = CGRect(x: 230, y: 0, width: 600, height: 800)
        let flow = CGRect(x: 0, y: 300, width: 220, height: 500)
        let notice = BarPlacement.status(beside: bar, visibleFrame: screen,
                                         contentSize: CGSize(width: 150, height: 26),
                                         obstructingWindows: [codex, flow])
        for obstacle in [bar, codex, flow] { XCTAssertFalse(notice.intersects(obstacle)) }
        XCTAssertTrue(screen.contains(notice))
    }
}

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
    func testCustomModelControlCanBeLocatedWithoutInventingASelection() {
        for title in ["Custom", "Custom High", "Custom Extra High"] {
            XCTAssertTrue(CurrentModelMatcher.isModelButtonTitle(title, among: catalogue))
            XCTAssertNil(CurrentModelMatcher.selection(forButtonTitle: title, among: catalogue).modelID)
            XCTAssertFalse(CurrentModelMatcher.searchResultsOnlyMatch("gpt-6-astra", titles: [title], among: catalogue))
        }
        for title in ["Custom permissions", "Custom model settings", "Customize", "Custom High Other"] {
            XCTAssertFalse(CurrentModelMatcher.isModelButtonTitle(title, among: catalogue))
        }
    }

    func testFilteredOpusRecentAndCatalogueResultsAllowReturn() {
        // Exact installed 1.2.13 failure: both sections exposed the same two choices.
        let titles = ["Opus 5.5 Extra High Standard",
                      "Opus 5.5 Claude Opus 5.5, running through your Claude Code CLI."]
        XCTAssertTrue(CurrentModelMatcher.searchResultsOnlyMatch("claude-opus-5-5", titles: titles + titles, among: catalogue))
        XCTAssertTrue(CurrentModelMatcher.searchResultsOnlyMatch("claude-opus-5-5", titles: [titles[1]], among: catalogue))
    }

    func testUnfilteredOrUnknownResultsNeverAllowReturn() {
        for titles in [[], ["Opus 5.5 High", "GPT-6 Sol High"], ["Opus 5.5 High", "Unknown model"], ["Fable 5.1"]] {
            XCTAssertFalse(CurrentModelMatcher.searchResultsOnlyMatch("claude-opus-5-5", titles: titles, among: catalogue))
        }
    }

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

    func testSpeedTiersFromBothCatalogueSourcesAndOlderSavedModels() throws {
        let result: [String: Any] = ["data": [
            ["model": "gpt-6.1-sol", "displayName": "GPT-6.1-Sol", "additionalSpeedTiers": ["fast", "ultrafast"]],
            ["model": "claude-opus-5-5", "displayName": "Opus 5.5", "additionalSpeedTiers": [String]()],
        ]]
        XCTAssertEqual(CodexModelParsing.parseModelListResult(result).models.map(\.speedTiers), [[.fast, .ultrafast], []])
        let cache = Data("""
            {"models":[{"slug":"gpt-6.1-terra","display_name":"GPT-6.1 Terra","additional_speed_tiers":["fast"]},
                       {"slug":"gpt-5.5","display_name":"GPT-5.5"}]}
            """.utf8)
        XCTAssertEqual(CodexModelParsing.parseModelsCache(cache).map(\.speedTiers), [[.fast], []])
        let saved = CodexModel(id: "gpt-6.1-sol", displayName: "GPT-6.1-Sol", speedTiers: [.fast, .ultrafast])
        XCTAssertEqual(try JSONDecoder().decode(CodexModel.self, from: JSONEncoder().encode(saved)), saved)
        let old = Data(#"[{"id":"gpt-6-sol","displayName":"GPT-6-Sol","description":"","hidden":false}]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([CodexModel].self, from: old).first?.speedTiers, [])
    }
}

final class BarPlacementTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 70, width: 2056, height: 1226)
    private let size = CGSize(width: 142, height: 216)
    private let codex = CGRect(x: 100, y: 400, width: 1400, height: 700)

    func testCoverageNeedsMoreThanHalfTheWindowHidden() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertFalse(BarPlacement.isMostlyCovered(window, by: []))
        XCTAssertFalse(BarPlacement.isMostlyCovered(window, by: [CGRect(x: 0, y: 0, width: 500, height: 800)]), "Exactly half is not mostly")
        XCTAssertTrue(BarPlacement.isMostlyCovered(window, by: [CGRect(x: 0, y: 0, width: 501, height: 800)]))
        XCTAssertTrue(BarPlacement.isMostlyCovered(window, by: [CGRect(x: -50, y: -50, width: 1200, height: 1000)]))
        XCTAssertFalse(BarPlacement.isMostlyCovered(window, by: [CGRect(x: 2000, y: 0, width: 1000, height: 800)]), "A window on another display hides nothing")
    }

    func testFrontWindowsThatOverlapEachOtherAreNotCountedTwice() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let first = CGRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertFalse(BarPlacement.isMostlyCovered(window, by: [first, first.offsetBy(dx: 50, dy: 0)]), "Together they hide 45%, not 80%")
        XCTAssertTrue(BarPlacement.isMostlyCovered(window, by: [first, CGRect(x: 400, y: 0, width: 200, height: 800)]))
    }

    func testBarAvoidsAnotherCodexWindowBelowItsOwn() {
        let window = CGRect(x: 100, y: 500, width: 800, height: 600)
        let other = CGRect(x: 100, y: 100, width: 800, height: 390)
        let result = BarPlacement.place(window: window, visibleFrame: visible, contentSize: CGSize(width: 700, height: 30), obstructingWindows: [other])
        XCTAssertFalse(result.intersects(other))
        XCTAssertFalse(result.intersects(window))
        XCTAssertTrue(visible.contains(result))
    }

    func testAClearNormalSpotIgnoresAnUnrelatedCodexWindow() {
        let window = CGRect(x: 100, y: 500, width: 800, height: 600)
        let normal = BarPlacement.place(window: window, visibleFrame: visible, contentSize: CGSize(width: 700, height: 30))
        let result = BarPlacement.place(window: window, visibleFrame: visible, contentSize: CGSize(width: 700, height: 30),
                                        obstructingWindows: [CGRect(x: 1000, y: 100, width: 900, height: 900)])
        XCTAssertEqual(result, normal)
    }

    func testRightOfFlowCannotCoverTheCodexWindow() {
        let flow = CGRect(x: 200, y: 200, width: 1100, height: 700)
        let result = BarPlacement.place(window: codex, visibleFrame: visible, contentSize: size, agentFlowHUD: flow)
        let oldAnchor = CGRect(x: flow.maxX + 4, y: flow.midY - size.height / 2,
                               width: size.width, height: size.height)
        XCTAssertTrue(oldAnchor.intersects(codex), "The previous right-only anchor reproduces the reported obstruction")
        XCTAssertFalse(result.intersects(codex))
        XCTAssertFalse(result.intersects(flow))
        XCTAssertTrue(visible.contains(result))
        XCTAssertEqual(result.size, size)
    }

    func testMovingCodexRecomputesClearSpaceBesideFlow() {
        let flow = CGRect(x: 200, y: 200, width: 1100, height: 700)
        let result = BarPlacement.place(window: codex, visibleFrame: visible, contentSize: size, agentFlowHUD: flow)
        let moved = BarPlacement.place(window: codex.offsetBy(dx: 900, dy: 100), visibleFrame: visible,
                                       contentSize: size, agentFlowHUD: flow)
        XCTAssertNotEqual(result, moved)
        XCTAssertFalse(result.intersects(codex))
        XCTAssertFalse(moved.intersects(codex.offsetBy(dx: 900, dy: 100)))
        XCTAssertFalse(moved.intersects(flow))
        XCTAssertTrue(visible.contains(moved))
    }

    func testMovingAndGrowingFlowKeepsTheRailClearOfBothWindows() {
        for flow in [CGRect(x: 200, y: 170, width: 1000, height: 160),
                     CGRect(x: 100, y: 170, width: 1100, height: 500),
                     CGRect(x: 200, y: 170, width: 1100, height: 1000)] {
            let result = BarPlacement.place(window: codex, visibleFrame: visible, contentSize: size, agentFlowHUD: flow)
            XCTAssertFalse(result.intersects(codex))
            XCTAssertFalse(result.intersects(flow))
            XCTAssertTrue(visible.contains(result))
        }
    }

    func testBottomFlushFlowBelowTheDockKeepsTheWholeRailOnScreen() {
        let flow = CGRect(x: visible.maxX - 400, y: 0, width: 400, height: 100)
        let result = BarPlacement.place(window: codex, visibleFrame: visible, contentSize: size, agentFlowHUD: flow)
        XCTAssertFalse(result.intersects(codex))
        XCTAssertFalse(result.intersects(flow))
        XCTAssertTrue(visible.contains(result))
    }

    func testPartlyOffscreenFlowKeepsTheRailReachableAtEveryEdge() {
        for flow in [CGRect(x: -1400, y: 200, width: 900, height: 800),
                     CGRect(x: 2000, y: 200, width: 900, height: 800),
                     CGRect(x: 100, y: -800, width: 900, height: 900),
                     CGRect(x: 100, y: 1200, width: 900, height: 900)] {
            let result = BarPlacement.place(window: codex, visibleFrame: visible, contentSize: size, agentFlowHUD: flow)
            XCTAssertTrue(visible.contains(result))
            XCTAssertFalse(result.intersects(codex))
            XCTAssertFalse(result.intersects(flow))
            XCTAssertEqual(result.size, size)
        }
    }

    func testFlowOnAnotherDisplayUsesThatDisplaysCoordinates() {
        let display = visible.offsetBy(dx: -2056, dy: 200)
        let flow = CGRect(x: -1800, y: 500, width: 1100, height: 600)
        let result = BarPlacement.place(window: codex, visibleFrame: display, contentSize: size, agentFlowHUD: flow)
        XCTAssertFalse(result.intersects(codex))
        XCTAssertFalse(result.intersects(flow))
        XCTAssertTrue(display.contains(result))
    }

    func testNoFlowRestoresOriginalBelowCodexStrip() {
        let result = BarPlacement.place(window: codex, visibleFrame: visible, contentSize: CGSize(width: 700, height: 30))
        XCTAssertEqual(result.minY, codex.minY - 30)
        XCTAssertEqual(result.midX, codex.midX)
    }

    func testNoFlowAtTheDockKeepsOriginalAboveCodexStrip() {
        let window = CGRect(x: 100, y: visible.minY, width: 1400, height: 700)
        let result = BarPlacement.place(window: window, visibleFrame: visible, contentSize: CGSize(width: 700, height: 30))
        XCTAssertEqual(result.minY, window.maxY)
    }

    func testFilledScreenRetainsTheVisibleTopEdgeLastResort() {
        let result = BarPlacement.place(window: visible, visibleFrame: visible, contentSize: CGSize(width: 700, height: 30))
        XCTAssertEqual(result.maxY, visible.maxY - 6)
        XCTAssertTrue(visible.contains(result))
    }

    func testOversizedRailIsClampedToTheVisibleScreen() {
        let result = BarPlacement.place(window: codex, visibleFrame: visible,
                                        contentSize: CGSize(width: 3000, height: 2000), agentFlowHUD: visible)
        XCTAssertEqual(result, visible)
    }

    func testSwitchesToFlowsLeftWhenCodexBlocksTheRightSide() {
        let screen = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let window = CGRect(x: 750, y: 0, width: 650, height: 900)
        let flow = CGRect(x: 250, y: 0, width: 500, height: 900)
        let result = BarPlacement.place(window: window, visibleFrame: screen,
                                        contentSize: CGSize(width: 140, height: 100), agentFlowHUD: flow)
        XCTAssertLessThanOrEqual(result.maxX, flow.minX - 4)
        XCTAssertFalse(result.intersects(window))
        XCTAssertTrue(screen.contains(result))
    }

    func testNearbyWrappedControlsBeatADistantHorizontalRowAboveCodex() {
        let flow = CGRect(x: 200, y: 200, width: 1500, height: 700)
        let natural = CGSize(width: 700, height: 30)
        let result = BarPlacement.place(window: codex, visibleFrame: visible, contentSize: natural,
                                        agentFlowHUD: flow, contentSizeForWidth: { width in
            width >= 700 ? natural : CGSize(width: 230, height: 120)
        })
        XCTAssertEqual(result.size, CGSize(width: 230, height: 120))
        XCTAssertEqual(result.maxY, codex.minY)
        XCTAssertFalse(result.intersects(codex))
        XCTAssertFalse(result.intersects(flow))
    }

    func testScreenshotLayoutUsesSpaceRightOfFlowBelowCodexInsteadOfTheTop() {
        let screen = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        let window = CGRect(x: 120, y: 130, width: 1818, height: 1090)
        let flow = CGRect(x: 420, y: 25, width: 950, height: 135)
        let natural = CGSize(width: 785, height: 30)
        let result = BarPlacement.place(window: window, visibleFrame: screen, contentSize: natural,
                                        agentFlowHUD: flow, contentSizeForWidth: { width in
            width >= 785 ? natural : CGSize(width: 550, height: 70)
        })
        XCTAssertEqual(result.maxY, window.minY)
        XCTAssertGreaterThanOrEqual(result.minX, flow.maxX + 4)
        XCTAssertEqual(result.size, CGSize(width: 550, height: 70))
        XCTAssertTrue(screen.contains(result))
        XCTAssertFalse(result.intersects(window))
        XCTAssertFalse(result.intersects(flow))
    }

    func testBottomSideSpaceWinsEvenWhenTheOriginalStripWouldBeAboveCodex() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let window = CGRect(x: 100, y: 20, width: 850, height: 700)
        let natural = CGSize(width: 700, height: 30)
        let result = BarPlacement.place(window: window, visibleFrame: screen, contentSize: natural,
                                        contentSizeForWidth: { width in
            width >= 700 ? natural : CGSize(width: 230, height: 120)
        })
        XCTAssertGreaterThanOrEqual(result.minX, window.maxX)
        XCTAssertEqual(result.minY, screen.minY)
        XCTAssertFalse(result.intersects(window))
    }

    func testKeepsHorizontalControlsWhenTheyFitInTheSameBottomBand() {
        let screen = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        let window = CGRect(x: 120, y: 200, width: 1818, height: 950)
        let flow = CGRect(x: 500, y: 25, width: 600, height: 200)
        let natural = CGSize(width: 700, height: 30)
        let result = BarPlacement.place(window: window, visibleFrame: screen, contentSize: natural,
                                        agentFlowHUD: flow, contentSizeForWidth: { width in
            width >= 700 ? natural : CGSize(width: 230, height: 120)
        })
        XCTAssertEqual(result.size, natural)
        XCTAssertEqual(result.maxY, window.minY)
        XCTAssertGreaterThanOrEqual(result.minX, flow.maxX + 4)
    }

    func testWrapsOnlyWhenEveryClearRegionIsTooNarrowForOneRow() {
        let screen = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let window = CGRect(x: 700, y: 0, width: 700, height: 900)
        let flow = CGRect(x: 250, y: 0, width: 450, height: 900)
        let natural = CGSize(width: 700, height: 30)
        let result = BarPlacement.place(window: window, visibleFrame: screen, contentSize: natural,
                                        agentFlowHUD: flow, contentSizeForWidth: { width in
            width >= 700 ? natural : CGSize(width: 230, height: 120)
        })
        XCTAssertEqual(result.size, CGSize(width: 230, height: 120))
        XCTAssertFalse(result.intersects(window))
        XCTAssertFalse(result.intersects(flow))
        XCTAssertTrue(screen.contains(result))
    }

    func testAvoidsOtherFlowPanelsAsWellAsTheSelectedHud() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let window = CGRect(x: 200, y: 250, width: 1000, height: 500)
        let flow = CGRect(x: 200, y: 0, width: 1000, height: 250)
        let other = CGRect(x: 1200, y: 0, width: 400, height: 900)
        let result = BarPlacement.place(window: window, visibleFrame: screen,
                                        contentSize: CGSize(width: 300, height: 30), agentFlowHUD: flow,
                                        obstructingWindows: [flow, other])
        for obstacle in [window, flow, other] { XCTAssertFalse(result.intersects(obstacle)) }
        XCTAssertTrue(screen.contains(result))
    }

    func testMovingFlowAcrossTheScreenNeverCoversEitherWindowWhenSpaceExists() {
        for x in stride(from: -200, through: 2200, by: 200) {
            for y in stride(from: -200, through: 1400, by: 200) {
                let flow = CGRect(x: x, y: y, width: 500, height: 300)
                let result = BarPlacement.place(window: codex, visibleFrame: visible, contentSize: size,
                                                agentFlowHUD: flow)
                XCTAssertTrue(visible.contains(result), "Flow at \(flow)")
                XCTAssertFalse(result.intersects(codex), "Flow at \(flow)")
                XCTAssertFalse(result.intersects(flow), "Flow at \(flow)")
            }
        }
    }

    func testWindowServerCoordinatesStillConvertToCocoaCoordinates() {
        let window = CoordinateConversion.cocoaRect(fromCGBounds: CGRect(x: 120, y: 212, width: 1818, height: 985),
                                                    primaryScreenHeight: 1329)
        XCTAssertEqual(window, CGRect(x: 120, y: 132, width: 1818, height: 985))
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

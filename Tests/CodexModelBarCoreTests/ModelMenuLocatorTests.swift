import XCTest
@testable import CodexModelBarCore

final class ModelMenuLocatorTests: XCTestCase {
    private final class Node {
        let role: String
        let text: String
        var children: [Node]
        init(_ role: String = "group", _ text: String = "", _ children: [Node] = []) {
            self.role = role; self.text = text; self.children = children
        }
    }
    private let input = Node("input")
    private let target = Node("button", "GPT-6 Sol")
    private var locator: ModelMenuLocator<Node> {
        ModelMenuLocator(children: { $0.children }, isWebArea: { $0.role == "web" },
                         isButton: { $0.role == "button" },
                         header: { ["Recent models", "Matching models"].contains($0.text) ? $0.text : nil },
                         equals: { $0 === $1 }, isListBox: { $0.role == "listbox" },
                         isOption: { $0.role == "option" }, isSearchInput: { $0.role == "search" })
    }
    private func menu(_ title: String = "Recent models") -> Node {
        Node("group", "", [Node("group", "", [Node("group", "", [Node("text", title)]), target])])
    }
    // Source-derived fixture, not a captured live AX tree: Codex 26.1111.21308,
    // app.asar modules QT6E (popup search), OOvA (listbox / section items), and
    // the model submenu in 486887.8844429c7e.js. Native option roles are mapped
    // separately by CodexUI; the shortcut in the title must never become a result.
    private func popup(search: Node, sections: [Node]) -> Node {
        Node("group", "", [Node("group", "", [search]), Node("listbox", "", sections)])
    }
    private func section(_ title: String, _ entries: [Node]) -> Node {
        Node("group", "", [
            Node("group", "", [Node("group", "", [Node("text", title), Node("button", "Control+Command+M")])]),
            Node("group", "", entries)
        ])
    }
    func testPopupSearchAndNestedOptionsExcludeHeaderShortcut() {
        let search = Node("search"), recent = Node("option", "1 GPT-6 Sol High"), matching = Node("option", "GPT-6 Sol")
        let view = Node("web", "", [input, popup(search: search, sections: [section("Recent models", [recent]), section("Matching models", [matching])])])
        let found = locator.locate(in: Node("window", "", [view]), composer: input)
        XCTAssertTrue(found?.searchInput === search)
        XCTAssertEqual(found?.recent.count, 1)
        XCTAssertTrue(found?.recent.first === recent)
        XCTAssertTrue(found?.matching.first === matching)
    }
    func testRecentUltrafastPresetRequiresHighlightingTheCatalogueRow() throws {
        let recent = Node("option", "1 GPT-6.2 Sol High Ultrafast")
        let matching = Node("option", "GPT-6.2 Sol")
        let list = Node("listbox", "", [
            Node("text", "Recent models"), recent, Node("text", "Matching models"), matching
        ])
        let found = try XCTUnwrap(locator.locate(in: Node("web", "", [input, list]), composer: input))
        XCTAssertFalse(found.canChooseMatchingModel { $0 === recent })
        XCTAssertTrue(found.canChooseMatchingModel { $0 === matching })
        XCTAssertFalse(found.canChooseMatchingModel { _ in false })
        XCTAssertFalse(found.canChooseMatchingModel { _ in true })

        list.children = Array(list.children.prefix(2))
        let recentOnly = try XCTUnwrap(locator.locate(in: Node("web", "", [input, list]), composer: input))
        XCTAssertFalse(recentOnly.canChooseMatchingModel { _ in true })
    }

    func testPopupFindsFilteredMatchingSectionWithoutRecentResults() {
        let search = Node("search"), matching = Node("option", "Opus 5.5")
        let view = Node("web", "", [input, popup(search: search, sections: [section("Matching models", [matching])])])
        let found = locator.locate(in: Node("window", "", [view]), composer: input)
        XCTAssertTrue(found?.searchInput === search)
        XCTAssertEqual(found?.recent.count, 0)
        XCTAssertTrue(found?.matching.first === matching)
        XCTAssertEqual(found?.canChooseMatchingModel { _ in false }, true)
    }
    func testPopupWithoutItsOwnSearchInputSearchesThroughTheListBoxNotTheComposer() {
        let list = Node("listbox", "", [section("Recent models", [Node("option")])])
        let found = locator.locate(in: Node("window", "", [Node("web", "", [input, list])]), composer: input)
        XCTAssertTrue(found?.searchInput === list)
    }
    // Captured from live Codex 26.1111 with Accessibility on 2026-11-15: no search
    // field is exposed, focus sits on an option, and the options are the listbox's
    // direct children. CodexUI's option predicate (DOM id "-option-N") already
    // excludes each option's name parts and the header's ⌃⌘M text.
    func testLiveHiddenSearchMenuFindsBothSections() {
        let recent = Node("option", "1 GPT-6.1 Sol Extra High Standard", [Node("text", "Extra High")])
        let matching = Node("option", "GPT-6.1 Sol Latest workhorse model")
        let list = Node("listbox", "", [
            Node("group", "", [Node("text", "Recent models"), Node("text", "⌃⌘M")]), recent,
            Node("group", "", [Node("text", "Matching models")]), matching])
        let view = Node("web", "", [input, Node("group", "", [Node("group", "", [list])])])
        let found = locator.locate(in: Node("window", "", [view]), composer: input)
        XCTAssertTrue(found?.searchInput === list)
        XCTAssertEqual(found?.recent.count, 1)
        XCTAssertTrue(found?.recent.first === recent)
        XCTAssertEqual(found?.matching.count, 1)
        XCTAssertTrue(found?.matching.first === matching)
    }
    // Observed in the isolated IAB fixture on 2026-11-15: the title retained one
    // group, but options and Matching models became direct listbox children.
    func testBrowserFlattenedMenuReachesBothModelSections() {
        let search = Node("search"), recent = Node("option", "Opus 5.5"), matching = Node("option", "Fable 5.2")
        let list = Node("listbox", "", [
            Node("group", "", [Node("text", "Recent models"), Node("button", "Control+Command+M")]),
            recent, Node("text", "Matching models"), matching
        ])
        let view = Node("web", "", [input, Node("group", "", [search, list])])
        let found = locator.locate(in: Node("window", "", [view]), composer: input)
        XCTAssertTrue(found?.searchInput === search)
        XCTAssertEqual(found?.recent.count, 1)
        XCTAssertTrue(found?.recent.first === recent)
        XCTAssertEqual(found?.matching.count, 1)
        XCTAssertTrue(found?.matching.first === matching)
    }
    func testPopupWrapperCanAlsoBeIgnoredWithoutLosingItsFocusedSearch() {
        let search = Node("search"), matching = Node("option", "Fable 5.2")
        let list = Node("listbox", "", [Node("text", "Matching models"), matching])
        let view = Node("web", "", [input, search, list])
        let found = locator.locate(in: Node("window", "", [view]), composer: input)
        XCTAssertTrue(found?.searchInput === search)
        XCTAssertTrue(found?.matching.first === matching)
    }
    func testSectionsUseReadingOrderAcrossDifferentWrapperDepths() {
        for depth in 0...6 {
            let search = Node("search"), recent = Node("option", "Opus 5.5"), matching = Node("option", "Fable 5.2")
            var recentNode = recent, matchingNode = matching
            for _ in 0..<depth { recentNode = Node("group", "", [recentNode]); matchingNode = Node("group", "", [matchingNode]) }
            let list = Node("listbox", "", [Node("text", "Recent models"), recentNode, Node("text", "Matching models"), matchingNode])
            let found = locator.locate(in: Node("window", "", [Node("web", "", [input, search, list])]), composer: input)
            XCTAssertTrue(found?.recent.first === recent)
            XCTAssertTrue(found?.matching.first === matching)
        }
    }
    func testAnotherModelSearchFieldInTheSameWebAreaIsAmbiguous() {
        let list = Node("listbox", "", [Node("text", "Matching models"), Node("option", "Fable 5.2")])
        let view = Node("web", "", [input, Node("search"), Node("group", "", [Node("search"), list])])
        XCTAssertNil(locator.locate(in: Node("window", "", [view]), composer: input))
    }
    func testOriginalAdjacentMenu() {
        let window = Node("window", "", [Node("web", "", [Node("group", "", [input, menu()])])])
        XCTAssertTrue(locator.locate(in: window, composer: input)?.recent.first === target)
        XCTAssertNil(locator.locate(in: window, composer: input)?.searchInput)
    }
    func testPortalOutsideDeepComposerAncestorsAndMatchingSearch() {
        var nested = input
        for _ in 0..<20 { nested = Node("group", "", [nested]) }
        let window = Node("window", "", [Node("web", "", [nested, menu("Matching models")])])
        XCTAssertTrue(locator.locate(in: window, composer: input)?.matching.first === target)
    }
    func testEmbeddedBrowserCannotSupplyMenu() {
        let window = Node("window", "", [Node("web", "", [input, Node("web", "", [menu()])])])
        XCTAssertNil(locator.locate(in: window, composer: input))
    }
    func testTwoMenusAreAmbiguous() {
        let window = Node("window", "", [Node("web", "", [input, menu(), menu()])])
        XCTAssertNil(locator.locate(in: window, composer: input))
    }
    func testMissingComposerAndPlainChatTextDoNotMatch() {
        let window = Node("window", "", [Node("web", "", [menu()])])
        XCTAssertNil(locator.locate(in: window, composer: input))
        window.children[0].children = [input, Node("text", "Recent models")]
        XCTAssertNil(locator.locate(in: window, composer: input))
    }
}

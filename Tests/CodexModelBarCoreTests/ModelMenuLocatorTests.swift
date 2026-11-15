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
    func testPopupFindsFilteredMatchingSectionWithoutRecentResults() {
        let search = Node("search"), matching = Node("option", "Opus 5.5")
        let view = Node("web", "", [input, popup(search: search, sections: [section("Matching models", [matching])])])
        let found = locator.locate(in: Node("window", "", [view]), composer: input)
        XCTAssertTrue(found?.searchInput === search)
        XCTAssertEqual(found?.recent.count, 0)
        XCTAssertTrue(found?.matching.first === matching)
    }
    func testPopupWithoutItsOwnSearchInputDoesNotTypeIntoComposer() {
        let view = Node("web", "", [input, Node("listbox", "", [section("Recent models", [Node("option")])])])
        XCTAssertNil(locator.locate(in: Node("window", "", [view]), composer: input))
    }
    func testPopupWithTwoSearchInputsIsAmbiguous() {
        let menu = popup(search: Node("group", "", [Node("search"), Node("search")]), sections: [section("Recent models", [Node("option")])])
        XCTAssertNil(locator.locate(in: Node("window", "", [Node("web", "", [input, menu])]), composer: input))
    }
    func testEmbeddedBrowserCannotSupplyPopupSearchOrResults() {
        let embedded = Node("web", "", [popup(search: Node("search"), sections: [section("Recent models", [Node("option")])])])
        XCTAssertNil(locator.locate(in: Node("window", "", [Node("web", "", [input, embedded])]), composer: input))
        let split = Node("group", "", [embedded, Node("listbox", "", [section("Recent models", [Node("option")])])])
        XCTAssertNil(locator.locate(in: Node("window", "", [Node("web", "", [input, split])]), composer: input))
    }
    func testTwoPopupMenusAndDuplicateHeadersAreAmbiguous() {
        let menu = popup(search: Node("search"), sections: [section("Recent models", [Node("option")])])
        let other = popup(search: Node("search"), sections: [section("Recent models", [Node("option")])])
        XCTAssertNil(locator.locate(in: Node("window", "", [Node("web", "", [input, menu, other])]), composer: input))
        let duplicates = popup(search: Node("search"), sections: [section("Recent models", [Node("option")]), section("Recent models", [Node("option")])])
        XCTAssertNil(locator.locate(in: Node("window", "", [Node("web", "", [input, duplicates])]), composer: input))
    }
    func testOptionInspectionSkipsTheTranscriptOutsideAListBox() {
        var inspected = 0
        let fast = ModelMenuLocator<Node>(children: { $0.children }, isWebArea: { $0.role == "web" },
            isButton: { $0.role == "button" }, header: { _ in nil }, equals: { $0 === $1 },
            isListBox: { $0.role == "listbox" }, isOption: { _ in inspected += 1; return false })
        XCTAssertNil(fast.locate(in: Node("window", "", [Node("web", "", [input, Node("text", "long transcript")])]), composer: input))
        XCTAssertEqual(inspected, 0, "Option attribute reads belong to the popup, not every transcript sentence")
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

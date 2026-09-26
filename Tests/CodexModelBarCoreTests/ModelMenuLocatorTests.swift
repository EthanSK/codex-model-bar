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
                         equals: { $0 === $1 })
    }
    private func menu(_ title: String = "Recent models") -> Node {
        Node("group", "", [Node("group", "", [Node("group", "", [Node("text", title)]), target])])
    }
    func testOriginalAdjacentMenu() {
        let window = Node("window", "", [Node("web", "", [Node("group", "", [input, menu()])])])
        XCTAssertTrue(locator.locate(in: window, composer: input)?.recent.first === target)
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

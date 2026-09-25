import XCTest
@testable import CodexModelBarCore

final class ComposerLocatorTests: XCTestCase {
    private final class Tree {
        var children: [String: [String]] = [
            "window": ["main", "side", "editor", "picker"],
            "main": ["main-input", "main-tools"], "main-tools": ["main-model"],
            "side": ["side-input", "side-tools"], "side-tools": ["side-model"],
        ]
        var parents: [String: String] = [:]
        let inputs = Set(["main-input", "side-input", "editor"])
        var models = Set(["main-model", "side-model"])
        init() {
            for (parent, nodes) in children { for node in nodes { parents[node] = parent } }
        }
        var locator: ComposerLocator<String> {
            ComposerLocator(children: { self.children[$0] ?? [] }, parent: { self.parents[$0] },
                            isTextArea: { self.inputs.contains($0) },
                            isModelButton: { self.models.contains($0) }, equals: ==)
        }
    }

    func testFocusedMainAndSideOverridePreviouslyFocusedInput() {
        let tree = Tree()
        XCTAssertEqual(tree.locator.locate(in: "window", focused: "side-input", previousComposer: "main-input")?.composer,
                       "side-input")
        XCTAssertEqual(tree.locator.locate(in: "window", focused: "main-input", previousComposer: "side-input")?.composer,
                       "main-input")
        XCTAssertEqual(tree.locator.locate(in: "window", focused: "side-model", previousComposer: "main-input")?.composer,
                       "side-input")
    }

    func testPickerPreservesLastInputButUnrelatedTextAreaCannotRedirectAction() {
        let tree = Tree()
        XCTAssertEqual(tree.locator.locate(in: "window", focused: "picker", previousComposer: "side-input")?.composer,
                       "side-input")
        XCTAssertNil(tree.locator.locate(in: "window", focused: "picker", previousComposer: nil))
        XCTAssertNil(tree.locator.locate(in: "window", focused: "editor", previousComposer: "side-input"))
        tree.models.remove("side-model")
        XCTAssertNil(tree.locator.locate(in: "window", focused: "side-input", previousComposer: "main-input"))
    }

    func testDetachedOldChatIsRejectedEvenWhenItsParentAndTitleSurvive() {
        let tree = Tree()
        tree.children["window"] = ["side", "editor", "picker"]
        // Stale AX objects can still return their former parent and model title.
        XCTAssertEqual(tree.locator.locate(in: "window", focused: "picker", previousComposer: "main-input")?.composer,
                       "side-input")
    }

    func testReplacedModelButtonIsReadFromTheCurrentComposerSubtree() {
        let tree = Tree()
        tree.children["side-tools"] = ["replacement-model"]
        tree.parents["replacement-model"] = "side-tools"
        tree.models.insert("replacement-model")
        XCTAssertEqual(tree.locator.locate(in: "window", focused: "picker", previousComposer: "side-input")?.modelButton,
                       "replacement-model")
    }

    func testUnpairedButtonCannotBorrowAnUnrelatedTextArea() {
        let locator = ComposerLocator<String>(children: { $0 == "window" ? ["model", "input-a", "input-b"] : [] },
            parent: { $0 == "window" ? nil : "window" }, isTextArea: { $0.hasPrefix("input") },
            isModelButton: { $0 == "model" }, equals: ==)
        XCTAssertNil(locator.locate(in: "window", focused: "input-b", previousComposer: nil))
    }

    func testFocusedComposerBeyondFastScanBudgetStillWins() {
        let tree = Tree()
        let attachments = (0..<220).map { "attachment-\($0)" }
        tree.children["main"] = ["main-input"] + attachments + ["main-tools"]
        attachments.forEach { tree.parents[$0] = "main" }
        XCTAssertEqual(tree.locator.locate(in: "window", focused: "main-input", previousComposer: "side-input")?.composer,
                       "main-input")
    }
}

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
        var inputs = Set(["main-input", "side-input", "editor"])
        var models = Set(["main-model", "side-model"])
        var focusedInputs: Set<String> = []
        init() {
            for (parent, nodes) in children { for node in nodes { parents[node] = parent } }
        }
        var locator: ComposerLocator<String> {
            ComposerLocator(children: { self.children[$0] ?? [] }, parent: { self.parents[$0] },
                            isTextArea: { self.inputs.contains($0) },
                            isModelButton: { self.models.contains($0) }, equals: ==,
                            hasKeyboardFocus: { self.focusedInputs.contains($0) })
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

    func testFlattenedParentsDoNotRejectTheFocusedSideComposer() {
        let tree = Tree()
        // The input is listed directly under side, but its AXParent reports an
        // intermediate group omitted from side's AXChildren (Chromium flattening).
        tree.parents["side-input"] = "omitted-group"
        tree.parents["omitted-group"] = "side"
        tree.children["omitted-group"] = ["side-input"]
        XCTAssertEqual(tree.locator.locate(in: "window", focused: "side-input", previousComposer: "main-input")?.composer,
                       "side-input")
    }

    func testInputFocusFlagWinsOverRememberedComposerWhenAppFocusIsAContainer() {
        let tree = Tree()
        tree.focusedInputs = ["side-input"]
        XCTAssertEqual(tree.locator.locate(in: "window", focused: "window", previousComposer: "main-input")?.composer,
                       "side-input")
        tree.focusedInputs.insert("main-input")
        XCTAssertNil(tree.locator.locate(in: "window", focused: "window", previousComposer: "main-input"))
    }

    func testLoadingSideInputCannotRedirectItsFocusFlagToTheMainTask() {
        let tree = Tree()
        tree.models.remove("side-model")
        tree.focusedInputs = ["side-input"]
        XCTAssertNil(tree.locator.locate(in: "window", focused: "window", previousComposer: "main-input"))
    }

    func testSideInputReplacementCannotConfirmAgainstTheOtherTask() throws {
        let tree = Tree()
        let original = try XCTUnwrap(tree.locator.locate(in: "window", focused: "side-input", previousComposer: nil))
        let identity = ComposerIdentity(input: original.composer, scopeAncestors: original.scopeAncestors)
        XCTAssertEqual(original.scopeAncestors, ["side"])
        // Recorded failure: side input detaches after choosing Opus; the main
        // input already uses Opus and briefly becomes the sole candidate.
        tree.children["side"] = []
        let other = try XCTUnwrap(tree.locator.locate(in: "window", focused: nil, previousComposer: "side-input"))
        XCTAssertEqual(other.composer, "main-input")
        XCTAssertFalse(identity.matches(ComposerIdentity(input: other.composer, scopeAncestors: other.scopeAncestors), equals: ==))
        // The same side scope then receives a new input and a new model button.
        tree.children["side"] = ["new-input", "new-model"]
        tree.parents["new-input"] = "side"
        tree.parents["new-model"] = "side"
        tree.inputs.insert("new-input")
        tree.models.insert("new-model")
        let replacement = try XCTUnwrap(tree.locator.locate(in: "window", focused: "new-input", previousComposer: "side-input"))
        XCTAssertTrue(identity.matches(ComposerIdentity(input: replacement.composer, scopeAncestors: replacement.scopeAncestors), equals: ==))
    }

    func testReplacementNeedsASurvivingExclusiveScopeFromTheLiveTree() throws {
        let tree = Tree()
        tree.children["side-shell"] = ["side"]
        tree.parents["side"] = "side-shell"
        tree.children["window"] = ["main", "side-shell", "editor"]
        tree.parents["side-shell"] = "window"
        let original = try XCTUnwrap(tree.locator.locate(in: "window", focused: "side-input", previousComposer: nil))
        XCTAssertEqual(original.scopeAncestors, ["side", "side-shell"])
        let identity = ComposerIdentity(input: original.composer, scopeAncestors: original.scopeAncestors)
        tree.children["side-shell"] = ["new-input", "new-model"]
        tree.inputs.insert("new-input")
        tree.models.insert("new-model")
        tree.parents["new-input"] = "side-shell"
        tree.parents["new-model"] = "side-shell"
        let replacement = try XCTUnwrap(tree.locator.locate(in: "window", focused: "new-input", previousComposer: nil))
        XCTAssertTrue(identity.matches(ComposerIdentity(input: replacement.composer, scopeAncestors: replacement.scopeAncestors), equals: ==))
        // Whole task subtree was replaced: matching placement/order or stale AX
        // parents alone must not join the new task to the old one.
        tree.children["window"] = ["main", "new-input", "new-model"]
        let unrelated = try XCTUnwrap(tree.locator.locate(in: "window", focused: "new-input", previousComposer: nil))
        XCTAssertTrue(unrelated.scopeAncestors.isEmpty)
        XCTAssertFalse(identity.matches(ComposerIdentity(input: unrelated.composer, scopeAncestors: unrelated.scopeAncestors), equals: ==))
    }
}

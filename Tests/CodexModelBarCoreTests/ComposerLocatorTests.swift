import XCTest
@testable import CodexModelBarCore

final class ComposerLocatorTests: XCTestCase {
    func testEmbeddedBrowserTreeIsNotReadOrAcceptedAsAComposer() {
        let nodes = ["window": ["app-web"], "app-web": ["browser-web", "composer"],
                     "browser-web": ["foreign-input", "foreign-model"],
                     "composer": ["input", "model"]]
        let parents = ["app-web": "window", "browser-web": "app-web", "composer": "app-web",
                       "input": "composer", "model": "composer",
                       "foreign-input": "browser-web", "foreign-model": "browser-web"]
        var readEmbeddedChildren = false
        let locator = ComposerLocator<String>(children: {
            if $0 == "browser-web" { readEmbeddedChildren = true }
            return nodes[$0] ?? []
        }, parent: { parents[$0] }, isTextArea: { $0.hasSuffix("input") },
           isModelButton: { $0.hasSuffix("model") }, equals: ==,
           isWebArea: { $0.hasSuffix("-web") })
        XCTAssertEqual(locator.locate(in: "window", focused: "input", previousComposer: nil)?.composer, "input")
        XCTAssertFalse(readEmbeddedChildren, "An embedded page must not allocate/read its potentially huge descendant tree")
        XCTAssertNil(locator.locate(in: "window", focused: "foreign-input", previousComposer: "input"),
                     "An embedded input must not redirect actions to the Codex composer")
    }

    func testSeparateTopLevelWebAreasCanEachOwnAComposer() {
        let nodes = ["window": ["main-web", "side-web"], "main-web": ["main"], "side-web": ["side"],
                     "main": ["main-input", "main-model"], "side": ["side-input", "side-model"]]
        var parents: [String: String] = [:]
        for (parent, children) in nodes { for child in children { parents[child] = parent } }
        let locator = ComposerLocator<String>(children: { nodes[$0] ?? [] }, parent: { parents[$0] },
            isTextArea: { $0.hasSuffix("input") }, isModelButton: { $0.hasSuffix("model") }, equals: ==,
            isWebArea: { $0.hasSuffix("-web") })
        XCTAssertEqual(locator.locate(in: "window", focused: "side-input", previousComposer: "main-input")?.composer, "side-input")
        XCTAssertEqual(locator.locate(in: "window", focused: "main-input", previousComposer: "side-input")?.composer, "main-input")
    }

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
                            hasKeyboardFocus: { self.focusedInputs.contains($0) },
                            isConversationRegion: { $0.hasSuffix("-region") })
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

    func testSpeedInputDoesNotWaitForTheModelControlInEitherPane() {
        let tree = Tree()
        tree.children["window"] = ["main-region", "side-region", "editor"]
        tree.children["main-region"] = ["main"]
        tree.children["side-region"] = ["side"]
        tree.models = []
        for (focused, previous, expected) in [("main-input", "side-input", "main-region"),
                                               ("side-input", "main-input", "side-region"),
                                               ("side-region", "main-input", "side-region")] {
            XCTAssertNil(tree.locator.locate(in: "window", focused: focused, previousComposer: previous),
                         "The former speed lookup rejected this input solely because the model control was missing")
            XCTAssertEqual(tree.locator.conversation(in: "window", focused: focused, previousComposer: previous), expected)
            XCTAssertEqual(tree.locator.input(inConversation: expected), expected.replacingOccurrences(of: "region", with: "input"))
        }
    }

    func testReasoningCanReadTheClickedPanesModelAfterFocusingItsComposer() throws {
        let tree = Tree()
        tree.children["window"] = ["main-region", "side-region"]
        tree.children["main-region"] = ["main"]
        tree.children["side-region"] = ["question-input", "side"]
        tree.inputs.insert("question-input")
        for (parent, children) in tree.children { for child in children { tree.parents[child] = parent } }
        XCTAssertNil(tree.locator.locate(in: "window", focused: "side-region", previousComposer: "main-input"),
                     "Reading model metadata before focusing rejects a pane containing both a question and a composer")
        let region = try XCTUnwrap(tree.locator.conversation(in: "window", focused: "side-region", previousComposer: "main-input"))
        let input = try XCTUnwrap(tree.locator.input(inConversation: region))
        XCTAssertEqual(input, "side-input", "Focus the composer, not the question answer or remembered main chat")
        let located = try XCTUnwrap(tree.locator.locate(in: "window", focused: input, previousComposer: "main-input"))
        XCTAssertEqual(located.composer, input)
        XCTAssertEqual(located.modelButton, "side-model")
    }

    func testFocusedSpeedRouteSkipsLargeTranscriptsInBothPanes() {
        let nodes = ["window": ["app-web"], "app-web": ["main-region", "side-region"],
                     "main-region": ["main-transcript", "main-composer"],
                     "side-region": ["side-transcript", "side-composer"],
                     "main-composer": ["main-input"], "side-composer": ["side-input"]]
        var parents: [String: String] = [:]
        for (parent, children) in nodes { for child in children { parents[child] = parent } }
        var reads: [String] = []
        let locator = ComposerLocator<String>(children: {
            reads.append($0)
            XCTAssertFalse($0.hasSuffix("transcript"), "An already-focused input must not walk message history")
            return nodes[$0] ?? []
        }, parent: { parents[$0] }, isTextArea: { $0.hasSuffix("input") },
           isModelButton: { _ in XCTFail("Speed must not require model metadata"); return false }, equals: ==,
           isWebArea: { $0.hasSuffix("-web") }, isConversationRegion: { $0.hasSuffix("-region") })
        for pane in ["main", "side"] {
            reads = []
            XCTAssertEqual(locator.focusedInput(in: "window", focused: "\(pane)-input"), "\(pane)-input")
            XCTAssertEqual(reads, ["\(pane)-composer", "\(pane)-region", "app-web", "window"])
        }
    }

    func testMissingOrFlattenedParentsKeepTheExistingChildTreeRoute() {
        for parents in [[String: String](), ["input": "app-web", "app-web": "window"]] {
            let nodes = ["window": ["app-web"], "app-web": ["chat-region"], "chat-region": ["input"]]
            let locator = ComposerLocator<String>(children: { nodes[$0] ?? [] }, parent: { parents[$0] },
                isTextArea: { $0 == "input" }, isModelButton: { _ in false }, equals: ==,
                isWebArea: { $0 == "app-web" }, isConversationRegion: { $0 == "chat-region" })
            XCTAssertNil(locator.focusedInput(in: "window", focused: "input"))
            XCTAssertEqual(locator.conversation(in: "window", focused: "input", previousComposer: nil), "chat-region")
            XCTAssertEqual(locator.input(inConversation: "chat-region"), "input")
        }
    }

    func testFocusedSpeedRouteRejectsForeignDetachedEmbeddedAndCyclicInputs() {
        let nodes = ["window": ["app-web", "editor-input"], "app-web": ["chat-region"],
                     "chat-region": ["input", "browser-web"], "browser-web": ["foreign-input"],
                     "old-region": ["detached-input"], "cycle": ["cyclic-input"]]
        var parents: [String: String] = [:]
        for (parent, children) in nodes { for child in children { parents[child] = parent } }
        parents["old-region"] = "app-web"
        parents["cycle"] = "cycle"
        let locator = ComposerLocator<String>(children: { nodes[$0] ?? [] }, parent: { parents[$0] },
            isTextArea: { $0 == "input" || $0.hasSuffix("-input") }, isModelButton: { _ in false }, equals: ==,
            isWebArea: { $0.hasSuffix("-web") }, isConversationRegion: { $0.hasSuffix("-region") })
        XCTAssertEqual(locator.focusedInput(in: "window", focused: "input"), "input")
        for focused in ["editor-input", "foreign-input", "detached-input", "cyclic-input", "chat-region"] {
            XCTAssertNil(locator.focusedInput(in: "window", focused: focused), focused)
        }
        XCTAssertNil(locator.focusedInput(in: "window", focused: nil))
    }

    func testSpeedUsesTheClickedRegionDespiteMissingParentLinksAndTheOtherFocusedFlag() {
        let tree = Tree()
        tree.children["window"] = ["main-region", "side-region", "editor"]
        tree.children["main-region"] = ["main"]
        tree.children["side-region"] = ["side"]
        tree.focusedInputs = ["main-input"]
        tree.parents = [:]
        XCTAssertEqual(tree.locator.conversation(in: "window", focused: "side-region", previousComposer: "main-input"), "side-region")
        XCTAssertEqual(tree.locator.input(inConversation: "side-region"), "side-input")
    }

    func testSpeedPinsTheEmptyPaneAndWaitsForOnlyThatPanesInput() throws {
        let tree = Tree()
        tree.children["window"] = ["main-region", "side-region"]
        tree.children["main-region"] = ["main"]
        tree.children["side-region"] = []
        let target = try XCTUnwrap(tree.locator.conversation(in: "window", focused: "side-region", previousComposer: "main-input"))
        XCTAssertEqual(target, "side-region")
        XCTAssertNil(tree.locator.input(inConversation: "side-region"))
        tree.children["side-region"] = ["side"]
        XCTAssertEqual(tree.locator.input(inConversation: target), "side-input")
    }

    func testSpeedRejectsASharedOuterRegionWithOnlyOneLoadedChildChat() {
        let tree = Tree()
        tree.children["window"] = ["outer-region"]
        tree.children["outer-region"] = ["main-region", "side-region"]
        tree.children["main-region"] = ["main"]
        tree.children["side-region"] = []
        XCTAssertNil(tree.locator.conversation(in: "window", focused: "outer-region", previousComposer: "main-input"))
        XCTAssertNil(tree.locator.input(inConversation: "outer-region"))
        XCTAssertEqual(tree.locator.conversation(in: "window", focused: "side-region", previousComposer: "main-input"), "side-region")
    }

    func testSpeedRejectsForeignAndDetachedInputs() {
        let tree = Tree()
        tree.children["window"] = ["main-region", "side-region", "editor"]
        tree.children["main-region"] = ["main"]
        tree.children["side-region"] = ["side"]
        XCTAssertNil(tree.locator.conversation(in: "window", focused: "editor", previousComposer: "main-input"))
        tree.children["window"] = ["side-region"]
        XCTAssertNil(tree.locator.conversation(in: "window", focused: "main-input", previousComposer: "main-input"))
    }

    func testSpeedTargetsTheComposerBelowAPendingQuestionCard() {
        let tree = Tree()
        tree.children["window"] = ["main-region", "side-region"]
        tree.children["main-region"] = ["main"]
        tree.children["side-region"] = ["side-question", "side"] // Measured 2026-10-27: the question card's answer box precedes the composer in the same Conversation.
        tree.inputs.insert("side-question")
        for focused in ["side-question", "side-input", "side-region"] {
            XCTAssertEqual(tree.locator.conversation(in: "window", focused: focused, previousComposer: "main-input"), "side-region", focused)
        }
        XCTAssertEqual(tree.locator.input(inConversation: "side-region"), "side-input")
    }

    func testFocusedSpeedRouteNeverPostsIntoAQuestionAnswerBox() {
        let nodes = ["window": ["app-web"], "app-web": ["chat-region"],
                     "chat-region": ["transcript", "footer"], "footer": ["question", "composer"],
                     "question": ["question-input"], "composer": ["composer-input", "toolbar"]]
        var parents: [String: String] = [:]
        for (parent, children) in nodes { for child in children { parents[child] = parent } }
        let locator = ComposerLocator<String>(children: {
            XCTAssertNotEqual($0, "transcript", "The fast route must still skip message history")
            return nodes[$0] ?? []
        }, parent: { parents[$0] }, isTextArea: { $0.hasSuffix("-input") }, isModelButton: { _ in false }, equals: ==,
           isWebArea: { $0.hasSuffix("-web") }, isConversationRegion: { $0.hasSuffix("-region") })
        XCTAssertNil(locator.focusedInput(in: "window", focused: "question-input"),
                     "Pasting /fast + Return into the answer box would submit it as the answer")
        XCTAssertEqual(locator.focusedInput(in: "window", focused: "composer-input"), "composer-input")
    }

    func testPageFocusReusesTheRememberedComposerOnlyWithoutAConversation() {
        var nodes = ["window": ["app-web"], "app-web": ["thread", "side"], "thread": ["main-input"],
                     "side": ["side-input"], "browser-web": ["browser-input"]]
        var parents: [String: String] { nodes.reduce(into: [:]) { result, entry in entry.value.forEach { result[$0] = entry.key } } }
        func locator() -> ComposerLocator<String> {
            let parents = parents
            return ComposerLocator(children: { nodes[$0] ?? [] }, parent: { parents[$0] },
                                   isTextArea: { $0.hasSuffix("-input") }, isModelButton: { _ in false }, equals: ==,
                                   isWebArea: { $0.hasSuffix("-web") }, isConversationRegion: { $0.hasSuffix("-region") })
        }
        XCTAssertEqual(locator().regionlessInput("main-input", in: "window", focused: "app-web"), "main-input",
                       "Switching back to Codex leaves focus on its page while a new transcript has no Conversation landmark")
        XCTAssertEqual(locator().regionlessInput("main-input", in: "window", focused: "window"), "main-input")
        XCTAssertNil(locator().regionlessInput("main-input", in: "window", focused: "side"),
                     "A focused pane must not be redirected to the remembered composer")
        XCTAssertNil(locator().regionlessInput("main-input", in: "window", focused: "browser-web"),
                     "An embedded browser page above no composer is not Codex's page")
        nodes["app-web"] = ["side"]
        XCTAssertNil(locator().regionlessInput("main-input", in: "window", focused: "app-web"), "A detached composer is never reused")
        nodes["app-web"] = ["chat-region", "side"]
        nodes["chat-region"] = ["thread"]
        XCTAssertNil(locator().regionlessInput("main-input", in: "window", focused: "app-web"),
                     "With a Conversation the existing pane route decides")
    }

    func testInterruptedWalkStopsEarlyAndClaimsNothing() {
        var reads = 0
        var interrupt = false
        let rows = (0..<200).map { "row\($0)" }
        let locator = ComposerLocator<String>(children: { node in
            reads += 1
            switch node {
            case "window": return rows + ["composer"]
            case "composer": return ["input", "model"]
            default: return []
            }
        }, parent: { ["input": "composer", "model": "composer"][$0] ?? ($0 == "window" ? nil : "window") },
           isTextArea: { $0 == "input" }, isModelButton: { $0 == "model" }, equals: ==,
           isInterrupted: { interrupt })
        XCTAssertEqual(locator.locate(in: "window", focused: "input", previousComposer: nil)?.composer, "input")
        reads = 0
        interrupt = true // A queued user action arrived while the background poll was walking.
        XCTAssertNil(locator.locate(in: "window", focused: nil, previousComposer: nil))
        XCTAssertLessThan(reads, 40, "The walk must stop within one 32-node check, not finish the window")
    }

    func testSpeedRemembersOnlyAnAttachedPaneWhenANativePickerOwnsFocus() {
        let tree = Tree()
        tree.children["window"] = ["main-region", "side-region", "picker"]
        tree.children["main-region"] = ["main"]
        tree.children["side-region"] = ["side"]
        XCTAssertEqual(tree.locator.conversation(in: "window", focused: "picker", previousComposer: "side-input"), "side-region")
        XCTAssertNil(tree.locator.conversation(in: "window", focused: "picker", previousComposer: nil))
        tree.children["side-region"] = []
        XCTAssertNil(tree.locator.conversation(in: "window", focused: "picker", previousComposer: "side-input"))
    }

    func testSpeedNeverReadsAnEmbeddedBrowsersInputInsideTheCapturedConversation() {
        let nodes = ["window": ["app-web"], "app-web": ["chat-region"],
                     "chat-region": ["browser-web", "input"], "browser-web": ["foreign-input"]]
        var readEmbeddedChildren = false
        let locator = ComposerLocator<String>(children: {
            if $0 == "browser-web" { readEmbeddedChildren = true }
            return nodes[$0] ?? []
        }, parent: { _ in nil }, isTextArea: { $0.hasSuffix("input") }, isModelButton: { _ in false }, equals: ==,
           isWebArea: { $0.hasSuffix("-web") }, isConversationRegion: { $0.hasSuffix("-region") })
        XCTAssertEqual(locator.conversation(in: "window", focused: "input", previousComposer: nil), "chat-region")
        XCTAssertEqual(locator.input(inConversation: "chat-region"), "input")
        XCTAssertNil(locator.conversation(in: "window", focused: "foreign-input", previousComposer: "input"))
        XCTAssertFalse(readEmbeddedChildren)
    }

    func testSpeedPaneDiscoveryNeverReadsModelMetadata() {
        let locator = ComposerLocator<String>(children: { node in
            switch node {
            case "window": return ["chat-region"]
            case "chat-region": return ["input", "model"]
            default: return []
            }
        }, parent: { _ in nil }, isTextArea: { $0 == "input" },
           isModelButton: { _ in XCTFail("Speed must not inspect model metadata"); return false }, equals: ==,
           isConversationRegion: { $0 == "chat-region" })
        XCTAssertEqual(locator.conversation(in: "window", focused: "input", previousComposer: nil), "chat-region")
        XCTAssertEqual(locator.input(inConversation: "chat-region"), "input")
    }

    func testClickedConversationRegionOverridesThePreviouslyUsedOtherPane() {
        let tree = Tree()
        tree.children["window"] = ["main-region", "side-region", "editor"]
        tree.children["main-region"] = ["main"]
        tree.children["side-region"] = ["side"]
        tree.parents["main"] = "main-region"
        tree.parents["side"] = "side-region"
        tree.parents["main-region"] = "window"
        tree.parents["side-region"] = "window"
        for (region, previous, expected) in [("main-region", "side-input", "main-input"),
                                              ("side-region", "main-input", "side-input")] {
            XCTAssertEqual(tree.locator.locate(in: "window", focused: region, previousComposer: previous)?.composer,
                           expected)
        }
    }

    func testClickedRegionUsesLiveChildrenWhenAccessibilityParentsSkipIt() {
        let tree = Tree()
        tree.children["window"] = ["main", "side-region", "editor"]
        tree.children["side-region"] = ["side"]
        tree.parents["side-region"] = "window"
        tree.parents["side"] = "window"
        XCTAssertEqual(tree.locator.locate(in: "window", focused: "side-region", previousComposer: "main-input")?.composer,
                       "side-input")
    }

    func testLoadingClickedRegionCannotFallBackToTheRememberedOtherChat() {
        let tree = Tree()
        tree.children["window"] = ["main", "side-region", "editor"]
        tree.children["side-region"] = ["side"]
        tree.parents["side-region"] = "window"
        tree.models.remove("side-model")
        XCTAssertNil(tree.locator.locate(in: "window", focused: "side-region", previousComposer: "main-input"))
    }

    func testEmptyLoadingConversationCannotReuseTheOtherChat() {
        let tree = Tree()
        tree.children["window"] = ["main", "side-region"]
        tree.children["side-region"] = []
        tree.parents["side-region"] = "window"
        XCTAssertNil(tree.locator.locate(in: "window", focused: "side-region", previousComposer: "main-input"))
    }

    func testSharedFocusedRegionCannotChooseOneOfItsTwoChats() {
        let tree = Tree()
        tree.children["window"] = ["shared-region", "editor"]
        tree.children["shared-region"] = ["main", "side"]
        tree.parents["shared-region"] = "window"
        XCTAssertNil(tree.locator.locate(in: "window", focused: "shared-region", previousComposer: "main-input"))
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

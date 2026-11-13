import CoreGraphics
import XCTest
@testable import CodexModelBarCore

/// Synthetic trees shaped like the AX trees measured from Codex 26.1103 on 2026-11-11.
final class VoiceChatLocatorTests: XCTestCase {
    private struct Node {
        var role = "AXGroup"
        var subrole = ""
        var label = ""
        var classes: [String] = []
        var frame: CGRect?
        var children: [String] = []
    }

    private final class Tree {
        var nodes: [String: Node] = [:]
        var readChildren: Set<String> = []
        func add(_ id: String, _ node: Node) { nodes[id] = node }
        var parents: [String: String] {
            var result: [String: String] = [:]
            for (id, node) in nodes { for child in node.children { result[child] = id } }
            return result
        }
        var locator: VoiceChatLocator<String> {
            let parents = self.parents
            return VoiceChatLocator<String>(
                children: { id in self.readChildren.insert(id); return self.nodes[id]?.children ?? [] },
                parent: { parents[$0] }, role: { self.nodes[$0]?.role ?? "" },
                subrole: { self.nodes[$0]?.subrole ?? "" },
                label: { self.nodes[$0]?.label ?? "" },
                classes: { self.nodes[$0]?.classes ?? [] },
                frame: { self.nodes[$0]?.frame })
        }
    }

    /// The measured overlay: a 306-point pill group whose controls span x 40…250.
    private func overlay(live: Bool = true) -> Tree {
        let tree = Tree()
        tree.add("window", Node(role: "AXWindow", subrole: "AXDialog", children: ["web"]))
        tree.add("web", Node(role: "AXWebArea", children: ["pill", "status"]))
        tree.add("pill", Node(subrole: "AXApplicationGroup", frame: CGRect(x: 0, y: 1311, width: 306, height: 40),
                              children: ["new", "controls", "activity"]))
        tree.add("new", Node(role: "AXButton", label: "Start new chat", frame: CGRect(x: 40, y: 1321, width: 21, height: 20)))
        tree.add("controls", Node(children: live ? ["mic", "stop", "mute"] : ["start"]))
        tree.add("mic", Node(role: "AXCheckBox", label: "Mute microphone", frame: CGRect(x: 79, y: 1312, width: 39, height: 38)))
        tree.add("stop", Node(role: "AXButton", label: "Stop voice chat", frame: CGRect(x: 117, y: 1312, width: 47, height: 38)))
        tree.add("mute", Node(role: "AXCheckBox", label: "Mute voice chat", frame: CGRect(x: 163, y: 1312, width: 39, height: 38)))
        tree.add("start", Node(role: "AXButton", label: "Start voice chat", frame: CGRect(x: 117, y: 1312, width: 47, height: 38)))
        tree.add("activity", Node(role: "AXButton", label: "Show activity, 9 items", frame: CGRect(x: 211, y: 1312, width: 39, height: 38)))
        tree.add("status", Node(subrole: "AXApplicationStatus", frame: CGRect(x: 30, y: 1265, width: 221, height: 38)))
        return tree
    }

    func testLivePillUsesTheUnionOfItsControlsNotThePaddedGroup() {
        let frame = overlay().locator.voicePillFrame(inOverlay: "window")
        XCTAssertEqual(frame, CGRect(x: 40, y: 1312, width: 210, height: 38))
    }

    func testNoPillWithoutAStopVoiceButton() {
        XCTAssertNil(overlay(live: false).locator.voicePillFrame(inOverlay: "window"),
                     "The Quick Chat bar without a live call must not show the jump button")
    }

    /// A main window: a sidebar (complementary landmark) with rows, and a conversation
    /// (main landmark) that must never be read.
    private func window(rows: [(String, Bool)], markerInConversation: Bool = false) -> Tree {
        let tree = Tree()
        tree.add("window", Node(role: "AXWindow", subrole: "AXStandardWindow", children: ["sidebar", "conversation"]))
        tree.add("conversation", Node(subrole: "AXLandmarkMain", children: ["transcript"]))
        tree.add("transcript", Node(children: markerInConversation ? ["stray"] : []))
        tree.add("stray", Node(role: "AXImage", label: "Voice chat active"))
        tree.add("sidebar", Node(subrole: "AXLandmarkComplementary", children: ["list"]))
        var listChildren: [String] = []
        for (index, row) in rows.enumerated() {
            let cell = "cell\(index)", button = "row\(index)", text = "text\(index)", badge = "badge\(index)", marker = "marker\(index)"
            listChildren.append(cell)
            tree.add(cell, Node(children: [button]))
            tree.add(button, Node(role: "AXButton", label: row.0, classes: ["group", "sidebar-item"],
                                  children: row.1 ? [text, badge] : [text]))
            tree.add(text, Node(role: "AXStaticText", label: row.0))
            tree.add(badge, Node(children: [marker]))
            tree.add(marker, Node(role: "AXImage", label: "Voice chat active"))
        }
        tree.add("list", Node(role: "AXList", subrole: "AXContentList", children: listChildren))
        return tree
    }

    func testFindsOnlyTheRowCodexMarksAsTheLiveVoiceChat() {
        let tree = window(rows: [("🗣️ Voice | Old call", false), ("🏢 Company admin | Realivy and ETG", true), ("Realtime Voice Chat", false)])
        let rows = tree.locator.activeVoiceRows(inWindow: "window")
        XCTAssertEqual(rows.map(\.title), ["🏢 Company admin | Realivy and ETG"],
                       "Identity is Codex's live marker, never an older Voice title")
        XCTAssertEqual(rows.first?.row, "row1")
    }

    func testDoesNotReadTheConversationAndIgnoresMarkersOutsideSidebarRows() {
        let tree = window(rows: [("Chat", false)], markerInConversation: true)
        XCTAssertTrue(tree.locator.activeVoiceRows(inWindow: "window").isEmpty)
        XCTAssertFalse(tree.readChildren.contains("conversation"), "The transcript is most of the window's nodes; skip it")
    }

    func testMarkerWithoutASidebarRowIsIgnored() {
        let tree = Tree()
        tree.add("window", Node(role: "AXWindow", children: ["badge"]))
        tree.add("badge", Node(role: "AXButton", label: "Header", children: ["marker"]))
        tree.add("marker", Node(role: "AXImage", label: "Voice chat active"))
        XCTAssertTrue(tree.locator.activeVoiceRows(inWindow: "window").isEmpty,
                      "Only a sidebar-item row may choose a chat")
    }

    // MARK: Resolution

    private func record(_ id: String, _ title: String, name: String? = nil, archived: Bool = false, parent: String? = nil) -> CodexThreadRecord {
        CodexThreadRecord(id: id, name: name, title: title, archived: archived, attachedParentID: parent)
    }

    func testResolvesTheUniqueLiveTopLevelThread() {
        let threads = [record("a", "🏢 Company admin | Realivy and ETG"),
                       record("b", "🏢 Company admin | Realivy and ETG", parent: "a"), // Side chat: shares the title, no row.
                       record("c", "🏢 Company admin | Realivy and ETG", archived: true)]
        XCTAssertEqual(VoiceChatResolver.resolve(activeRowTitles: ["🏢 Company admin | Realivy and ETG"], threads: threads),
                       .thread(id: "a", title: "🏢 Company admin | Realivy and ETG"))
    }

    func testRenamedThreadMatchesByItsShownName() {
        let threads = [record("a", "<realtime_delegation> first message", name: "🗣️ Voice | Dinner"),
                       record("b", "🗣️ Voice | Dinner", name: "Something else")] // Shows "Something else", so it is not a match.
        XCTAssertEqual(VoiceChatResolver.resolve(activeRowTitles: ["🗣️ Voice | Dinner"], threads: threads),
                       .thread(id: "a", title: "🗣️ Voice | Dinner"))
    }

    func testDuplicateNamesRefuseInsteadOfGuessing() {
        let threads = [record("a", "Realtime Voice Chat"), record("b", "Realtime Voice Chat")]
        XCTAssertEqual(VoiceChatResolver.resolve(activeRowTitles: ["Realtime Voice Chat"], threads: threads),
                       .ambiguous(title: "Realtime Voice Chat", count: 2))
    }

    func testRowsFromSeveralWindowsMustAgree() {
        let threads = [record("a", "One"), record("b", "Two")]
        XCTAssertEqual(VoiceChatResolver.resolve(activeRowTitles: ["One", "One"], threads: threads), .thread(id: "a", title: "One"),
                       "Two windows showing the same marked row are one answer")
        XCTAssertEqual(VoiceChatResolver.resolve(activeRowTitles: ["One", "Two"], threads: threads), .conflictingRows(["One", "Two"]))
    }

    func testNoMarkedRowOrNoMatch() {
        XCTAssertEqual(VoiceChatResolver.resolve(activeRowTitles: [], threads: [record("a", "One")]), .noActiveRow)
        XCTAssertEqual(VoiceChatResolver.resolve(activeRowTitles: ["Gone"], threads: [record("a", "One")]),
                       .noMatchingThread(title: "Gone"))
    }

    func testWhitespaceIsComparedTheWayRowsDrawIt() {
        let threads = [record("a", "<realtime_delegation>\n  <input>Hey</input>\n")]
        XCTAssertEqual(VoiceChatResolver.resolve(activeRowTitles: ["<realtime_delegation> <input>Hey</input>"], threads: threads),
                       .thread(id: "a", title: "<realtime_delegation> <input>Hey</input>"))
    }

    // MARK: Link

    func testLinkAcceptsOnlyUUIDs() {
        XCTAssertEqual(CodexThreadLink.url(forThreadID: "01A17F99-E436-7091-9DF5-C083ECA1354C")?.absoluteString,
                       "codex://threads/01a17f99-e436-7091-9df5-c083eca1354c")
        XCTAssertNil(CodexThreadLink.url(forThreadID: "new"), "A database value must never become another codex:// command")
        XCTAssertNil(CodexThreadLink.url(forThreadID: "../settings"))
    }

    // MARK: Placement

    private let screen = CGRect(x: 0, y: 0, width: 3440, height: 1440)

    func testButtonSitsRightOfThePillAndCentredOnIt() {
        // Pill controls from the live measurement: AX y 1311…1351 on a 1440-point display.
        let frame = VoiceJumpPlacement.frame(pill: CGRect(x: 40, y: 1311, width: 210, height: 40),
                                             size: CGSize(width: 32, height: 32), screens: [screen], primaryScreenHeight: 1440)
        XCTAssertEqual(frame, CGRect(x: 258, y: 93, width: 32, height: 32)) // Cocoa: pill spans y 89…129, centre 109.
    }

    func testOverlaySizeCheckAcceptsFullOrVisibleFrameButNotSmallPanels() {
        let screens = [CGSize(width: 3440, height: 1440), CGSize(width: 1920, height: 1080)]
        XCTAssertTrue(VoiceJumpPlacement.isOverlaySized(CGSize(width: 3440, height: 1440), screenSizes: screens))
        XCTAssertTrue(VoiceJumpPlacement.isOverlaySized(CGSize(width: 3440, height: 1385), screenSizes: screens),
                      "A window sized to the visible frame (menu bar and Dock removed) must still count")
        XCTAssertTrue(VoiceJumpPlacement.isOverlaySized(CGSize(width: 1920, height: 1050), screenSizes: screens))
        XCTAssertFalse(VoiceJumpPlacement.isOverlaySized(CGSize(width: 420, height: 300), screenSizes: screens),
                       "Computer Use panels and menus must not be walked every half second")
    }

    func testButtonMovesLeftAtTheScreenEdge() {
        let frame = VoiceJumpPlacement.frame(pill: CGRect(x: 3200, y: 700, width: 230, height: 40),
                                             size: CGSize(width: 32, height: 32), screens: [screen], primaryScreenHeight: 1440)
        XCTAssertEqual(frame?.maxX, 3192, "Right of the pill would leave the screen, so it goes on the left")
    }

    func testPillOnASecondScreenAndOffScreen() {
        let second = CGRect(x: 3440, y: 360, width: 1920, height: 1080)
        let frame = VoiceJumpPlacement.frame(pill: CGRect(x: 3500, y: 0, width: 200, height: 40),
                                             size: CGSize(width: 32, height: 32), screens: [screen, second], primaryScreenHeight: 1440)
        XCTAssertEqual(frame?.minX, 3708)
        XCTAssertNil(VoiceJumpPlacement.frame(pill: CGRect(x: -5000, y: 0, width: 200, height: 40),
                                              size: CGSize(width: 32, height: 32), screens: [screen], primaryScreenHeight: 1440))
    }
}

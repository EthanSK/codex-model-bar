import CoreGraphics
import XCTest
@testable import CodexModelBarCore

/// Synthetic trees shaped like the AX trees measured from Codex 26.1103 on 2026-11-11.
final class VoiceChatLocatorTests: XCTestCase {
    private struct Node {
        var role = "AXGroup"
        var subrole = ""
        var label = ""
        var frame: CGRect?
        var children: [String] = []
    }

    private final class Tree {
        var nodes: [String: Node] = [:]
        func add(_ id: String, _ node: Node) { nodes[id] = node }
        var parents: [String: String] {
            var result: [String: String] = [:]
            for (id, node) in nodes { for child in node.children { result[child] = id } }
            return result
        }
        var locator: VoiceChatLocator<String> {
            let parents = self.parents
            return VoiceChatLocator<String>(
                children: { self.nodes[$0]?.children ?? [] },
                parent: { parents[$0] }, role: { self.nodes[$0]?.role ?? "" },
                subrole: { self.nodes[$0]?.subrole ?? "" },
                label: { self.nodes[$0]?.label ?? "" },
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

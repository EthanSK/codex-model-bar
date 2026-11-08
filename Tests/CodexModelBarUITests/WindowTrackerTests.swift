import XCTest
import CoreGraphics
import AppKit
import CodexModelBarCore
@testable import CodexModelBar

final class WindowTrackerTests: XCTestCase {
    private let mainFrame = CGRect(x: 214, y: 171, width: 1727, height: 915)
    private let previewFrame = CGRect(x: 400, y: 220, width: 800, height: 560)

    func testFrontmostComputerUsePreviewCannotBecomeTheAnchor() {
        let windows = [window(2, frame: previewFrame), window(1, frame: mainFrame)]
        XCTAssertEqual(CodexWindowTracker.chooseWindow(in: windows, pid: 42, mainFrame: mainFrame, needsMainWindow: true)?.0, 1)
        XCTAssertEqual(CodexWindowTracker.chooseWindow(in: windows, pid: 42, mainFrame: mainFrame, needsMainWindow: true)?.1, mainFrame)
    }

    func testNewMainTaskWindowWinsEvenWhenSmallerThanTheOldWindowOrPreview() {
        let newMain = CGRect(x: 50, y: 60, width: 600, height: 400)
        let windows = [window(2, frame: previewFrame), window(1, frame: mainFrame), window(3, frame: newMain)]
        XCTAssertEqual(CodexWindowTracker.chooseWindow(in: windows, pid: 42, mainFrame: newMain, needsMainWindow: true)?.0, 3)
    }

    func testMissingOrOffscreenMainWindowDoesNotFallBackToPreview() {
        let windows = [window(2, frame: previewFrame)]
        XCTAssertNil(CodexWindowTracker.chooseWindow(in: windows, pid: 42, mainFrame: nil, needsMainWindow: true))
        XCTAssertNil(CodexWindowTracker.chooseWindow(in: windows, pid: 42, mainFrame: mainFrame, needsMainWindow: true))
    }

    func testPendingMainWindowLookupKeepsOnlyThePreviouslyIdentifiedVisibleWindow() {
        let windows = [window(2, frame: previewFrame), window(1, frame: mainFrame)]
        let retained = CodexWindowTracker.chooseWindow(in: windows, pid: 42, mainFrame: nil,
                                                       needsMainWindow: true, previousWindowID: 1)
        XCTAssertEqual(retained?.0, 1)
        XCTAssertEqual(retained?.1, mainFrame)
        XCTAssertNil(CodexWindowTracker.chooseWindow(in: windows, pid: 42, mainFrame: nil,
                                                    needsMainWindow: true, previousWindowID: nil))
    }

    func testReadyReplacementWinsImmediatelyOverThePreviousWindow() {
        let replacement = CGRect(x: 50, y: 60, width: 600, height: 400)
        let windows = [window(1, frame: mainFrame), window(2, frame: previewFrame), window(3, frame: replacement)]
        XCTAssertEqual(CodexWindowTracker.chooseWindow(in: windows, pid: 42, mainFrame: replacement,
                                                      needsMainWindow: true, previousWindowID: 1)?.0, 3)
        XCTAssertEqual(CodexWindowTracker.chooseWindow(in: windows, pid: 42, mainFrame: replacement.offsetBy(dx: 10, dy: 0),
                                                      needsMainWindow: true, previousWindowID: 1)?.0, 1)
    }

    func testUnavailablePreviousWindowDoesNotKeepTheBarOverAnotherAppOrPreview() {
        var hidden = window(1, frame: mainFrame)
        hidden[kCGWindowIsOnscreen as String] = false
        var transparent = window(1, frame: mainFrame)
        transparent[kCGWindowAlpha as String] = 0.0
        var floating = window(1, frame: mainFrame)
        floating[kCGWindowLayer as String] = NSWindow.Level.floating.rawValue
        for previous in [nil, hidden, transparent, floating, window(1, frame: mainFrame, pid: 99)] as [[String: Any]?] {
            let infos = [window(2, frame: previewFrame)] + (previous.map { [$0] } ?? [])
            XCTAssertNil(CodexWindowTracker.chooseWindow(in: infos, pid: 42, mainFrame: nil,
                                                        needsMainWindow: true, previousWindowID: 1))
        }
    }

    func testCoordinateRoundingAndUnrelatedOwner() {
        let rounded = mainFrame.offsetBy(dx: 0.5, dy: -0.5)
        let windows = [window(5, frame: mainFrame, pid: 99), window(1, frame: rounded)]
        XCTAssertEqual(CodexWindowTracker.chooseWindow(in: windows, pid: 42, mainFrame: mainFrame, needsMainWindow: true)?.0, 1)
    }

    func testPermissionSetupBarCanStillAppearBeforeAccessibilityIsGranted() {
        XCTAssertEqual(CodexWindowTracker.chooseWindow(in: [window(1, frame: mainFrame)], pid: 42,
                                                      mainFrame: nil, needsMainWindow: false)?.0, 1)
    }

    func testOnlyVisibleAgentFlowFloatingPanelsObstructTheToolbar() {
        var panel = window(9, frame: previewFrame, pid: 99)
        panel[kCGWindowLayer as String] = NSWindow.Level.floating.rawValue + 1
        panel[kCGWindowIsOnscreen as String] = true
        var hidden = panel
        hidden[kCGWindowNumber as String] = CGWindowID(10)
        hidden[kCGWindowIsOnscreen as String] = false
        var transparent = panel
        transparent[kCGWindowAlpha as String] = 0.0
        var unrelated = panel
        unrelated[kCGWindowOwnerPID as String] = pid_t(100)
        var normalWindow = panel
        normalWindow[kCGWindowLayer as String] = 0
        let panels = CodexWindowTracker.agentFlowPanels(in: [normalWindow, hidden, transparent, unrelated, panel], pids: [99])
        XCTAssertEqual(panels.count, 1)
        XCTAssertEqual(panels.first?.0, 9)
        XCTAssertEqual(panels.first?.1, previewFrame)
        XCTAssertTrue(CodexWindowTracker.agentFlowPanels(in: [panel], pids: []).isEmpty)
    }

    func testFlowPanelChangesPublishEvenWhenTheCodexWindowDoesNotMove() {
        let old = CodexWindowTracker.Snapshot(codexPID: 42, windowFrame: mainFrame, codexIsFrontmost: true)
        var next = old
        next.agentFlowPanelFrames = [previewFrame]
        XCTAssertNotEqual(old, next)
        next.agentFlowPanelFrames = []
        XCTAssertEqual(old, next)
    }

    func testShrinkingHudReturnsDirectlyToNormalBeforeItsWindowIsRemoved() {
        let visible = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        let window = CGRect(x: 106, y: 133, width: 1818, height: 1090)
        let natural = CGSize(width: 786, height: 30)
        let normal = BarPlacement.place(window: window, visibleFrame: visible, contentSize: natural)
        var snapshot = CodexWindowTracker.Snapshot(codexPID: 42, windowFrame: window, codexIsFrontmost: true)
        var placed: [CGRect] = []
        for frames in [[CGRect(x: 546, y: 0, width: 963, height: 108)],
                       [CGRect(x: 546, y: 0, width: 963, height: 102)], []] as [[CGRect]] {
            snapshot.agentFlowPanelFrames = frames
            let hud = snapshot.agentFlowHUDFrame(overlapping: normal)
            placed.append(BarPlacement.place(window: window, visibleFrame: visible, contentSize: natural,
                                              agentFlowHUD: hud, obstructingWindows: frames, contentSizeForWidth: { width in
                width >= natural.width ? natural : CGSize(width: width, height: 56)
            }))
        }
        XCTAssertEqual(normal, CGRect(x: 622, y: 103, width: 786, height: 30))
        XCTAssertGreaterThanOrEqual(placed[0].minX, 1513, "A real overlapping HUD still moves the controls to its right")
        XCTAssertEqual(placed[1], normal, "A clear normal strip must not detour left because of Flow's extra four-point margin")
        XCTAssertEqual(placed[2], normal, "Removing the hidden window must keep the same normal placement")
    }

    func testRailAvoidsBothWindowsAtTheScreenEdgeWithoutTakingFocus() throws {
        _ = NSApplication.shared
        let panel = BarPanel()
        defer { panel.close() }
        let visible = CGRect(x: 0, y: 0, width: 1600, height: 1200) // Match the other placement tests: GitHub's smaller physical display cannot contain this fixed 1000×700 Codex fixture plus a 216-point bar, so it correctly reaches the intentional no-space fallback.
        let window = CGRect(x: visible.minX + 100, y: visible.minY + 100, width: 1000, height: 700)
        let flow = CGRect(x: visible.minX + 100, y: visible.minY + 100, width: 800, height: 300)
        for hud in [flow, CGRect(x: visible.maxX - 180, y: visible.minY, width: 180, height: 600), flow] {
            let frame = BarPlacement.place(window: window, visibleFrame: visible,
                                           contentSize: CGSize(width: 142, height: 216), agentFlowHUD: hud)
            panel.place(frame: frame, obstructingWindows: [hud])
            XCTAssertEqual(panel.frame, frame)
            XCTAssertEqual(panel.level, .floating)
            XCTAssertFalse(frame.intersects(window))
            XCTAssertFalse(frame.intersects(hud))
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
        }
    }

    func testLargestOverlappingFlowSurfaceOwnsTheAnchor() {
        var snapshot = CodexWindowTracker.Snapshot(codexPID: 42, windowFrame: mainFrame, codexIsFrontmost: true)
        let hud = CGRect(x: 100, y: 100, width: 1000, height: 300)
        let normalFrame = CGRect(x: 300, y: 140, width: 700, height: 30)
        let smallOverlap = CGRect(x: 300, y: 130, width: 80, height: 80)
        let largerButSeparate = CGRect(x: 1100, y: 500, width: 1400, height: 900)
        snapshot.agentFlowPanelFrames = [smallOverlap, largerButSeparate, hud]
        XCTAssertEqual(snapshot.agentFlowHUDFrame(overlapping: normalFrame), hud)
        snapshot.agentFlowPanelFrames = []
        XCTAssertNil(snapshot.agentFlowHUDFrame(overlapping: normalFrame))
    }

    func testMirroredFlowHUDDoesNotJumpToAnotherDisplayBecauseWindowOrderChanged() {
        let codex = CGRect(x: 1581, y: 161, width: 1829, height: 1207)
        let hud = CGRect(x: 1238, y: 0, width: 963, height: 102)
        let otherDisplay = CGRect(x: 3918, y: 1295, width: 963, height: 102)
        let laptop = CGRect(x: -1346, y: -289, width: 963, height: 102)
        var snapshot = CodexWindowTracker.Snapshot(codexPID: 42, windowFrame: codex, codexIsFrontmost: true)
        for panels in [[otherDisplay, laptop, hud], [laptop, hud, otherDisplay], [hud, otherDisplay, laptop]] {
            snapshot.agentFlowPanelFrames = panels
            XCTAssertEqual(snapshot.agentFlowHUDFrame(overlapping: CGRect(x: 1500, y: 80, width: 700, height: 30)), hud)
        }
    }

    func testCodexFlowAndAccessoryContextRemainVisibleUntilAnotherAppTakesFocus() {
        var snapshot = CodexWindowTracker.Snapshot(codexPID: 42, windowFrame: mainFrame, codexIsFrontmost: true)
        snapshot.agentFlowPanelFrames = [previewFrame]
        var lastDirect: pid_t?
        for (pid, companion, visible) in [(42, false, true), (99, true, true), (100, true, true),
                                           (88, false, false), (99, true, false), (100, true, false),
                                           (42, false, true), (99, true, true)] as [(pid_t, Bool, Bool)] {
            snapshot.updateForeground(pid: pid, isCompanion: companion, lastDirectApplicationPID: &lastDirect)
            XCTAssertEqual(snapshot.shouldShowToolbar, visible, "Foreground PID \(pid)")
            XCTAssertEqual(snapshot.codexIsFrontmost, pid == 42)
        }
        snapshot.agentFlowPanelFrames = []
        XCTAssertTrue(snapshot.shouldShowToolbar, "Keep the old position while Flow's HUD is still opening")
        snapshot.windowFrame = nil
        XCTAssertFalse(snapshot.shouldShowToolbar)
        snapshot.windowFrame = mainFrame
        snapshot.codexPID = nil
        XCTAssertFalse(snapshot.shouldShowToolbar)
    }

    func testVisibleBarDoesNotMoveForASeparateOrRemoteFlowHUD() {
        var snapshot = CodexWindowTracker.Snapshot(codexPID: 42, windowFrame: mainFrame, codexIsFrontmost: false)
        let normalFrame = BarPlacement.place(window: mainFrame, visibleFrame: CGRect(x: 0, y: 0, width: 3440, height: 1440),
                                              contentSize: CGSize(width: 700, height: 30))
        for hud in [CGRect(x: -1300, y: -200, width: 963, height: 200),
                    CGRect(x: normalFrame.maxX + 4, y: normalFrame.minY, width: 963, height: 200),
                    CGRect(x: normalFrame.minX, y: normalFrame.maxY + 4, width: 963, height: 200)] {
            snapshot.agentFlowPanelFrames = [hud]
            XCTAssertNil(snapshot.agentFlowHUDFrame(overlapping: normalFrame))
        }
    }

    func testFlowGrowthMovesTheBarOnlyWhenItReachesTheNormalStripAndShrinkRestoresIt() {
        let visible = CGRect(x: 0, y: 0, width: 2000, height: 1100)
        let window = CGRect(x: 100, y: 300, width: 1500, height: 700)
        let normalFrame = BarPlacement.place(window: window, visibleFrame: visible, contentSize: CGSize(width: 700, height: 30))
        var snapshot = CodexWindowTracker.Snapshot(codexPID: 42, windowFrame: window, codexIsFrontmost: true)
        for height in [200.0, 300.0, 600.0, 200.0] {
            let hud = CGRect(x: 300, y: 0, width: 800, height: height)
            snapshot.agentFlowPanelFrames = [hud]
            let obstructing = snapshot.agentFlowHUDFrame(overlapping: normalFrame)
            XCTAssertEqual(obstructing != nil, height >= 300)
            let placed = BarPlacement.place(window: window, visibleFrame: visible, contentSize: normalFrame.size, agentFlowHUD: obstructing)
            if height < 300 { XCTAssertEqual(placed, normalFrame) }
            else {
                XCTAssertFalse(placed.intersects(window))
                XCTAssertFalse(placed.intersects(hud))
                XCTAssertTrue(visible.contains(placed))
            }
        }
    }

    func testOverlapDecisionUsesTheNormalWidthEvenAfterTheBarWrapsBesideFlow() {
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let window = CGRect(x: 100, y: 300, width: 1000, height: 400)
        let bar = BarView(frame: .zero)
        bar.setModels([CodexModel(id: "astra", displayName: "GPT-6-Astra"),
                       CodexModel(id: "opus", displayName: "Opus 5.5")])
        var snapshot = CodexWindowTracker.Snapshot(codexPID: 42, windowFrame: window, codexIsFrontmost: true)
        let hud = CGRect(x: 100, y: 100, width: 950, height: 250)
        snapshot.agentFlowPanelFrames = [hud]
        var frames: [CGRect] = []
        for _ in 0..<4 {
            bar.availableWidth = visible.width
            let normal = BarPlacement.place(window: window, visibleFrame: visible, contentSize: bar.preferredSize)
            let obstructing = snapshot.agentFlowHUDFrame(overlapping: normal)
            XCTAssertEqual(obstructing, hud)
            bar.availableWidth = visible.maxX - hud.maxX - 4
            XCTAssertGreaterThan(bar.preferredSize.height, 30)
            frames.append(BarPlacement.place(window: window, visibleFrame: visible, contentSize: bar.preferredSize, agentFlowHUD: obstructing))
        }
        XCTAssertTrue(frames.allSatisfy { $0 == frames[0] }, "The moved bar clearing Flow must not make the next update snap back")
    }

    func testEveryStandardWindowGetsABarFrontmostFirstButAPreviewDoesNot() {
        let other = CGRect(x: 2000, y: 100, width: 1000, height: 800)
        let infos = [window(2, frame: previewFrame), window(1, frame: mainFrame), window(3, frame: other)]
        let found = CodexWindowTracker.taskWindows(in: infos, pid: 42, standardWindowFrames: [mainFrame, other],
                                                   chosenWindowID: 1, previousWindowIDs: [])
        XCTAssertEqual(found.map(\.id), [1, 3])
        XCTAssertEqual(found.map(\.bounds), [mainFrame, other])
    }

    func testAMissedAccessibilityReadKeepsKnownWindowsButAddsNoNewOnes() {
        let other = CGRect(x: 2000, y: 100, width: 1000, height: 800)
        let infos = [window(1, frame: mainFrame), window(3, frame: other), window(4, frame: previewFrame)]
        let found = CodexWindowTracker.taskWindows(in: infos, pid: 42, standardWindowFrames: [], chosenWindowID: 1, previousWindowIDs: [3])
        XCTAssertEqual(found.map(\.id), [1, 3])
    }

    func testBeforeAccessibilityOnlyThePermissionBarsWindowIsListed() {
        let other = CGRect(x: 2000, y: 100, width: 1000, height: 800)
        let found = CodexWindowTracker.taskWindows(in: [window(1, frame: mainFrame), window(3, frame: other)], pid: 42,
                                                   standardWindowFrames: [], chosenWindowID: 1, previousWindowIDs: [])
        XCTAssertEqual(found.map(\.id), [1])
    }

    func testAnotherAppCoveringAWindowCountsLikeAnotherCodexWindow() {
        let codex = CGRect(x: 2000, y: 100, width: 1000, height: 800)
        var chrome = window(50, frame: codex.insetBy(dx: 10, dy: 10), pid: 99)
        chrome[kCGWindowLayer as String] = 0
        var floatingHUD = window(51, frame: codex, pid: 98)
        floatingHUD[kCGWindowLayer as String] = NSWindow.Level.floating.rawValue
        let covered = CodexWindowTracker.taskWindows(in: [chrome, window(3, frame: codex)], pid: 42, standardWindowFrames: [codex],
                                                     chosenWindowID: nil, previousWindowIDs: [])
        XCTAssertEqual(covered.first?.isMostlyCovered, true, "A bar must not float over Chrome covering an idle Codex window")
        let clear = CodexWindowTracker.taskWindows(in: [floatingHUD, window(3, frame: codex)], pid: 42, standardWindowFrames: [codex],
                                                   chosenWindowID: nil, previousWindowIDs: [])
        XCTAssertEqual(clear.first?.isMostlyCovered, false, "Flow's floating panels are handled by placement, not hiding")
    }

    func testAReadingFindsItsWindowDespiteRoundingAndIgnoresAnUnlistedWindow() {
        var snapshot = CodexWindowTracker.Snapshot(codexPID: 42, windowFrame: mainFrame, codexIsFrontmost: true)
        let other = CGRect(x: 2000, y: 100, width: 1000, height: 800)
        snapshot.taskWindows = [.init(id: 1, bounds: mainFrame, frame: mainFrame, isMostlyCovered: false),
                                .init(id: 3, bounds: other, frame: other, isMostlyCovered: false)]
        XCTAssertEqual(snapshot.taskWindow(matching: other.offsetBy(dx: 1.5, dy: -1))?.id, 3)
        XCTAssertNil(snapshot.taskWindow(matching: previewFrame))
    }

    func testBarsStayUpWhileTheFocusedWindowIsBeingReplaced() {
        var snapshot = CodexWindowTracker.Snapshot(codexPID: 42, windowFrame: nil, codexIsFrontmost: true)
        XCTAssertFalse(snapshot.shouldShowToolbar)
        snapshot.taskWindows = [.init(id: 3, bounds: mainFrame, frame: mainFrame, isMostlyCovered: false)]
        XCTAssertTrue(snapshot.shouldShowToolbar, "Closing one window must not blink the other window's bar")
    }

    private func window(_ id: CGWindowID, frame: CGRect, pid: pid_t = 42) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1.0,
         kCGWindowIsOnscreen as String: true,
         kCGWindowBounds as String: frame.dictionaryRepresentation]
    }
}

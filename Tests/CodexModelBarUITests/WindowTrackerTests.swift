import XCTest
import CoreGraphics
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

    func testCoordinateRoundingAndUnrelatedOwner() {
        let rounded = mainFrame.offsetBy(dx: 0.5, dy: -0.5)
        let windows = [window(5, frame: mainFrame, pid: 99), window(1, frame: rounded)]
        XCTAssertEqual(CodexWindowTracker.chooseWindow(in: windows, pid: 42, mainFrame: mainFrame, needsMainWindow: true)?.0, 1)
    }

    func testPermissionSetupBarCanStillAppearBeforeAccessibilityIsGranted() {
        XCTAssertEqual(CodexWindowTracker.chooseWindow(in: [window(1, frame: mainFrame)], pid: 42,
                                                      mainFrame: nil, needsMainWindow: false)?.0, 1)
    }

    private func window(_ id: CGWindowID, frame: CGRect, pid: pid_t = 42) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1.0,
         kCGWindowBounds as String: frame.dictionaryRepresentation]
    }
}

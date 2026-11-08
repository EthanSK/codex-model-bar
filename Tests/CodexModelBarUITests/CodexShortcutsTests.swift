// Configured shortcut parsing uses fixture bytes and never posts keyboard input.
import AppKit
import XCTest
@testable import CodexModelBar

final class CodexShortcutsTests: XCTestCase {
    func testRealLayoutLookupFromBackgroundQueueDoesNotCrash() {
        let completed = expectation(description: "AX background shortcut lookup")
        let data = Data(#"[{"command":"composer.toggleFastMode","key":"Ctrl+Shift+S"}]"#.utf8)
        AX.queue.async {
            let shortcut = CodexShortcuts.load(.cycleSpeed, data: data)
            XCTAssertNotNil(shortcut)
            XCTAssertEqual(shortcut?.flags, [.maskControl, .maskShift])
            completed.fulfill()
        }
        wait(for: [completed], timeout: 3)
    }

    func testNullEntriesAndUnsupportedKeysDoNotHideConfiguredReasoningArrows() throws {
        let data = Data(#"[{"command":"other","key":null},{"command":"composer.increaseReasoningEffort","key":"Hyper+F18"},{"command":"composer.increaseReasoningEffort","key":"Command+Control+Option+Shift+F18"},{"command":"composer.increaseReasoningEffort","key":"Ctrl+Command+Up"}]"#.utf8)
        let shortcut = try XCTUnwrap(CodexShortcuts.load(.increaseReasoning, data: data))
        XCTAssertEqual(shortcut.keyCode, 126)
        XCTAssertEqual(shortcut.flags, [.maskControl, .maskCommand])
    }

    func testSpeedLoadsOnlyItsConfiguredChordAndResolvesLetterFromLayout() throws {
        let data = Data(#"[{"command":"composer.toggleFastMode","key":"Ctrl+Command+S"},{"command":"composer.cycleReasoningEffort","key":"Ctrl+Command+R"}]"#.utf8)
        let shortcut = try XCTUnwrap(CodexShortcuts.load(.cycleSpeed, data: data, letterKey: { letter, flags in
            XCTAssertEqual(letter, "s")
            XCTAssertEqual(flags, [.maskControl, .maskCommand])
            return 41 // A fixture layout differs from physical QWERTY S.
        }))
        XCTAssertEqual(shortcut.keyCode, 41)
        XCTAssertEqual(shortcut.flags, [.maskControl, .maskCommand])
    }

    func testDisabledMissingMalformedAndMultiStrokeBindingsNeverInventKeys() {
        for json in ["[]", #"[{"command":"composer.toggleFastMode","key":null}]"#, "broken",
                     #"[{"command":"composer.toggleFastMode","key":"Ctrl+K Ctrl+S"}]"#] {
            XCTAssertNil(CodexShortcuts.load(.cycleSpeed, data: Data(json.utf8), letterKey: { _, _ in 1 }))
        }
    }

    func testFunctionBindingsKeepExistingReasoningCodesAndFlags() throws {
        for (key, code) in [("F18", 79), ("F19", 80)] {
            let shortcut = try XCTUnwrap(CodexShortcuts.parse("Command+Control+Option+Shift+" + key))
            XCTAssertEqual(shortcut.keyCode, CGKeyCode(code))
            XCTAssertEqual(shortcut.flags, [.maskCommand, .maskControl, .maskAlternate, .maskShift])
        }
    }
}

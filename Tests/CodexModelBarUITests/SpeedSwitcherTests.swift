import AppKit
import XCTest
@testable import CodexModelBar
import CodexModelBarCore

final class SpeedSwitcherTests: XCTestCase {
    func testStandardDiscoveryUsesOneUnicodeKeyPair() throws {
        for text in ["/"] {
            let events = try XCTUnwrap(Keyboard.textEvents(text))
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
            for event in events {
                var length = 0
                var units = [UniChar](repeating: 0, count: 32)
                event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
                XCTAssertEqual(String(utf16CodeUnits: units, count: length), text)
            }
        }
    }

    func testPasteShortcutAndReturnMatchAgentFlowInputSources() throws {
        let events = try XCTUnwrap(SpeedCommandPaste.events())
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [55, 9, 9, 55, 36, 36])
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged, .keyDown, .keyUp])
        XCTAssertEqual(events.map(\.flags), [.maskCommand, .maskCommand, .maskCommand, [], [], []])
        let privateStateID = try XCTUnwrap(events.first).getIntegerValueField(.eventSourceStateID)
        XCTAssertNotEqual(privateStateID, Int64(CGEventSourceStateID.hidSystemState.rawValue))
        XCTAssertNotEqual(privateStateID, Int64(CGEventSourceStateID.combinedSessionState.rawValue))
        XCTAssertEqual(events.prefix(4).map { $0.getIntegerValueField(.eventSourceStateID) },
                       Array(repeating: privateStateID, count: 4)) // macOS assigns each private source its own identifier; Command itself produces flagsChanged events.
        XCTAssertEqual(events.suffix(2).map { $0.getIntegerValueField(.eventSourceStateID) },
                       Array(repeating: Int64(CGEventSourceStateID.hidSystemState.rawValue), count: 2))
    }

    func testPasteKeepsTheCommandAvailableToALaggingReader() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old clipboard", forType: .string)
        board.setData(Data([1, 2]), forType: .rtf)
        XCTAssertTrue(SpeedCommandPaste.prepare("/ultrafast", on: board))
        XCTAssertEqual(board.string(forType: .string), "/ultrafast")
        XCTAssertNil(board.data(forType: .rtf))
        let payloadStays = expectation(description: "Payload stays for delayed paste")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(board.string(forType: .string), "/ultrafast")
            board.clearContents()
            board.setString("newer user copy", forType: .string)
            payloadStays.fulfill()
        }
        wait(for: [payloadStays], timeout: 1)
        XCTAssertEqual(board.string(forType: .string), "newer user copy")
    }

    func testCancelledPasteDoesNotChangeTheUserClipboard() {
        let changeCount = NSPasteboard.general.changeCount
        XCTAssertFalse(SpeedCommandPaste.post("/fast", canPost: { false }))
        XCTAssertEqual(NSPasteboard.general.changeCount, changeCount)
    }

    func testReleaseCancelsBothQueuedRatchetsWithoutEnteringTheApp() {
        let switcher = SpeedSwitcher()
        let barrier = DispatchSemaphore(value: 0)
        AX.queue.async { barrier.wait() }
        let cancelled = expectation(description: "Both queued commands cancel")
        cancelled.expectedFulfillmentCount = 2
        for speed in [ResponseSpeed.ultrafast, .fast] {
            switcher.change(.command(speed), allModels: [], codex: .current) { result in
                guard case .cancelled = result else { return XCTFail("Must cancel before any app interaction: \(result)") }
                cancelled.fulfill()
            }
        }
        XCTAssertTrue(switcher.isBusy)
        switcher.cancelMouseCommands()
        barrier.signal()
        wait(for: [cancelled], timeout: 2)
        XCTAssertFalse(switcher.isBusy)
    }

    func testOldQueuedRatchetExpiresWithoutEnteringTheApp() {
        let switcher = SpeedSwitcher()
        let barrier = DispatchSemaphore(value: 0)
        AX.queue.async { barrier.wait() }
        let expired = expectation(description: "Stale command cancels")
        switcher.change(.command(.fast), allModels: [], codex: .current) { result in
            guard case .cancelled = result else { return XCTFail("Must expire before any app interaction: \(result)") }
            expired.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { barrier.signal() }
        wait(for: [expired], timeout: 2)
        XCTAssertFalse(switcher.isBusy)
    }
}

import AppKit
import XCTest
@testable import CodexModelBar
import CodexModelBarCore

final class SpeedSwitcherTests: XCTestCase {
    func testWholeSlashCommandUsesOneUnicodeKeyPair() throws {
        for text in ["/fast", "/ultrafast"] {
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

// Native speed event and queue regression checks; all output goes to inert sinks.
import AppKit
import XCTest
@testable import CodexModelBar
import CodexModelBarCore

final class SpeedSwitcherTests: XCTestCase {
    private let shortcut = CodexShortcuts.Shortcut(keyCode: 41, flags: [.maskControl, .maskShift], isArrow: false)

    @MainActor
    func testActualNativeMenuReceivesLayoutResolvedShortcutWithoutEditingDraft() throws {
        // An unshown AppKit fixture: dispatch production-created events only to
        // this test's menu, never to an app PID, global tap or visible window.
        let target = NativeSpeedMenuTarget()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Cycle speed", action: #selector(NativeSpeedMenuTarget.cycle), keyEquivalent: "s")
        item.keyEquivalentModifierMask = [.control, .shift]
        item.target = target
        menu.addItem(item)
        let draft = NSTextView()
        draft.string = "Review the selected draft"
        draft.setSelectedRange(NSRange(location: 7, length: 3))
        let binding = try XCTUnwrap(CodexShortcuts.parse("Ctrl+Shift+S"))
        XCTAssertTrue(SpeedShortcut.post(binding, count: 1, pid: 12345, canPost: { true }, send: { event, _ in
            guard event.type == .keyDown else { return }
            let native = NSEvent(cgEvent: event)!
            XCTAssertTrue(menu.performKeyEquivalent(with: native))
        }))
        XCTAssertEqual(target.calls, 1)
        XCTAssertEqual(draft.string, "Review the selected draft")
        XCTAssertEqual(draft.selectedRange(), NSRange(location: 7, length: 3))
    }

    func testNativeCyclesContainOnlyConfiguredPairsAndDoNotTouchClipboard() {
        let before = NSPasteboard.general.changeCount
        var sent: [CGEvent] = []
        var waits: [useconds_t] = []
        var destinations: [pid_t] = []
        XCTAssertTrue(SpeedShortcut.post(shortcut, count: 2, pid: 12345, canPost: { true },
                                         send: { sent.append($0); destinations.append($1) }, wait: { waits.append($0) }))
        XCTAssertEqual(sent.map(\.type), [.keyDown, .keyUp, .keyDown, .keyUp])
        XCTAssertEqual(sent.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [41, 41, 41, 41])
        XCTAssertEqual(sent.map(\.flags), Array(repeating: shortcut.flags, count: 4))
        XCTAssertEqual(destinations, Array(repeating: 12345, count: 4))
        XCTAssertEqual(waits, [100_000], "Reuse one existing gap, without extra focus padding")
        for event in sent {
            var length = 0
            event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
            XCTAssertLessThanOrEqual(length, 1, "A native key may expose its letter; never a slash command payload")
            XCTAssertFalse(SpeedSwitcher.isExternalInput(event))
        }
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }

    func testFocusLossReleasesAdmittedKeyAndCancelsRemainingCycles() {
        var allowed = true
        var sent: [CGEvent] = []
        var steps: [Int] = []
        XCTAssertFalse(SpeedShortcut.post(shortcut, count: 2, pid: 12345, canPost: { allowed }, didPostStep: { steps.append($0) },
                                          send: { event, _ in sent.append(event); allowed = false }, wait: { _ in }))
        XCTAssertEqual(sent.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(steps, [0], "Account for the already-posted native step after cancellation")
    }

    func testOneCycleHasNoDeliberateWaitAndCancellationSendsNothing() {
        var count = 0
        XCTAssertTrue(SpeedShortcut.post(shortcut, count: 1, pid: 12345, canPost: { true },
                                         send: { _, _ in count += 1 }, wait: { _ in XCTFail("No pause for one cycle") }))
        XCTAssertEqual(count, 2)
        XCTAssertFalse(SpeedShortcut.post(shortcut, count: 1, pid: 12345, canPost: { false },
                                          send: { _, _ in XCTFail("Cancelled") }))
    }

    func testNewExternalKeysAndClicksStillCancelTheBorrowedFocus() throws {
        for type in [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let event = try XCTUnwrap(CGEvent(source: nil))
            event.type = type
            event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            XCTAssertTrue(SpeedSwitcher.isExternalInput(event))
        }
    }

    func testQuickReleasePreservesFirstRatchetButCancelsLaterQueuedWork() {
        var performed = 0
        let switcher = SpeedSwitcher(performer: { request, _, _, isCurrent in
            XCTAssertTrue(isCurrent())
            guard case .command(.ultrafast) = request else {
                XCTFail("Only the first ratchet may run")
                return .cancelled
            }
            performed += 1
            return .requested(.ultrafast) // Inert sink: never focus or type in a real app.
        })
        let barrier = DispatchSemaphore(value: 0)
        AX.queue.async { barrier.wait() }
        let completed = expectation(description: "First command finishes, later queue cancels")
        completed.expectedFulfillmentCount = 2
        switcher.change(.command(.ultrafast), codex: .current) { result in
            guard case .requested(.ultrafast) = result else { return XCTFail("Quick release lost the first ratchet: \(result)") }
            completed.fulfill()
        }
        switcher.change(.command(.fast), codex: .current) { result in
            guard case .cancelled = result else { return XCTFail("Later queued ratchet must cancel: \(result)") }
            completed.fulfill()
        }
        XCTAssertTrue(switcher.isBusy)
        switcher.cancelMouseCommands()
        barrier.signal()
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(performed, 1)
        XCTAssertFalse(switcher.isBusy)
    }

    func testOldQueuedRatchetExpiresWithoutEnteringTheApp() {
        let switcher = SpeedSwitcher(performer: { _, _, _, _ in
            XCTFail("Even the reserved first ratchet must expire before app interaction")
            return .requested(.fast)
        })
        let barrier = DispatchSemaphore(value: 0)
        AX.queue.async { barrier.wait() }
        let expired = expectation(description: "Stale command cancels")
        switcher.change(.command(.fast), codex: .current) { result in
            guard case .cancelled = result else { return XCTFail("Must expire before any app interaction: \(result)") }
            expired.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { barrier.signal() }
        wait(for: [expired], timeout: 2)
        XCTAssertFalse(switcher.isBusy)
    }
}

@MainActor
private final class NativeSpeedMenuTarget: NSObject {
    var calls = 0
    @objc func cycle() { calls += 1 }
}

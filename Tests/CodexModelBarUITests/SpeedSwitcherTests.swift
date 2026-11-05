import AppKit
import XCTest
@testable import CodexModelBar
import CodexModelBarCore

final class SpeedSwitcherTests: XCTestCase {
    func testPostedTextAndHIDReturnDoNotCancelReturningToTheTypingInput() throws {
        for event in try XCTUnwrap(SpeedCommandPaste.events("/ultrafast")) {
            XCTAssertFalse(SpeedSwitcher.isExternalInput(event))
        }
    }

    func testNewExternalKeysAndClicksCancelTheBorrowedFocus() throws {
        for type in [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let event = try XCTUnwrap(CGEvent(source: nil))
            event.type = type
            event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            XCTAssertTrue(SpeedSwitcher.isExternalInput(event))
        }
        XCTAssertTrue(SpeedSwitcher.isExternalInput(nil))
    }

    func testCompleteUnicodeCommandAndHIDReturnNeverSendCommandV() throws {
        let events = try XCTUnwrap(SpeedCommandPaste.events("/ultrafast"))
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [0, 0, 36, 36])
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp, .keyDown, .keyUp])
        XCTAssertEqual(events.map(\.flags), [[], [], [], []])
        for event in events.prefix(2) {
            var count = 0
            event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &count, unicodeString: nil)
            var units = [UniChar](repeating: 0, count: count)
            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
            XCTAssertEqual(String(decoding: units, as: UTF16.self), " /ultrafast")
        }
        let privateStateID = try XCTUnwrap(events.first).getIntegerValueField(.eventSourceStateID)
        XCTAssertNotEqual(privateStateID, Int64(CGEventSourceStateID.hidSystemState.rawValue))
        XCTAssertNotEqual(privateStateID, Int64(CGEventSourceStateID.combinedSessionState.rawValue))
        XCTAssertEqual(events.prefix(2).map { $0.getIntegerValueField(.eventSourceStateID) },
                       Array(repeating: privateStateID, count: 2))
        XCTAssertEqual(events.suffix(2).map { $0.getIntegerValueField(.eventSourceStateID) },
                       Array(repeating: Int64(CGEventSourceStateID.hidSystemState.rawValue), count: 2))
    }

    func testSuccessfulTextDeliveryDoesNotTouchTheUserClipboard() {
        let changeCount = NSPasteboard.general.changeCount
        var sent: [CGEvent] = []
        var waits: [useconds_t] = []
        XCTAssertTrue(SpeedCommandPaste.post("/ultrafast", canPost: { true },
                                            send: { sent.append($0) }, wait: { waits.append($0) }))
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(waits, [100_000, 10_000, 100_000, 30_000])
        XCTAssertEqual(NSPasteboard.general.changeCount, changeCount)
    }

    func testCancelledTextDoesNotChangeTheUserClipboard() {
        let changeCount = NSPasteboard.general.changeCount
        XCTAssertFalse(SpeedCommandPaste.post("/fast", canPost: { false }))
        XCTAssertEqual(NSPasteboard.general.changeCount, changeCount)
    }

    func testLostFocusSuppressesReturnButStillReleasesTheTextKey() {
        var allowed = true
        var sent: [CGEvent] = []
        XCTAssertFalse(SpeedCommandPaste.post("/fast", canPost: { allowed },
                                             send: { sent.append($0); allowed = false }, wait: { _ in }))
        XCTAssertEqual(sent.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(sent.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [0, 0])
    }

    func testEachToggleWaitsAfterFocusAndBeforeOneReturn() {
        for command in ["/fast", "/ultrafast"] {
            for _ in 0..<2 { // The second identical command is the requested toggle OFF.
                var sequence: [String] = []
                XCTAssertTrue(SpeedCommandPaste.post(command, canPost: { true }, send: {
                    sequence.append("\($0.getIntegerValueField(.keyboardEventKeycode)):\($0.type.rawValue)")
                }, wait: { sequence.append("wait:\($0)") }))
                XCTAssertEqual(sequence, ["wait:100000", "0:10", "wait:10000", "0:11", "wait:100000",
                                          "36:10", "wait:30000", "36:11"],
                               "Focus settles before one whole command and one Enter, without a result check or retry")
            }
        }
    }

    func testLosingKeyboardOwnershipDuringFocusDelaySendsNothing() {
        var allowed = true
        var waits: [useconds_t] = []
        var sent: [CGEvent] = []
        XCTAssertFalse(SpeedCommandPaste.post("/ultrafast", canPost: { allowed },
                                             send: { sent.append($0) }, wait: {
            waits.append($0)
            allowed = false
        }))
        XCTAssertEqual(waits, [100_000])
        XCTAssertTrue(sent.isEmpty, "Do not type into a different app if focus changes during the settling delay")
    }

    func testSpeedTextMatchesCodexInlineCommandBoundaryWithExistingDrafts() throws {
        // The installed Codex composer's actual suggestion pattern (Fj/Uj).
        // Its match is on text BEFORE the caret; the suggestion consumes only
        // the trigger and query, not the draft or the separating whitespace.
        let matcher = try NSRegularExpression(pattern: #"(?:^|\s)([/@$])([\p{L}\p{N}\p{M}.:_/\\-]*)$"#)
        for command in ["/fast", "/ultrafast"] {
            for draft in ["", "review", "review.", "review ", "review\n", "🦀 café", "https://example.com/path"] {
                let text = draft + SpeedCommandPaste.payload(command)
                let match = try XCTUnwrap(matcher.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), text)
                XCTAssertEqual((text as NSString).substring(with: match.range(at: 1)), "/")
                XCTAssertEqual((text as NSString).substring(with: match.range(at: 2)), String(command.dropFirst()))
                let consumed = NSRange(location: match.range(at: 1).location,
                                       length: command.utf16.count)
                XCTAssertEqual((text as NSString).replacingCharacters(in: consumed, with: ""), draft + " ")
            }
        }
        XCTAssertNil(matcher.firstMatch(in: "review/fast", range: NSRange(location: 0, length: 11)),
                     "The reported old concatenation must reproduce a missing command suggestion")
    }

    func testTextAtMiddleCaretPreservesTheFollowingDraftText() throws {
        let beforeCaret = "review", afterCaret = " the changes"
        for command in ["/fast", "/ultrafast"] {
            let payload = SpeedCommandPaste.payload(command)
            XCTAssertEqual(beforeCaret + payload + afterCaret,
                           "review " + command + " the changes")
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

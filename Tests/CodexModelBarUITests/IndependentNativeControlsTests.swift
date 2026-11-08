import AppKit
import XCTest
@testable import CodexNativeControls

final class IndependentNativeControlsTests: XCTestCase {
    func testAllCommandsUseTheEmbeddedEngineWithoutAnyURLHandler() {
        let done = expectation(description: "Native requests complete without a Model Bar app")
        done.expectedFulfillmentCount = 3
        var commands: [CodexShortcuts.Command] = []
        let engine = CodexShortcutController(performer: { command, source, _, _, current in
            XCTAssertTrue(current()); XCTAssertEqual(source, .mouse)
            commands.append(command)
            return .requested
        })
        for command in [CodexShortcuts.Command.cycleSpeed, .increaseReasoning, .decreaseReasoning] {
            engine.change(command, source: .mouse, codex: .current) { result in
                guard case .requested = result else { return XCTFail("Native request cancelled") }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(commands, [.cycleSpeed, .increaseReasoning, .decreaseReasoning])
        XCTAssertFalse(engine.isBusy)
    }

    func testLockAfterAdmissionCancelsEvenTheReservedFirstRequest() {
        var allowed = true
        let engine = CodexShortcutController(inputAllowed: { allowed }, performer: { _, _, _, _, _ in
            XCTFail("A reserved request must never bypass the host session gate")
            return .requested
        })
        let barrier = DispatchSemaphore(value: 0)
        CodexAX.queue.async { barrier.wait() }
        let done = expectation(description: "Lock cancels reserved work")
        engine.change(.cycleSpeed, source: .mouse, codex: .current) { result in
            guard case .cancelled = result else { return XCTFail("Lock must cancel") }
            done.fulfill()
        }
        allowed = false; barrier.signal()
        wait(for: [done], timeout: 2)
        XCTAssertFalse(engine.isBusy)
    }

    func testReleaseCancelsOnlyItsCommandFamilyAndPreservesBothFirstRatchets() {
        var commands: [CodexShortcuts.Command] = []
        let engine = CodexShortcutController(performer: { command, _, _, _, current in
            XCTAssertTrue(current()); commands.append(command); return .requested
        })
        let barrier = DispatchSemaphore(value: 0)
        CodexAX.queue.async { barrier.wait() }
        let done = expectation(description: "Separate speed/reasoning cancellation")
        done.expectedFulfillmentCount = 3
        for command in [CodexShortcuts.Command.cycleSpeed, .cycleSpeed, .increaseReasoning] {
            engine.change(command, source: .mouse, codex: .current) { _ in done.fulfill() }
        }
        engine.cancelMouse(.speed); barrier.signal()
        wait(for: [done], timeout: 2)
        XCTAssertEqual(commands, [.cycleSpeed, .increaseReasoning])
    }
}

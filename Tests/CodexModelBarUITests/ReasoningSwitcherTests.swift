import AppKit
import XCTest
@testable import CodexModelBar
import CodexModelBarCore

final class ReasoningSwitcherTests: XCTestCase {
    func testMouseRatchetsMoveOnlyOneLiveModelLevel() {
        let model = CodexModel(id: "active", displayName: "Active",
                               supportedEfforts: ["low", "medium", "high", "max"])
        for current in model.supportedEfforts.indices {
            XCTAssertEqual(ReasoningSwitcher.Request.increase.targetIndex(in: model, from: current),
                           min(current + 1, 3))
            XCTAssertEqual(ReasoningSwitcher.Request.decrease.targetIndex(in: model, from: current),
                           max(current - 1, 0))
        }
        let otherModel = CodexModel(id: "other", displayName: "Other", supportedEfforts: ["low", "max"])
        XCTAssertEqual(ReasoningSwitcher.Request.increase.targetIndex(in: otherModel, from: 0), 1)
        XCTAssertNil(ReasoningSwitcher.Request.increase.targetIndex(in: otherModel, from: 2))
        XCTAssertNil(ReasoningSwitcher.Request.decrease.targetIndex(in: otherModel, from: -1))
    }

    func testSliderRetainsItsExactTargetAndModelBoundary() {
        let model = CodexModel(id: "active", displayName: "Active", supportedEfforts: ["low", "high", "max"])
        XCTAssertEqual(ReasoningSwitcher.Request.select("max", modelID: "active").targetIndex(in: model, from: 0), 2)
        XCTAssertNil(ReasoningSwitcher.Request.select("max", modelID: "stale").targetIndex(in: model, from: 0))
        XCTAssertNil(ReasoningSwitcher.Request.select("unsupported", modelID: "active").targetIndex(in: model, from: 0))
    }

    func testReleaseCancelsQueuedReasoningRatchetsBeforeAppInteraction() {
        let switcher = ReasoningSwitcher()
        let barrier = DispatchSemaphore(value: 0)
        AX.queue.async { barrier.wait() }
        let cancelled = expectation(description: "Both queued directions cancel")
        cancelled.expectedFulfillmentCount = 2
        for request in [ReasoningSwitcher.Request.increase, .decrease] {
            switcher.change(request, allModels: [], codex: .current) { result in
                guard case .cancelled = result else { return XCTFail("Unexpected app interaction: \(result)") }
                cancelled.fulfill()
            }
        }
        XCTAssertTrue(switcher.isBusy)
        switcher.cancelMouseCommands()
        barrier.signal()
        wait(for: [cancelled], timeout: 2)
        XCTAssertFalse(switcher.isBusy)
    }

    func testStaleQueuedReasoningRatchetExpiresBeforeAppInteraction() {
        let switcher = ReasoningSwitcher()
        let barrier = DispatchSemaphore(value: 0)
        AX.queue.async { barrier.wait() }
        let expired = expectation(description: "Old ratchet cancels")
        switcher.change(.increase, allModels: [], codex: .current) { result in
            guard case .cancelled = result else { return XCTFail("Unexpected app interaction: \(result)") }
            expired.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { barrier.signal() }
        wait(for: [expired], timeout: 2)
        XCTAssertFalse(switcher.isBusy)
    }
}

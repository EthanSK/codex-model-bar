import XCTest
@testable import CodexModelBar
import CodexModelBarCore

final class CurrentModelWatcherTests: XCTestCase {
    func testFocusChangeDiscardsSlowOldReadAndCoalescesRefreshes() {
        let started = expectation(description: "Old read started")
        let delivered = expectation(description: "New context delivered")
        let release = DispatchSemaphore(value: 0)
        var reads = 0 // reader runs only on the serial AX queue
        let watcher = CurrentModelWatcher(readSelection: { _, _, force in
            reads += 1
            if reads == 1 {
                started.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return CurrentSelection(modelID: "old", effort: "low")
            }
            XCTAssertTrue(force)
            return CurrentSelection(modelID: "new", effort: "xhigh")
        }, isTrusted: { true }, observesFocus: false)
        watcher.onChange = { selection in
            XCTAssertEqual(selection, CurrentSelection(modelID: "new", effort: "xhigh"))
            delivered.fulfill()
        }
        let models = [CodexModel(id: "old", displayName: "Old"), CodexModel(id: "new", displayName: "New")]
        watcher.update(pid: 101, models: models)
        wait(for: [started], timeout: 2)
        for _ in 0..<10 { watcher.refreshSoon() }
        release.signal()
        wait(for: [delivered], timeout: 2)
        watcher.update(pid: nil, models: models)
        XCTAssertEqual(reads, 2, "Focus refreshes must not build a backlog of old AX reads")
    }

    func testReadFromBeforeAnInteractionCannotOverwriteItsSelection() {
        let started = expectation(description: "Read started")
        let delivered = expectation(description: "Post-switch state delivered")
        let release = DispatchSemaphore(value: 0)
        var reads = 0
        let watcher = CurrentModelWatcher(readSelection: { _, _, _ in
            reads += 1
            if reads == 1 {
                started.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return CurrentSelection(modelID: "sol", effort: "low")
            }
            return CurrentSelection(modelID: "sol", effort: "max")
        }, isTrusted: { true }, observesFocus: false)
        watcher.onChange = { selection in
            XCTAssertEqual(selection.effort, "max")
            delivered.fulfill()
        }
        let models = [CodexModel(id: "sol", displayName: "Sol")]
        watcher.update(pid: 101, models: models)
        wait(for: [started], timeout: 2)
        watcher.setSuspended(true)
        watcher.setSuspended(false)
        release.signal()
        wait(for: [delivered], timeout: 2)
        watcher.update(pid: nil, models: models)
    }
}

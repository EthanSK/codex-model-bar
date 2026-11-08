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
                return (CurrentSelection(modelID: "old", effort: "low"), nil)
            }
            XCTAssertTrue(force)
            return (CurrentSelection(modelID: "new", effort: "xhigh"), nil)
        }, isTrusted: { true }, observesFocus: false)
        watcher.onChange = { selection, _ in
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
                return (CurrentSelection(modelID: "sol", effort: "low"), nil)
            }
            return (CurrentSelection(modelID: "sol", effort: "max"), nil)
        }, isTrusted: { true }, observesFocus: false)
        watcher.onChange = { selection, _ in
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
    func testSavedFastPublishesEvenWhenItsSvgIsHiddenFromAccessibility() {
        let values: [CurrentSelection] = [
            .init(modelID: "sol", effort: "high", speedIconVisible: false, savedSpeed: .standard),
            .init(modelID: "sol", effort: "high", speedIconVisible: false, savedSpeed: .fast),
            .init(modelID: "sol", effort: "high", speedIconVisible: true, savedSpeed: .ultrafast),
        ]
        var index = 0
        var reported: [CurrentSelection] = []
        let delivered = expectation(description: "All three observed speeds")
        delivered.expectedFulfillmentCount = 3
        let models = [CodexModel(id: "sol", displayName: "Sol")]
        let watcher = CurrentModelWatcher(readSelection: { _, _, _ in
            defer { index += 1 }
            return (values[min(index, values.count - 1)], nil)
        }, isTrusted: { true }, observesFocus: false)
        watcher.onChange = { selection, _ in
            reported.append(selection); delivered.fulfill()
            if reported.count < values.count { watcher.refreshSoon() }
            else { watcher.update(pid: nil, models: models) }
        }
        watcher.update(pid: 101, models: models)
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(reported, values)
    }

    func testTheSameSelectionInAnotherWindowStillReportsSoThatWindowsBarUpdates() {
        let windows = [CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 900, y: 0, width: 800, height: 600)]
        let selection = CurrentSelection(modelID: "sol", effort: "high")
        var index = 0
        var reported: [CGRect?] = []
        let delivered = expectation(description: "A reading from each window")
        delivered.expectedFulfillmentCount = 2
        let models = [CodexModel(id: "sol", displayName: "Sol")]
        let watcher = CurrentModelWatcher(readSelection: { _, _, _ in
            defer { index += 1 }
            return (selection, windows[min(index, windows.count - 1)])
        }, isTrusted: { true }, observesFocus: false)
        watcher.onChange = { reading, windowBounds in
            XCTAssertEqual(reading, selection)
            reported.append(windowBounds); delivered.fulfill()
            if reported.count < windows.count { watcher.refreshSoon() }
            else { watcher.update(pid: nil, models: models) }
        }
        watcher.update(pid: 101, models: models)
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(reported, windows)
    }
}

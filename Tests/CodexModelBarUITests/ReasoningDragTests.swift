import AppKit
import XCTest
@testable import CodexModelBar
import CodexModelBarCore

final class ReasoningDragTests: XCTestCase {
    func testDragPreviewsEachTickAndCommitsOnlyOnRelease() throws {
        let bar = makeBar()
        let slider = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSSlider }.first)
        let label = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSTextField }.first)
        var commits: [String] = []
        bar.onSelectEffort = { commits.append($0) }
        let width = bar.preferredWidth

        slider.mouseDown(with: event(.leftMouseDown, tick: 0, slider: slider))
        slider.mouseDragged(with: event(.leftMouseDragged, tick: 1, slider: slider))
        XCTAssertEqual(label.stringValue, "Reasoning High")
        XCTAssertTrue(commits.isEmpty)
        slider.mouseDragged(with: event(.leftMouseDragged, tick: 2, slider: slider))
        XCTAssertEqual(label.stringValue, "Reasoning Max")
        XCTAssertTrue(commits.isEmpty)
        slider.mouseUp(with: event(.leftMouseUp, tick: 2, slider: slider))
        XCTAssertEqual(commits, ["max"])
        XCTAssertEqual(bar.preferredWidth, width)
    }

    func testFocusOrModelChangeDuringDragCancelsCommit() throws {
        for changeModel in [false, true] {
            let bar = makeBar()
            let slider = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSSlider }.first)
            var commits: [String] = []
            bar.onSelectEffort = { commits.append($0) }
            slider.mouseDown(with: event(.leftMouseDown, tick: 0, slider: slider))
            slider.mouseDragged(with: event(.leftMouseDragged, tick: 2, slider: slider))
            if changeModel {
                bar.setCurrentSelection(CurrentSelection(modelID: "other", effort: "high"))
            } else {
                bar.cancelReasoningPreview()
            }
            slider.mouseUp(with: event(.leftMouseUp, tick: 2, slider: slider))
            XCTAssertTrue(commits.isEmpty)
            let label = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSTextField }.first)
            XCTAssertEqual(label.stringValue, changeModel ? "Reasoning High" : "Reasoning Low")
        }
    }

    private func makeBar() -> BarView {
        let bar = BarView(frame: NSRect(x: 0, y: 0, width: 600, height: BarView.height))
        let models = ["main", "other"].map {
            CodexModel(id: $0, displayName: $0, supportedEfforts: ["low", "high", "max"])
        }
        bar.setCatalogModels(models)
        bar.setModels(models)
        bar.setCurrentSelection(CurrentSelection(modelID: "main", effort: "low"))
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private func event(_ type: NSEvent.EventType, tick: Int, slider: NSSlider) -> NSEvent {
        let local = NSPoint(x: slider.rectOfTickMark(at: tick).midX, y: slider.bounds.midY)
        return NSEvent.mouseEvent(with: type, location: slider.convert(local, to: nil),
                                 modifierFlags: [], timestamp: 0, windowNumber: 0,
                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}

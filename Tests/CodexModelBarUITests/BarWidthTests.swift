import AppKit
import XCTest
@testable import CodexModelBar
import CodexModelBarCore

final class BarWidthTests: XCTestCase {
    func testEveryModelSurvivesNarrowLayoutAndStatusChanges() {
        let bar = BarView(frame: NSRect(x: 0, y: 0, width: 640, height: BarView.height))
        let models = ["GPT-6-Astra", "GPT-6-Sol", "Opus 5.5", "Fable 5.1"].map {
            CodexModel(id: $0, displayName: $0, supportedEfforts: ["low", "high", "xhigh"])
        }
        bar.setCatalogModels(models)
        bar.setModels(models)
        let naturalWidth = bar.preferredWidth
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        for width in [naturalWidth, 480, naturalWidth, 900, naturalWidth] {
            bar.frame.size.width = width
            for status in [nil, "Codex did not confirm the new reasoning level", nil] as [String?] {
                bar.showStatus(status)
                bar.layoutSubtreeIfNeeded()
                let buttons = descendants(bar).compactMap { $0 as? ModelButton }
                XCTAssertEqual(buttons.count, models.count, "Detached buttons at width \(width)")
                for button in buttons {
                    let rect = bar.convert(button.bounds, from: button)
                    XCTAssertGreaterThan(rect.width, 12, "Collapsed \(button.model.id)")
                    XCTAssertGreaterThanOrEqual(rect.minX, -0.5)
                    XCTAssertLessThanOrEqual(rect.maxX, width + 0.5)
                }
                XCTAssertEqual(bar.preferredWidth, naturalWidth, accuracy: 0.5)
            }
        }
    }

    func testModelAndReasoningChangesKeepPreferredWidth() {
        let bar = BarView(frame: NSRect(x: 0, y: 0, width: 800, height: BarView.height))
        let models = [
            CodexModel(id: "gpt-6-sol", displayName: "GPT-6-Sol",
                       supportedEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            CodexModel(id: "claude-opus-5-5", displayName: "Opus 5.5",
                       supportedEfforts: ["low", "medium", "high", "xhigh", "max"]),
        ]
        bar.setCatalogModels(models)
        bar.setModels(models)
        bar.setCurrentSelection(CurrentSelection(modelID: models[0].id, effort: "low"))
        let width = bar.preferredWidth

        for model in models {
            for effort in model.supportedEfforts {
                bar.setCurrentSelection(CurrentSelection(modelID: model.id, effort: effort))
                XCTAssertEqual(bar.preferredWidth, width, accuracy: 0.5,
                               "Bar width changed for \(model.id) \(effort)")
            }
        }
        bar.setBusyReasoning(true)
        XCTAssertEqual(bar.preferredWidth, width, accuracy: 0.5)
        bar.setBusyReasoning(false)
        XCTAssertEqual(bar.preferredWidth, width, accuracy: 0.5)
    }
}

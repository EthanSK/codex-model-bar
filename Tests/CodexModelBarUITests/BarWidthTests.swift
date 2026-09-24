import AppKit
import XCTest
@testable import CodexModelBar
import CodexModelBarCore

final class BarWidthTests: XCTestCase {
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

import AppKit
import XCTest
@testable import CodexModelBar
import CodexModelBarCore

final class BarWidthTests: XCTestCase {
    func testRealControlsStayBelowCodexToTheRightOfTheBottomFlowPanel() {
        let bar = BarView(frame: .zero)
        bar.setModels(["GPT-6-Astra", "Opus 5.5", "Fable 5.1", "GPT-6.1-Sol", "GPT-6.1 Terra"].map {
            CodexModel(id: $0, displayName: $0, supportedEfforts: ["low", "high", "xhigh"])
        })
        let screen = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        let window = CGRect(x: 120, y: 130, width: 1818, height: 1090)
        let flow = CGRect(x: 420, y: 25, width: 950, height: 135)
        bar.availableWidth = screen.width
        let natural = bar.preferredSize
        let placed = BarPlacement.place(window: window, visibleFrame: screen, contentSize: natural,
                                         agentFlowHUD: flow, contentSizeForWidth: { width in
            bar.availableWidth = width
            return bar.preferredSize
        })
        bar.availableWidth = placed.width
        bar.frame.size = placed.size
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(placed.maxY, window.minY)
        XCTAssertGreaterThanOrEqual(placed.minX, flow.maxX + 4)
        XCTAssertFalse(placed.intersects(window))
        XCTAssertFalse(placed.intersects(flow))
        XCTAssertTrue(screen.contains(placed))
        XCTAssertEqual(bar.preferredSize, placed.size)
        for control in bar.subviews where !control.isHidden && control is NSControl {
            XCTAssertTrue(bar.bounds.contains(control.frame))
        }
    }

    func testClearPlacementMeasuresRealControlsAndResetsTheSelectedWidth() {
        let bar = BarView(frame: .zero)
        bar.setModels(["GPT-6-Astra", "GPT-6.1-Sol", "Opus 5.5", "Fable 5.1"].map {
            CodexModel(id: $0, displayName: $0, supportedEfforts: ["low", "high", "xhigh"])
        })
        let screen = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let cases = [(CGRect(x: 700, y: 0, width: 700, height: 900), CGRect(x: 300, y: 0, width: 400, height: 900)),
                     (CGRect(x: 0, y: 0, width: 700, height: 900), CGRect(x: 700, y: 0, width: 400, height: 900)),
                     (CGRect(x: 100, y: 400, width: 1100, height: 300), CGRect(x: 200, y: 200, width: 900, height: 300))]
        for (window, flow) in cases {
            bar.availableWidth = screen.width
            let placed = BarPlacement.place(window: window, visibleFrame: screen, contentSize: bar.preferredSize,
                                             agentFlowHUD: flow, contentSizeForWidth: { width in
                bar.availableWidth = width
                return bar.preferredSize
            })
            bar.availableWidth = placed.width
            bar.frame.size = placed.size
            bar.layoutSubtreeIfNeeded()
            XCTAssertEqual(bar.preferredSize, placed.size, "Do not draw at the last rejected candidate's width")
            XCTAssertFalse(placed.intersects(window))
            XCTAssertFalse(placed.intersects(flow))
            XCTAssertTrue(screen.contains(placed))
            for control in bar.subviews where !control.isHidden && control is NSControl {
                XCTAssertTrue(bar.bounds.contains(control.frame), "A readable control must stay inside the selected clear region")
            }
        }
    }

    func testControlsWrapOnlyBelowNaturalWidthAndStayReadableDuringStatusChanges() {
        let bar = BarView(frame: .zero)
        let models = ["GPT-6-Astra", "GPT-6-Sol", "Opus 5.5", "Fable 5.1"].map {
            CodexModel(id: $0, displayName: $0, supportedEfforts: ["low", "high", "xhigh"])
        }
        bar.setCatalogModels(models)
        bar.setModels(models)
        let naturalWidth = bar.preferredWidth
        bar.frame.size = bar.preferredSize
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        for availableWidth in [naturalWidth + 40, naturalWidth, naturalWidth - 1, 320, 180, 0, naturalWidth] {
            bar.availableWidth = availableWidth
            bar.frame.size = bar.preferredSize
            let width = bar.frame.width
            let size = bar.preferredSize
            XCTAssertEqual(size.height == 30, availableWidth >= naturalWidth)
            if availableWidth >= 180 { XCTAssertLessThanOrEqual(width, availableWidth) }
            for status in [nil, "Codex did not confirm the new reasoning level", nil] as [String?] {
                bar.showStatus(status)
                bar.layoutSubtreeIfNeeded()
                XCTAssertFalse(bar.subviews.compactMap { $0 as? NSSlider }.first!.isHidden,
                               "A status message must never replace the reasoning slider")
                XCTAssertFalse(bar.subviews.compactMap { $0 as? NSTextField }.first!.isHidden)
                let buttons = descendants(bar).compactMap { $0 as? ModelButton }
                let speeds = descendants(bar).compactMap { $0 as? NSButton }.filter {
                    $0.accessibilityLabel()?.hasSuffix(" speed") == true
                }
                XCTAssertEqual(speeds.count, 1)
                for button in speeds {
                    let rect = bar.convert(button.bounds, from: button)
                    XCTAssertEqual(rect.width, 24)
                    XCTAssertGreaterThanOrEqual(rect.minX, 0)
                    XCTAssertLessThanOrEqual(rect.maxX, width)
                    for modelButton in buttons {
                        XCTAssertFalse(rect.intersects(bar.convert(modelButton.bounds, from: modelButton)))
                    }
                }
                let visibleControls = bar.subviews.filter { !$0.isHidden && ($0 is NSControl) }
                for (index, control) in visibleControls.enumerated() {
                    XCTAssertTrue(bar.bounds.contains(control.frame), "Clipped control \(control)")
                    for other in visibleControls.dropFirst(index + 1) {
                        XCTAssertFalse(control.frame.intersects(other.frame), "Overlapping controls")
                    }
                }
                XCTAssertEqual(buttons.count, models.count, "Detached buttons at width \(width)")
                for button in buttons {
                    let rect = bar.convert(button.bounds, from: button)
                    XCTAssertEqual(rect.width, button.intrinsicContentSize.width, "Shrank \(button.model.id)")
                    XCTAssertGreaterThanOrEqual(rect.minX, -0.5)
                    XCTAssertLessThanOrEqual(rect.maxX, width + 0.5)
                }
                XCTAssertEqual(bar.preferredWidth, naturalWidth, accuracy: 0.5)
                XCTAssertEqual(bar.preferredSize, size, "Status text must not change wrapping")
            }
        }
    }

    func testSideSpaceCanGrowAndRestoreOneHorizontalRow() {
        let bar = BarView(frame: .zero)
        bar.setModels([CodexModel(id: "sol", displayName: "GPT-6.1-Sol")])
        let original = bar.preferredSize
        XCTAssertEqual(original.height, 30)
        bar.availableWidth = original.width / 2
        XCTAssertLessThan(bar.preferredSize.width, original.width)
        XCTAssertGreaterThan(bar.preferredSize.height, original.height)
        bar.availableWidth = original.width + 40
        XCTAssertEqual(bar.preferredSize, original)
        bar.availableWidth = nil
        XCTAssertEqual(bar.preferredSize, original)
    }

    func testCompletedSpeedNoticeLeavesReasoningAvailableImmediately() throws {
        let bar = BarView(frame: .zero)
        let model = CodexModel(id: "sol", displayName: "Sol", supportedEfforts: ["low", "high", "max"])
        bar.setCatalogModels([model])
        bar.setModels([model])
        bar.setCurrentSelection(CurrentSelection(modelID: model.id, effort: "high"))
        let slider = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSSlider }.first)
        bar.frame.size = bar.preferredSize
        bar.layoutSubtreeIfNeeded()
        let frame = slider.frame
        bar.setBusySpeed(true)
        XCTAssertFalse(slider.isEnabled, "An in-flight speed command still owns the input")
        bar.showStatus("Requested Ultrafast", sticky: true)
        bar.setBusySpeed(false)
        bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(slider.isEnabled)
        XCTAssertFalse(slider.isHidden)
        XCTAssertEqual(slider.frame, frame)
        var selected: [String] = []
        bar.onSelectEffort = { selected.append($0) }
        slider.doubleValue = 2
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        XCTAssertEqual(selected, ["max"])
        bar.showStatus(nil)
    }

    func testReasoningLabelAndSliderStayTogetherUntilEvenThatGroupCannotFit() {
        let bar = BarView(frame: .zero)
        bar.setModels([CodexModel(id: "sol", displayName: "GPT-6.1-Sol")])
        let label = bar.subviews.compactMap { $0 as? NSTextField }.first!
        let slider = bar.subviews.compactMap { $0 as? NSSlider }.first!
        for width: CGFloat in [bar.preferredWidth, 320, 180, 320] {
            bar.availableWidth = width
            bar.frame.size = bar.preferredSize
            bar.layoutSubtreeIfNeeded()
            XCTAssertEqual(slider.frame.width, 122)
            if width >= 320 {
                XCTAssertEqual(label.frame.midY, slider.frame.midY)
                XCTAssertGreaterThan(slider.frame.minX, label.frame.maxX)
            } else {
                XCTAssertGreaterThanOrEqual(label.frame.minY, slider.frame.maxY)
            }
        }
    }

    func testSingleSpeedButtonCyclesAndBusyBlocksOtherActions() throws {
        let bar = BarView(frame: .zero)
        bar.setModels([CodexModel(id: "sol", displayName: "Sol")])
        var cycles = 0
        bar.onCycleSpeed = { cycles += 1 }
        let speeds = bar.subviews.compactMap { $0 as? NSButton }.filter {
            $0.accessibilityLabel() == "Cycle speed"
        }
        XCTAssertEqual(speeds.count, 1)
        let button = try XCTUnwrap(speeds.first)
        for current in [ResponseSpeed.standard, .fast, .ultrafast, nil] as [ResponseSpeed?] {
            bar.setCurrentSpeed(current)
            XCTAssertEqual(button.accessibilityValue() as? String, current?.rawValue)
            XCTAssertEqual(button.toolTip, "Cycle speed")
            button.performClick(nil)
        }
        XCTAssertEqual(cycles, 4, "Every click sends one native cycle regardless of displayed state")
        bar.setBusySpeed(true)
        XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(bar.subviews.compactMap { $0 as? ModelButton }.allSatisfy { !$0.isEnabled })
        bar.setBusySpeed(false)
        XCTAssertTrue(button.isEnabled)
    }

    func testModelAndReasoningChangesKeepPreferredWidth() {
        let bar = BarView(frame: .zero)
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

import XCTest
import CodexModelBarCore
@testable import CodexNativeControls

final class CodexSpeedMenuTests: XCTestCase {
    func testVerifyOnlyReadsNativeUltrafastAndClosesTheMenu() {
        let fixture = Fixture(speed: "Ultrafast")
        XCTAssertEqual(CodexSpeedMenu.run(fixture.menu, speed: .ultrafast, readOnly: true), .alreadySelected)
        XCTAssertEqual(fixture.pressed, ["model", "model"])
        XCTAssertEqual(fixture.selectionChecks, 0)
    }

    func testVerifyOnlyDoesNotChangeFast() {
        let fixture = Fixture(speed: "Fast")
        XCTAssertEqual(CodexSpeedMenu.run(fixture.menu, speed: .ultrafast, readOnly: true), .refused("ultrafast-not-selected"))
        XCTAssertEqual(fixture.pressed, ["model", "model"])
        XCTAssertEqual(fixture.speed, "Fast")
        XCTAssertEqual(fixture.selectionChecks, 0)
    }

    func testApplySelectsUltrafastOnceAndReadsTheReopenedMenu() {
        let fixture = Fixture(speed: "Standard")
        XCTAssertEqual(CodexSpeedMenu.run(fixture.menu, speed: .ultrafast, readOnly: false), .applied)
        XCTAssertEqual(fixture.pressed, ["model", "speed-row", "ultrafast", "model", "model"])
        XCTAssertEqual(fixture.speed, "Ultrafast")
        XCTAssertEqual(fixture.selectionChecks, 1)
    }

    func testChangedCallRefusesBeforeSelecting() {
        let fixture = Fixture(speed: "Fast")
        fixture.maySelect = false
        XCTAssertEqual(CodexSpeedMenu.run(fixture.menu, speed: .ultrafast, readOnly: false), .refused("ultrafast-selection-refused"))
        XCTAssertEqual(fixture.pressed, ["model", "speed-row", "model"])
        XCTAssertEqual(fixture.speed, "Fast")
    }

    func testStandardAndFastApplyOnceAndThenVerifyWithoutSelecting() {
        for speed in [ResponseSpeed.standard, .fast] {
            let fixture = Fixture(speed: "Ultrafast")
            XCTAssertEqual(CodexSpeedMenu.run(fixture.menu, speed: speed, readOnly: false), .applied)
            XCTAssertEqual(fixture.speed, speed.rawValue)
            XCTAssertEqual(fixture.pressed, ["model", "speed-row", speed.rawValue.lowercased(), "model", "model"])
            XCTAssertEqual(CodexSpeedMenu.run(fixture.menu, speed: speed, readOnly: true), .alreadySelected)
            XCTAssertEqual(fixture.pressed.suffix(2), ["model", "model"])
            XCTAssertEqual(fixture.selectionChecks, 1)
        }
    }

    func testUnavailableFastDoesNotActivateASelection() {
        let fixture = Fixture(speed: "Standard")
        fixture.speedOptions.removeAll { $0.item == "fast" }
        XCTAssertEqual(CodexSpeedMenu.run(fixture.menu, speed: .fast, readOnly: false), .refused("fast-selection-refused"))
        XCTAssertEqual(fixture.pressed, ["model", "speed-row", "model"])
        XCTAssertEqual(fixture.speed, "Standard")
        XCTAssertEqual(fixture.selectionChecks, 0)
    }

    private final class Fixture {
        enum Surface { case closed, model, speed }
        var speed: String
        var surface = Surface.closed
        var pressed = [String]()
        var maySelect = true
        var selectionChecks = 0
        var speedOptions = [(title: "Standard", item: "standard"),
                            (title: "Fast 2x speed", item: "fast"),
                            (title: "Ultrafast 4x speed", item: "ultrafast")]

        init(speed: String) { self.speed = speed }

        var menu: CodexSpeedMenu.Menu<String> {
            CodexSpeedMenu.Menu(items: {
                switch self.surface {
                case .closed: return []
                case .model: return [(title: "Speed " + self.speed, item: "speed-row")]
                case .speed: return self.speedOptions
                }
            }, press: { item in
                self.pressed.append(item)
                switch item {
                case "model": self.surface = self.surface == .closed ? .model : .closed
                case "speed-row": self.surface = .speed
                case "standard", "fast", "ultrafast":
                    self.speed = item.capitalized
                    self.surface = .closed
                default: return false
                }
                return true
            }, trigger: { "model" }, ownsComposer: { true },
               maySelect: { self.selectionChecks += 1; return self.maySelect }, stillCurrent: { true })
        }
    }
}

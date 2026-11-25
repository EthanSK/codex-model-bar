import XCTest
@testable import CodexNativeControls

final class CodexSpeedMenuTests: XCTestCase {
    func testVerifyOnlyReadsNativeUltrafastAndClosesTheMenu() {
        let fixture = Fixture(speed: "Ultrafast")
        XCTAssertEqual(CodexSpeedMenu.run(fixture.menu, readOnly: true), .alreadySelected)
        XCTAssertEqual(fixture.pressed, ["model", "model"])
        XCTAssertEqual(fixture.selectionChecks, 0)
    }

    func testVerifyOnlyDoesNotChangeFast() {
        let fixture = Fixture(speed: "Fast")
        XCTAssertEqual(CodexSpeedMenu.run(fixture.menu, readOnly: true), .refused("ultrafast-not-selected"))
        XCTAssertEqual(fixture.pressed, ["model", "model"])
        XCTAssertEqual(fixture.speed, "Fast")
        XCTAssertEqual(fixture.selectionChecks, 0)
    }

    func testApplySelectsUltrafastOnceAndReadsTheReopenedMenu() {
        let fixture = Fixture(speed: "Standard")
        XCTAssertEqual(CodexSpeedMenu.run(fixture.menu, readOnly: false), .applied)
        XCTAssertEqual(fixture.pressed, ["model", "speed-row", "ultrafast", "model", "model"])
        XCTAssertEqual(fixture.speed, "Ultrafast")
        XCTAssertEqual(fixture.selectionChecks, 1)
    }

    func testChangedCallRefusesBeforeSelecting() {
        let fixture = Fixture(speed: "Fast")
        fixture.maySelect = false
        XCTAssertEqual(CodexSpeedMenu.run(fixture.menu, readOnly: false), .refused("ultrafast-selection-refused"))
        XCTAssertEqual(fixture.pressed, ["model", "speed-row", "model"])
        XCTAssertEqual(fixture.speed, "Fast")
    }

    private final class Fixture {
        enum Surface { case closed, model, speed }
        var speed: String
        var surface = Surface.closed
        var pressed = [String]()
        var maySelect = true
        var selectionChecks = 0

        init(speed: String) { self.speed = speed }

        var menu: CodexSpeedMenu.Menu<String> {
            CodexSpeedMenu.Menu(items: {
                switch self.surface {
                case .closed: return []
                case .model: return [(title: "Speed " + self.speed, item: "speed-row")]
                case .speed: return [(title: "Fast", item: "fast"), (title: "Ultrafast 4x speed", item: "ultrafast")]
                }
            }, press: { item in
                self.pressed.append(item)
                switch item {
                case "model": self.surface = self.surface == .closed ? .model : .closed
                case "speed-row": self.surface = .speed
                case "ultrafast":
                    self.speed = "Ultrafast"
                    self.surface = .closed
                default: return false
                }
                return true
            }, trigger: { "model" }, ownsComposer: { true },
               maySelect: { self.selectionChecks += 1; return self.maySelect }, stillCurrent: { true })
        }
    }
}

import XCTest
@testable import CodexModelBarCore

final class MouseShortcutTests: XCTestCase {
    func testFixedShortcutRejectsExtraCommandsAndPayloads() throws {
        XCTAssertTrue(MouseShortcut.isAstraUltrafast(try XCTUnwrap(URL(string: "codex-model-bar://astra-ultrafast"))))
        for text in ["https://astra-ultrafast", "codex-model-bar://other", "codex-model-bar://astra-ultrafast/extra",
                     "codex-model-bar://astra-ultrafast?model=other", "codex-model-bar://astra-ultrafast#text",
                     "codex-model-bar://user@astra-ultrafast", "codex-model-bar://astra-ultrafast:123"] {
            XCTAssertFalse(MouseShortcut.isAstraUltrafast(try XCTUnwrap(URL(string: text))), text)
        }
    }

    func testToggleDescriptionDistinguishesEnableFromDisable() {
        XCTAssertEqual(SpeedCommandState.read(title: "Ultrafast Turn off Ultrafast and return to standard speed", speed: .ultrafast), .enabled)
        XCTAssertEqual(SpeedCommandState.read(title: "/ultrafast The fastest available responses for latency-sensitive work", speed: .ultrafast), .disabled)
        for text in ["Ultrafast", "Enable fast mode", "Fast Turn off Fast and return to standard speed",
                     "Chat about Ultrafast The fastest available responses for latency-sensitive work"] {
            XCTAssertNil(SpeedCommandState.read(title: text, speed: .ultrafast), text)
        }
    }

    func testSpeedRatchetURLsAcceptOnlyFixedPayloadFreeActions() throws {
        for (name, expected) in [("speed-up", MouseShortcut.Action.speedUp), ("speed-down", .speedDown)] {
            XCTAssertEqual(MouseShortcut.action(for: try XCTUnwrap(URL(string: "codex-model-bar://\(name)"))), expected)
            for extra in ["/extra", "?speed=fast", "#text", ":123"] {
                XCTAssertNil(MouseShortcut.action(for: try XCTUnwrap(URL(string: "codex-model-bar://\(name)\(extra)"))))
            }
        }
    }
}

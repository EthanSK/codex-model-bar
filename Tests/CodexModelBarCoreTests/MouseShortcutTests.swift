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
        XCTAssertEqual(UltrafastCommandState.read(title: "Ultrafast Turn off Ultrafast and return to standard speed"), .enabled)
        XCTAssertEqual(UltrafastCommandState.read(title: "/ultrafast The fastest available responses for latency-sensitive work"), .disabled)
        for text in ["Ultrafast", "Enable fast mode", "Fast Turn off Fast and return to standard speed",
                     "Chat about Ultrafast The fastest available responses for latency-sensitive work"] {
            XCTAssertNil(UltrafastCommandState.read(title: text), text)
        }
    }
}

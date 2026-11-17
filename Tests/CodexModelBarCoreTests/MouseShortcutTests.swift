import XCTest
@testable import CodexModelBarCore

final class MouseShortcutTests: XCTestCase {
    func testAstraShortcutFollowsNewestVisibleModelWithUltrafast() {
        let models = [
            CodexModel(id: "gpt-6-astra", displayName: "Astra", speedTiers: [.ultrafast]),
            CodexModel(id: "gpt-6.2-astra", displayName: "Astra 6.2", speedTiers: [.ultrafast]),
            CodexModel(id: "gpt-6.10-astra", displayName: "Astra 6.10", speedTiers: [.ultrafast]),
            CodexModel(id: "gpt-7-astra", displayName: "Astra 7", speedTiers: [.fast]),
            CodexModel(id: "gpt-8-astra", displayName: "Astra 8", hidden: true, speedTiers: [.ultrafast]),
            CodexModel(id: "gpt-9-sol", displayName: "Sol 9", speedTiers: [.ultrafast])
        ]
        XCTAssertEqual(MouseShortcut.astraUltrafastModel(in: models)?.id, "gpt-6.10-astra")
        XCTAssertNil(MouseShortcut.astraUltrafastModel(in: Array(models.suffix(3))))
    }

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
        for (name, expected) in [("speed-up", MouseShortcut.Action.speedUp), ("speed-down", .speedDown), ("speed-cancel", .speedCancel)] {
            XCTAssertEqual(MouseShortcut.action(for: try XCTUnwrap(URL(string: "codex-model-bar://\(name)"))), expected)
            for extra in ["/extra", "?speed=fast", "#text", ":123"] {
                XCTAssertNil(MouseShortcut.action(for: try XCTUnwrap(URL(string: "codex-model-bar://\(name)\(extra)"))))
            }
        }
    }

    func testReasoningRatchetURLsAcceptOnlyFixedPayloadFreeActions() throws {
        for (name, expected) in [("reasoning-up", MouseShortcut.Action.reasoningUp),
                                 ("reasoning-down", .reasoningDown), ("reasoning-cancel", .reasoningCancel)] {
            XCTAssertEqual(MouseShortcut.action(for: try XCTUnwrap(URL(string: "codex-model-bar://\(name)"))), expected)
            for text in ["codex-model-bar://\(name)/extra", "codex-model-bar://\(name)?effort=max",
                         "codex-model-bar://\(name)#text", "codex-model-bar://\(name):123",
                         "codex-model-bar://user@\(name)", "https://\(name)"] {
                XCTAssertNil(MouseShortcut.action(for: try XCTUnwrap(URL(string: text))), text)
            }
        }
    }
}

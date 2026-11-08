// Setup regression fixtures never touch the real Codex config or post input.
import XCTest
@testable import CodexModelBar

final class AppSetupTests: XCTestCase {
    private func fixture(_ text: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("keybindings.json")
        if let text { try Data(text.utf8).write(to: url) }
        return url
    }

    func testFreshSetupAndRepeatedLaunch() throws {
        let url = try fixture(nil)
        XCTAssertEqual(try AppSetup.configureShortcuts(at: url), 3)
        let saved = try Data(contentsOf: url)
        XCTAssertEqual(try AppSetup.configureShortcuts(at: url), 0)
        XCTAssertEqual(try Data(contentsOf: url), saved)
    }

    func testKeepsVoiceBindingsCustomReasoningAndDisabledSpeed() throws {
        let url = try fixture(#"[{"command":"realtimeVoice","key":"Ctrl+Command+Shift+V","future":true},{"command":"composer.increaseReasoningEffort","key":"Ctrl+F19"},{"command":"composer.toggleFastMode","key":null}]"#)
        XCTAssertEqual(try AppSetup.configureShortcuts(at: url), 1)
        let bindings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(bindings[0]["future"] as? Bool, true)
        XCTAssertEqual(bindings[1]["key"] as? String, "Ctrl+F19")
        XCTAssertTrue(bindings[2]["key"] is NSNull)
    }

    func testDoesNotStealEquivalentChordOrReplaceMalformedFile() throws {
        let url = try fixture(#"[{"command":"other","key":"Control+Cmd+Up"}]"#)
        XCTAssertEqual(try AppSetup.configureShortcuts(at: url), 2)
        let broken = try fixture("broken")
        XCTAssertThrowsError(try AppSetup.configureShortcuts(at: broken))
        XCTAssertEqual(try String(contentsOf: broken), "broken")
    }
}

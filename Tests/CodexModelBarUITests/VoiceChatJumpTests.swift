// Exercises the floating AppKit button with a disposable H Chat command helper.
import AppKit
import XCTest
@testable import CodexModelBar

final class VoiceChatJumpTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-chat-jump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeHelper(build: String, reply: String = "", status: Int = 0) throws -> (app: URL, invocations: URL) {
        let app = directory.appendingPathComponent("HelloChat.app", isDirectory: true)
        let files = app.appendingPathComponent("Contents", isDirectory: true)
        let binaries = files.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let plist = [
            "CFBundleIdentifier": "com.ethansk.HeyChat",
            "CFBundleVersion": build,
            "CFBundleExecutable": "HelloChat",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: files.appendingPathComponent("Info.plist"))
        let executable = binaries.appendingPathComponent("HelloChat")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" >> "${0%/*}/invocations"
        [ "$#" -eq 1 ] && [ "$1" = '--show-current-voice' ] || exit 2
        printf '%s\\n' "\(reply)"
        exit \(status)

        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (app, binaries.appendingPathComponent("invocations"))
    }

    @MainActor
    func testFloatingButtonRunsTheCanonicalCommandOnce() async throws {
        _ = NSApplication.shared
        let helper = try makeHelper(build: "1065", reply: "Opened the current Voice chat.")
        let panel = VoiceJumpPanel()
        let jump = VoiceChatJump(codexApp: { nil }, panel: panel) { HChatShowVoice.openCurrentCall(in: helper.app) }
        let finished = expectation(description: "The button re-enables after its command finishes")
        panel.onSizeChange = {
            if panel.button.isEnabled { finished.fulfill() }
        }

        panel.button.performClick(nil)
        XCTAssertFalse(panel.button.isEnabled)
        panel.onClick?() // Even another action delivered during the command must not launch a second helper.
        await fulfillment(of: [finished], timeout: 3)
        let arguments = try String(contentsOf: helper.invocations, encoding: .utf8)
        XCTAssertEqual(arguments, "--show-current-voice\n")
        XCTAssertEqual(panel.preferredSize, VoiceJumpPanel.buttonSize)
        withExtendedLifetime(jump) {}
    }

    func testRefusesToLaunchOlderHChat() throws {
        let helper = try makeHelper(build: "1050")
        XCTAssertEqual(HChatShowVoice.openCurrentCall(in: helper.app), "Update H Chat to show the Voice chat")
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.invocations.path))
    }

    func testMissingHChatReturnsAnInstallNotice() {
        XCTAssertEqual(HChatShowVoice.openCurrentCall(in: directory.appendingPathComponent("Missing.app")),
                       "Install H Chat to show the Voice chat")
    }

    func testUsesTheHandlersInactiveMessage() throws {
        let helper = try makeHelper(build: "1054", reply: "There’s no active Voice call.", status: 1)
        XCTAssertEqual(HChatShowVoice.openCurrentCall(in: helper.app), "There’s no active Voice call.")
    }

    func testPanelNeverTakesFocusAndFloatsAboveCodexOverlay() {
        let panel = VoiceJumpPanel()
        XCTAssertFalse(panel.canBecomeKey, "Clicking must not take the keyboard away from Codex or the call")
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.floating.rawValue, "Codex's overlay sits at the floating level")
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(panel.preferredSize, VoiceJumpPanel.buttonSize)
        panel.showNotice("Couldn't identify the current Voice chat.")
        XCTAssertGreaterThan(panel.preferredSize.width, VoiceJumpPanel.buttonSize.width, "A notice widens the panel beside the button")
        panel.showNotice(nil)
        XCTAssertEqual(panel.preferredSize, VoiceJumpPanel.buttonSize)
    }
}

import AppKit
import SQLite3
import XCTest
import CodexModelBarCore
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

    /// Builds a tiny stand-in for Codex's `threads` table with only the columns read.
    private func makeDatabase(named name: String, withAttachedColumn: Bool = true, rows: [String]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let attached = withAttachedColumn ? ", attached_thread_parent_id TEXT" : ""
        let statements = ["CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT NOT NULL, archived INTEGER NOT NULL\(attached))"] + rows
        for sql in statements { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
        return url
    }

    func testReadsLiveThreadsAndSkipsArchivedOnes() throws {
        let url = try makeDatabase(named: "state_5.sqlite", rows: [
            "INSERT INTO threads VALUES ('a', NULL, 'Voice chat', 0, NULL)",
            "INSERT INTO threads VALUES ('b', 'Renamed', 'Raw title', 0, 'a')",
            "INSERT INTO threads VALUES ('c', NULL, 'Old', 1, NULL)",
        ])
        let records = try XCTUnwrap(CodexThreadIndex.records(at: url)).sorted { $0.id < $1.id }
        XCTAssertEqual(records, [
            CodexThreadRecord(id: "a", name: nil, title: "Voice chat", archived: false, attachedParentID: nil),
            CodexThreadRecord(id: "b", name: "Renamed", title: "Raw title", archived: false, attachedParentID: "a"),
        ])
    }

    func testOlderSchemaWithoutTheAttachedColumnStillReads() throws {
        let url = try makeDatabase(named: "state_4.sqlite", withAttachedColumn: false,
                                   rows: ["INSERT INTO threads VALUES ('a', NULL, 'Voice chat', 0)"])
        XCTAssertEqual(CodexThreadIndex.records(at: url)?.map(\.id), ["a"])
    }

    func testMissingDatabaseIsUnreadableNotEmpty() {
        XCTAssertNil(CodexThreadIndex.records(at: directory.appendingPathComponent("state_9.sqlite")),
                     "An unreadable list must refuse the jump, not report that no chat matched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state_9.sqlite").path),
                       "Opening read-only must never create a database")
    }

    func testPicksTheNewestStateDatabase() throws {
        for name in ["state_4.sqlite", "state_12.sqlite", "state_5.sqlite", "state_5.sqlite-wal", "goals_1.sqlite", "state_x.sqlite"] {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data())
        }
        XCTAssertEqual(CodexThreadIndex.databaseURL(codexHome: directory)?.lastPathComponent, "state_12.sqlite")
    }

    func testPanelNeverTakesFocusAndFloatsAboveCodexOverlay() {
        let panel = VoiceJumpPanel()
        XCTAssertFalse(panel.canBecomeKey, "Clicking must not take the keyboard away from Codex or the call")
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.floating.rawValue, "Codex's overlay sits at the floating level")
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(panel.preferredSize, VoiceJumpPanel.buttonSize)
        panel.showNotice("Codex's sidebar isn't showing the Voice chat")
        XCTAssertGreaterThan(panel.preferredSize.width, VoiceJumpPanel.buttonSize.width, "A notice widens the panel beside the button")
        panel.showNotice(nil)
        XCTAssertEqual(panel.preferredSize, VoiceJumpPanel.buttonSize)
    }
}

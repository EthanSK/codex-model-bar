/*
 ============================================================================
 **MOVED FROM — MOVE HISTORY**
 2026-11-08: Sources/CodexModelBar/ModelSwitcher.swift / waitUntil, poll. Extraction of existing native
 shortcut/focus code so Model Bar and Agentic Mouse embed the same implementation
 without depending on either running app. Task: Codex native shortcuts.
 ============================================================================
 */
import Foundation

public enum CodexControlWait {
    /// Re-evaluates `condition` every 40 ms until true or `timeout` seconds pass.
    @discardableResult
    public static func until(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        poll(timeout: timeout) { condition() ? true : nil } ?? false
    }

    /// Re-evaluates `body` every 40 ms until it returns a value or `timeout` passes.
    public static func poll<T>(timeout: TimeInterval, _ body: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = body() { return value }
            usleep(40_000)
        } while Date() < deadline
        return nil
    }
}

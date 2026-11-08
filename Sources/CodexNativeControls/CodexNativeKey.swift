/*
 ============================================================================
 **MOVED FROM — MOVE HISTORY**
 2026-11-08: CodexModelBar/SpeedShortcut.swift. Extraction of the existing one
 private, balanced key pair. New: shared by both embedded native-control hosts.
 ============================================================================
 */
import AppKit
import ApplicationServices

public enum CodexNativeKey {
    public static func post(_ shortcut: CodexShortcuts.Shortcut, pid: pid_t,
                            canPost: () -> Bool,
                            send: (CGEvent, pid_t) -> Void = { $0.postToPid($1) }) -> Bool {
        guard canPost() else { return false }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false) else { return false }
        for event in [down, up] { event.flags = shortcut.flags; send(event, pid) }
        return true // Always release the admitted key; no global modifier prefix or text.
    }
}

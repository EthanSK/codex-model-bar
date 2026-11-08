/*
 ============================================================================
 **MOVED FROM — MOVE HISTORY**
 2026-11-08: SpeedCommandPaste.swift. The existing 100 ms command-step delay is
 retained for model typing and between native speed steps. Unicode/Return speed
 delivery is replaced by process-targeted native shortcut pairs.
 ============================================================================
 */
import AppKit
import ApplicationServices

enum SpeedShortcut {
    static let commandStepDelay: useconds_t = 100_000

    /// One balanced private key pair per native step. No modifier-prefix events,
    /// Unicode payload, pasteboard or Return can reach the user's draft/recorder.
    static func post(_ shortcut: CodexShortcuts.Shortcut, count: Int, pid: pid_t,
                     canPost: () -> Bool, didPostStep: (Int) -> Void = { _ in },
                     send: (CGEvent, pid_t) -> Void = { $0.postToPid($1) },
                     wait: (useconds_t) -> Void = { _ = usleep($0) }) -> Bool {
        guard (1...2).contains(count) else { return false }
        for step in 0..<count {
            if step > 0 { wait(commandStepDelay) } // Reuse the former text-to-Return gap; no added padding.
            guard canPost() else { return false }
            let source = CGEventSource(stateID: .privateState)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false) else { return false }
            for event in [down, up] { event.flags = shortcut.flags; send(event, pid) }
            didPostStep(step) // A later cancellation must retain the estimate of any step already posted.
        }
        return true // Never wait for a resulting speed or retry a posted step.
    }
}

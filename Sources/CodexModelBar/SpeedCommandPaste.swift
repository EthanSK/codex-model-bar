import AppKit
import ApplicationServices

/// Historical name: this used to paste. Speed commands now use one direct
/// Unicode key pair followed by Return, without touching any pasteboard.
enum SpeedCommandPaste {
    /// Reuse the existing whole-text Unicode encoder; no per-character typing.
    static func events(_ command: String) -> [CGEvent]? {
        guard var events = Keyboard.textEvents(payload(command)) else { return nil }
        for event in events { event.flags = [] }
        let returnSource = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: returnSource,
                                      virtualKey: Keyboard.returnKey, keyDown: down) else { return nil }
            event.flags = []
            events.append(event)
        }
        return events
    }

    /// Codex's inline matcher requires start-of-text or whitespace before `/`.
    /// Always supply the boundary: a plain `/fast` at a draft's end becomes
    /// literal `draft/fast`, so Return cannot toggle Fast back to Standard.
    /// Codex removes only its suggestion range, preserving the surrounding draft.
    static func payload(_ command: String) -> String { " " + command }

    /// Ethan: "just send it best effort" with "a bit more delay between each
    /// step". Give the focused input 100 ms before typing, then give Codex's
    /// inline command handler the same 100 ms after the whole text;
    /// never poll for a result, retry the toggle or use the clipboard.
    /// Model search shares this pre-text delay after its input focus handoff.
    static let commandStepDelay: useconds_t = 100_000

    /// Type once and post one Return. Once a key goes down, always send its up
    /// event; recheck the keyboard owner before starting either key pair.
    static func post(_ command: String, canPost: () -> Bool,
                     send: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
                     wait: (useconds_t) -> Void = { _ = usleep($0) }) -> Bool {
        guard canPost(), let events = events(command) else { return false }
        wait(commandStepDelay) // Let the shared main/side-chat input focus settle before either bar or mouse typing (Ethan, 2026-10-31).
        for (index, event) in events.enumerated() {
            if index.isMultiple(of: 2), !canPost() { return false }
            send(event)
            if index == 0 { wait(10_000) }
            if index == 1 { wait(commandStepDelay) }
            if index == 2 { wait(30_000) } // Preserve the HID Return's real down/up interval used by Electron.
        }
        return true
    }
}

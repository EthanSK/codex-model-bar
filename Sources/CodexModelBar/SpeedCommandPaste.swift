import AppKit
import ApplicationServices

/// Matches Agent Flow's foreground Command-V followed by Return, without menu discovery.
enum SpeedCommandPaste {
    /// Build the same physical paste shortcut and HID Return that Agent Flow uses.
    static func events() -> [CGEvent]? {
        let pasteSource = CGEventSource(stateID: .privateState)
        let returnSource = CGEventSource(stateID: .hidSystemState)
        var events: [CGEvent] = []
        for (key, down, flags) in [(CGKeyCode(55), true, CGEventFlags.maskCommand),
                                  (9, true, .maskCommand), (9, false, .maskCommand),
                                  (55, false, []), (36, true, []), (36, false, [])] {
            guard let event = CGEvent(keyboardEventSource: key == 36 ? returnSource : pasteSource,
                                      virtualKey: key, keyDown: down) else { return nil }
            event.flags = flags
            events.append(event)
        }
        return events
    }

    /// Leave the command available until the receiving app consumes its queued paste.
    static func prepare(_ command: String, on board: NSPasteboard) -> Bool {
        board.clearContents()
        return board.setString(command, forType: .string) // Agent Flow's current foreground route leaves its clipboard payload too; timed restoration could replace a command before a lagging app reads it.
    }

    /// Paste once and post one Return; no command-menu checks, retries or text cleanup.
    static func post(_ command: String, canPost: () -> Bool) -> Bool {
        guard let events = events(), canPost(), prepare(command, on: .general) else { return false }
        let changeCount = NSPasteboard.general.changeCount
        for (index, event) in events.enumerated() {
            if index == 1, (!canPost() || NSPasteboard.general.changeCount != changeCount) {
                events[3].post(tap: .cghidEventTap) // A changed foreground app or newer clipboard copy must release Command without pasting that other payload.
                return false
            }
            if index == 4, !canPost() { return false }
            event.post(tap: .cghidEventTap)
            if index < 3 { usleep(10_000) }
            if index == 4 { usleep(30_000) } // Agent Flow's HID Return needs a real down/up interval; private back-to-back Return was ignored by Electron.
        }
        return true
    }
}

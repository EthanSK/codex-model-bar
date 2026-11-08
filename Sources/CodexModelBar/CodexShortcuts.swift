/*
 ============================================================================
 **MOVED FROM — MOVE HISTORY**
 2026-11-08: ReasoningSwitcher.swift / ReasoningShortcuts. The existing configured
 shortcut reader is shared with native speed. New: speed/cycle command IDs,
 layout-aware letter keys, and injectable binding data for offline tests.
 Task: Codex native shortcuts (01a1bb5d-60da-7733-ae65-557b8720cd43).
 ============================================================================
 */
import AppKit
import ApplicationServices
import Carbon

/// Refactor of existing ReasoningShortcuts; reads the user's current bindings,
/// including disabled entries, rather than assuming a shortcut is still assigned.
enum CodexShortcuts {
    enum Command: String {
        case cycleSpeed = "composer.toggleFastMode"
        case increaseReasoning = "composer.increaseReasoningEffort"
        case decreaseReasoning = "composer.decreaseReasoningEffort"
    }
    struct Shortcut: Equatable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
        let isArrow: Bool
    }
    struct Reasoning {
        let increase: Shortcut
        let decrease: Shortcut
    }
    private struct Binding: Decodable {
        let command: String
        let key: String? // One unrelated disabled shortcut must not hide usable keys.
    }

    static func reasoning() -> Reasoning? {
        guard let data = bindingData(),
              let increase = load(.increaseReasoning, data: data),
              let decrease = load(.decreaseReasoning, data: data) else { return nil }
        return Reasoning(increase: increase, decrease: decrease)
    }

    static func load(_ command: Command) -> Shortcut? {
        bindingData().flatMap { load(command, data: $0) }
    }

    static func load(_ command: Command, data: Data,
                     letterKey: (String, CGEventFlags) -> CGKeyCode? = letterKeyCode) -> Shortcut? {
        guard let bindings = try? JSONDecoder().decode([Binding].self, from: data) else { return nil }
        return bindings.filter { $0.command == command.rawValue }
            .compactMap { $0.key.flatMap { parse($0, letterKey: letterKey) } }
            .sorted { $0.isArrow && !$1.isArrow }.first
    }

    private static func bindingData() -> Data? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/keybindings.json")
        return try? Data(contentsOf: url)
    }

    static func parse(_ key: String,
                      letterKey: (String, CGEventFlags) -> CGKeyCode? = letterKeyCode) -> Shortcut? {
        let parts = key.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last else { return nil }
        var flags: CGEventFlags = []
        for part in parts.dropLast() {
            switch part {
            case "command", "cmd": flags.insert(.maskCommand)
            case "control", "ctrl": flags.insert(.maskControl)
            case "option", "alt": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: return nil
            }
        }
        let keyCode: CGKeyCode
        switch last {
        case "up": keyCode = 126
        case "down": keyCode = 125
        case "left": keyCode = 123
        case "right": keyCode = 124
        case "f16": keyCode = 106
        case "f18": keyCode = 79
        case "f19": keyCode = 80
        default:
            guard last.count == 1, last.first?.isLetter == true,
                  let resolved = letterKey(last, flags) else { return nil }
            keyCode = resolved
        }
        return Shortcut(keyCode: keyCode, flags: flags, isArrow: ["up", "down", "left", "right"].contains(last))
    }

    /// Resolve the semantic letter from the live layout. Control produces control
    /// characters, so retain only the Command/Option/Shift translation layers.
    /// This also respects Ethan's Dvorak–QWERTY Command input source.
    static func letterKeyCode(_ letter: String, flags: CGEventFlags) -> CGKeyCode? {
        // HIToolbox's input-source API requires the main queue on macOS 26.
        // Speed requests arrive on AX.queue, unlike the original menu fixture.
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { letterKeyCode(letter, flags: flags) }
        }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
              let bytes = CFDataGetBytePtr(unsafeBitCast(property, to: CFData.self)) else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            (CGKeyCode(0)...CGKeyCode(127)).first { keyCode in
                var dead: UInt32 = 0
                var length = 0
                var units = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers >> 8,
                                            UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysMask),
                                            &dead, units.count, &length, &units)
                return status == noErr && length > 0
                    && String(utf16CodeUnits: units, count: length).lowercased() == letter.lowercased()
            }
        }
    }
}

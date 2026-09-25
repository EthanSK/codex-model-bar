import AppKit
import ApplicationServices
import CodexModelBarCore

/// Moves to a chosen effort using Codex's own increase/decrease commands. The
/// user's keybindings are read on each change so the bar never sends an unbound key.
final class ReasoningSwitcher {
    enum Result {
        case changed
        case cancelledForTyping
        case failed(String)
    }

    private var busy = false

    func setEffort(_ target: String, model: CodexModel, allModels: [CodexModel], codex: NSRunningApplication,
                   completion: @escaping (Result) -> Void) {
        guard !busy else { return }
        busy = true
        let finish: (Result) -> Void = { result in
            DispatchQueue.main.async {
                self.busy = false
                completion(result)
            }
        }
        let pid = codex.processIdentifier
        AX.queue.async {
            guard codex.isActive else { finish(.failed("Codex is not active")); return }
            guard let shortcuts = ReasoningShortcuts.load() else {
                finish(.failed("Set reasoning shortcuts in Codex"))
                return
            }
            AX.enableWebAccessibility(pid: pid)
            guard let window = AX.focusedWindow(pid: pid) else {
                finish(.failed("No Codex window")); return
            }
            let located = CodexUI.Cache.current(window: window, models: allModels, forceRefresh: true)
            guard let composer = located.composer, let button = located.modelButton else {
                finish(.failed("No task composer")); return
            }
            let before = CurrentModelMatcher.selection(forButtonTitle: AX.title(button), among: allModels)
            guard before.modelID == model.id,
                  let current = before.effort,
                  let from = model.supportedEfforts.firstIndex(of: current),
                  let to = model.supportedEfforts.firstIndex(of: target) else {
                finish(.failed("Could not read the current reasoning level")); return
            }
            if from == to { finish(.changed); return }
            // Codex's command handler belongs to the composer. This also identifies
            // the right composer when a split view has two tasks open.
            if let focused: AXUIElement = AX.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
               AX.role(focused) == kAXTextAreaRole as String, !CFEqual(focused, composer) {
                finish(.failed("The task composer lost focus")); return
            }
            AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            guard ModelSwitcher.waitUntil(timeout: 0.6, {
                let app = AXUIElementCreateApplication(pid)
                guard let focused: AXUIElement = AX.attribute(app, kAXFocusedUIElementAttribute) else { return false }
                return CFEqual(focused, composer)
            }) else { finish(.failed("Could not focus the task composer")); return }

            let ascending = to > from
            let shortcut = ascending ? shortcuts.increase : shortcuts.decrease
            for next in stride(from: from + (ascending ? 1 : -1), through: to, by: ascending ? 1 : -1) {
                guard codex.isActive,
                      let focused: AXUIElement = AX.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
                      CFEqual(focused, composer) else {
                    finish(.failed("The task composer lost focus")); return
                }
                guard Keyboard.pressUnlessTyping(shortcut.keyCode, flags: shortcut.flags, pid: pid) else {
                    finish(.cancelledForTyping); return
                }
                let expected = model.supportedEfforts[next]
                let confirmed = ModelSwitcher.waitUntil(timeout: 1.2) {
                    guard codex.isActive,
                          let focused: AXUIElement = AX.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
                          CFEqual(focused, composer) else { return false }
                    let located = CodexUI.Cache.current(window: window, models: allModels, forceRefresh: true)
                    guard let currentComposer = located.composer, CFEqual(currentComposer, composer),
                          let button = located.modelButton else { return false }
                    let state = CurrentModelMatcher.selection(forButtonTitle: AX.title(button), among: allModels)
                    return state.modelID == model.id && state.effort == expected
                }
                guard confirmed else {
                    finish(.failed("Codex did not confirm the new reasoning level")); return
                }
            }
            finish(.changed)
        }
    }
}

private struct ReasoningShortcuts {
    struct Shortcut {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
        let isArrow: Bool
    }
    let increase: Shortcut
    let decrease: Shortcut

    private struct Binding: Decodable {
        let command: String
        let key: String
    }

    static func load() -> ReasoningShortcuts? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/keybindings.json")
        guard let data = try? Data(contentsOf: url),
              let bindings = try? JSONDecoder().decode([Binding].self, from: data) else { return nil }
        func shortcut(for command: String) -> Shortcut? {
            bindings.filter { $0.command == command }
                .compactMap { parse($0.key) }
                .sorted { $0.isArrow && !$1.isArrow }
                .first
        }
        guard let increase = shortcut(for: "composer.increaseReasoningEffort"),
              let decrease = shortcut(for: "composer.decreaseReasoningEffort") else { return nil }
        return ReasoningShortcuts(increase: increase, decrease: decrease)
    }

    private static func parse(_ key: String) -> Shortcut? {
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
        case "f18": keyCode = 79
        case "f19": keyCode = 80
        default: return nil
        }
        return Shortcut(keyCode: keyCode, flags: flags, isArrow: last == "up" || last == "down")
    }
}

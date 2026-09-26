import AppKit
import ApplicationServices
import CodexModelBarCore

/// The desktop shortcut can open a dropdown instead of the inline /model search.
/// Operate its model list without typing into a draft.
enum DropdownModelPicker {
    enum Choice: Equatable {
        case select(Int)
        case openModels(Int)
    }

    /// Match whole model labels only: an effort row or a descriptive button must
    /// never be mistaken for a model. Work mode can omit the GPT- prefix.
    static func choice(titles: [String], enabled: [Bool], current: String?, target: String,
                       models: [CodexModel]) -> Choice? {
        func matches(_ title: String, modelID: String?) -> Bool {
            guard let model = models.first(where: { $0.id == modelID }) else { return false }
            let title = CurrentModelMatcher.normalize(title)
            let name = CurrentModelMatcher.normalize(model.displayName)
            return title == name || (name.hasPrefix("gpt ") && title == String(name.dropFirst(4)))
        }
        let selectable = titles.indices.filter { enabled.indices.contains($0) && enabled[$0] }
        let targets = selectable.filter { matches(titles[$0], modelID: target) }
        if targets.count == 1 { return .select(targets[0]) }
        guard targets.isEmpty else { return nil }
        let rows = selectable.filter {
            let title = CurrentModelMatcher.normalize(titles[$0])
            return title == "select model" || matches(title, modelID: current)
                || (title.hasPrefix("model ") && matches(String(title.dropFirst(6)), modelID: current))
        }
        return rows.count == 1 ? .openModels(rows[0]) : nil
    }

    /// Only inspect the menu that currently holds focus. A different open menu,
    /// background chat or embedded browser page cannot supply a selectable item.
    static func focusedMenu(window: AXUIElement, pid: pid_t) -> AXUIElement? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused: AXUIElement = AX.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
        else { return nil }
        let menus = AX.all(in: window) { AX.role($0) == kAXMenuRole as String }
        return menus.last { menu in
            AX.first(in: menu, limit: 2_500, where: { CFEqual($0, focused) }) != nil
        }
    }

    /// Called only after this attempt opened the original composer's picker.
    /// The two actions are opening Select model and choosing the requested model.
    static func select(target: CodexModel, current: String?, models: [CodexModel], window: AXUIElement,
                       pid: pid_t, since started: TimeInterval, attempt: String) -> Bool {
        for step in 0..<2 {
            let ready = ModelSwitcher.poll(timeout: 1.0) { () -> ([AXUIElement], Choice)? in
                guard !Keyboard.userInteracted(since: started),
                      let menu = focusedMenu(window: window, pid: pid) else { return nil }
                let items = AX.all(in: menu, limit: 2_500) { AX.role($0) == kAXMenuItemRole as String }
                let titles = items.map(AX.title)
                let enabled = items.map { (AX.attribute($0, kAXEnabledAttribute) as Bool?) == true }
                guard let choice = choice(titles: titles, enabled: enabled, current: current,
                                          target: target.id, models: models) else { return nil }
                if step == 1, case .openModels = choice { return nil }
                return (items, choice)
            }
            guard let (items, choice) = ready, !Keyboard.userInteracted(since: started),
                  AX.focusedWindow(pid: pid).map({ CFEqual($0, window) }) == true,
                  focusedMenu(window: window, pid: pid) != nil else {
                Log.info("model-switch attempt=\(attempt) phase=dropdown-stopped step=\(step) userInteracted=\(Keyboard.userInteracted(since: started))")
                return false
            }
            let index: Int
            switch choice {
            case .select(let value): index = value
            case .openModels(let value): index = value
            }
            guard AX.press(items[index]) else {
                Log.info("model-switch attempt=\(attempt) phase=dropdown-press-failed choice=\(choice)")
                return false
            }
            Log.info("model-switch attempt=\(attempt) phase=dropdown-action choice=\(choice)")
            if case .select = choice { return true }
        }
        return false
    }

    /// Work mode may keep the dropdown open after selection. Escape restores the
    /// original composer; never send it after the user has taken over the menu.
    static func close(window: AXUIElement, pid: pid_t, since started: TimeInterval) {
        for _ in 0..<2 {
            guard !Keyboard.userInteracted(since: started),
                  AX.focusedWindow(pid: pid).map({ CFEqual($0, window) }) == true,
                  let menu = focusedMenu(window: window, pid: pid),
                  Keyboard.pressUnlessTyping(Keyboard.escape, pid: pid) else { return }
            _ = ModelSwitcher.waitUntil(timeout: 0.4) {
                focusedMenu(window: window, pid: pid).map { !CFEqual($0, menu) } ?? true
            }
        }
    }
}

import AppKit
import ApplicationServices
import CodexModelBarCore

/// Sets a speed through Codex's native submenu. Its items set an explicit tier;
/// `/fast` and `/ultrafast` instead toggle an already selected tier back to Standard.
final class SpeedSwitcher {
    enum Result {
        case changed
        case cancelledForTyping
        case failed(String)
    }

    private var busy = false

    func setSpeed(_ target: ResponseSpeed, allModels: [CodexModel], codex: NSRunningApplication,
                  completion: @escaping (Result) -> Void) {
        guard !busy else { return }
        busy = true
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let attempt = String(UUID().uuidString.prefix(8))
        Log.info("speed-switch attempt=\(attempt) phase=start speed=\(target.rawValue)")
        AX.queue.async {
            let result = Self.perform(target, models: allModels, codex: codex, since: requestedAt)
            Log.info("speed-switch attempt=\(attempt) phase=finish result=\(result)")
            DispatchQueue.main.async {
                self.busy = false
                completion(result)
            }
        }
    }

    private static func perform(_ target: ResponseSpeed, models: [CodexModel], codex: NSRunningApplication,
                                since started: TimeInterval) -> Result {
        let pid = codex.processIdentifier
        guard codex.isActive else { return .failed("Codex is not active") }
        guard !Keyboard.userInteracted(since: started) else { return .cancelledForTyping }
        AX.enableWebAccessibility(pid: pid)
        guard let window = AX.focusedWindow(pid: pid) else { return .failed("No Codex window") }
        let located = CodexUI.Cache.current(window: window, models: models, forceRefresh: true)
        guard let composer = located.composer, let modelButton = located.modelButton,
              let original = located.identity, let draft = CodexUI.composerText(composer),
              let root = webArea(containing: composer) else { return .failed("No task composer") }
        let restoreComposerFocus = CodexUI.composerHasFocus(composer, pid: pid)

        func sameComposer() -> Bool {
            guard codex.isActive, !Keyboard.userInteracted(since: started),
                  AX.focusedWindow(pid: pid).map({ CFEqual($0, window) }) == true else { return false }
            let current = CodexUI.Cache.current(window: window, models: models, forceRefresh: true)
            return current.identity.map { original.matches($0, equals: { CFEqual($0, $1) }) } == true
                && current.composer.flatMap(CodexUI.composerText) == draft
        }

        // A speed icon can be beside the model button, or inside its menu. Read only
        // this composer's ancestors first; another split task must not supply it.
        var control: AXUIElement?
        for scope in located.scopeAncestors {
            if let found = speedControl(in: scope) { control = found; break }
        }
        var openedModelMenu = false
        var openedSpeedMenu = false

        func dismissOwnedMenus() {
            // Escape is sent only while our own menu is still visible. An extra
            // Escape after it closes could dismiss an unrelated Codex panel.
            if openedSpeedMenu, sameComposer(), !speedOptions(in: root).isEmpty {
                _ = Keyboard.pressUnlessTyping(Keyboard.escape, pid: pid)
                _ = ModelSwitcher.waitUntil(timeout: 0.6) { speedOptions(in: root).isEmpty }
            }
            if openedModelMenu, sameComposer(), speedControl(in: root) != nil {
                _ = Keyboard.pressUnlessTyping(Keyboard.escape, pid: pid)
            }
        }
        defer {
            dismissOwnedMenus()
            // Codex's speed menu returns focus to its trigger. Restore the caret
            // only if this same input owned it before our click and the user stayed.
            if restoreComposerFocus, sameComposer(), speedOptions(in: root).isEmpty,
               let input = CodexUI.Cache.current(window: window, models: models, forceRefresh: true).composer {
                AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
        }

        if control == nil {
            guard speedControl(in: root) == nil, speedOptions(in: root).isEmpty else {
                return .failed("Close the Codex picker, then choose a speed")
            }
            guard sameComposer(), AX.press(modelButton) else { return .failed("Could not open Codex's speed choices") }
            openedModelMenu = true
            control = ModelSwitcher.poll(timeout: 1.5) { sameComposer() ? speedControl(in: root) : nil }
        }
        guard let control else { return .failed("Speed choices are unavailable for this model") }
        guard sameComposer() else { return .cancelledForTyping }
        Log.info("speed-switch phase=control speed=\(ResponseSpeed.controlValue(title: AX.title(control))?.rawValue ?? "unknown") role=\(AX.role(control)) modelMenu=\(openedModelMenu)")
        if ResponseSpeed.controlValue(title: AX.title(control)) == target { return .changed }
        guard sameComposer(), AX.press(control) else { return .failed("Could not open Codex's speed choices") }
        openedSpeedMenu = true
        guard let options = ModelSwitcher.poll(timeout: 1.5, {
            sameComposer() && !speedOptions(in: root).isEmpty ? speedOptions(in: root) : nil
        }) else { return .failed("Codex did not open its speed choices") }
        let matches = options.filter { ResponseSpeed.menuValue(title: AX.title($0)) == target }
        Log.info("speed-switch phase=options available=[\(options.compactMap { ResponseSpeed.menuValue(title: AX.title($0))?.rawValue }.sorted().joined(separator: ","))]")
        guard matches.count == 1, let option = matches.first,
              (AX.attribute(option, kAXEnabledAttribute) as Bool?) == true else {
            return .failed("\(target.rawValue) is unavailable for this model")
        }
        guard sameComposer(), AX.press(option) else { return .failed("Could not select \(target.rawValue) speed") }

        // Compact controls stay on screen; the advanced picker may close on selection.
        // Reopen only the same composer's picker when its speed row disappeared.
        _ = ModelSwitcher.waitUntil(timeout: 0.6) { speedOptions(in: root).isEmpty }
        if speedControl(in: root) == nil, openedModelMenu, sameComposer() {
            guard AX.press(modelButton) else { return .failed("Could not confirm \(target.rawValue) speed") }
        }
        let confirmed = ModelSwitcher.waitUntil(timeout: 1.5) {
            sameComposer() && speedControl(in: root).map { ResponseSpeed.controlValue(title: AX.title($0)) == target } == true
        }
        return confirmed ? .changed : .failed("Could not confirm \(target.rawValue) speed")
    }

    private static func webArea(containing element: AXUIElement) -> AXUIElement? {
        var node = AX.parent(element)
        for _ in 0..<60 {
            guard let current = node else { return nil }
            if AX.role(current) == "AXWebArea" { return current }
            node = AX.parent(current)
        }
        return nil
    }

    private static func speedControl(in root: AXUIElement) -> AXUIElement? {
        let matches = controls(in: root) { ResponseSpeed.controlValue(title: AX.title($0)) != nil }
        return matches.count == 1 ? matches.first : nil
    }

    private static func speedOptions(in root: AXUIElement) -> [AXUIElement] {
        let matches = controls(in: root) { ResponseSpeed.menuValue(title: AX.title($0)) != nil }
        // A complete speed menu always offers Standard. Reject stray Fast buttons
        // elsewhere in the chat, including embedded Computer Use previews.
        return matches.contains { ResponseSpeed.menuValue(title: AX.title($0)) == .standard } ? matches : []
    }

    private static func controls(in root: AXUIElement, matching predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
        var stack = AX.children(root), found: [AXUIElement] = [], visited = 0
        while let node = stack.popLast() {
            visited += 1
            guard visited <= 30_000 else { return [] }
            if AX.role(node) == "AXWebArea" { continue }
            if [kAXButtonRole as String, kAXPopUpButtonRole as String, kAXMenuItemRole as String].contains(AX.role(node)),
               predicate(node) { found.append(node) }
            stack.append(contentsOf: AX.children(node))
        }
        return found
    }
}

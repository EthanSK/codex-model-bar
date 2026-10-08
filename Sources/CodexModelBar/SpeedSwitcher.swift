import AppKit
import ApplicationServices
import CodexModelBarCore

/// Uses the typed slash route Ethan requested after the native speed-menu adapter
/// failed. Do not restore that picker fallback (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
final class SpeedSwitcher {
    enum Request { case select(ResponseSpeed), increase, decrease }
    enum Result { case changed(ResponseSpeed), cancelledForTyping, failed(String) }
    private var pendingCount = 0
    var isBusy: Bool { pendingCount > 0 }

    func setSpeed(_ target: ResponseSpeed, allModels: [CodexModel], codex: NSRunningApplication,
                  completion: @escaping (Result) -> Void) {
        change(.select(target), allModels: allModels, codex: codex, completion: completion)
    }

    func change(_ request: Request, allModels: [CodexModel], codex: NSRunningApplication,
                completion: @escaping (Result) -> Void) {
        pendingCount += 1 // Every wheel ratchet is queued on AX.queue; do not drop steps while a command is running.
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let attempt = String(UUID().uuidString.prefix(8))
        Log.info("speed-switch attempt=\(attempt) phase=start request=\(request)")
        AX.queue.async {
            let result = Self.perform(request, models: allModels, codex: codex, since: requestedAt)
            Log.info("speed-switch attempt=\(attempt) phase=finish result=\(result)")
            DispatchQueue.main.async {
                self.pendingCount -= 1
                completion(result)
            }
        }
    }

    private static func perform(_ request: Request, models: [CodexModel], codex: NSRunningApplication,
                                since started: TimeInterval) -> Result {
        let pid = codex.processIdentifier
        Log.info("speed-switch phase=focus active=\(codex.isActive) pid=\(pid) owner=\(AX.keyboardOwnerPID().map(String.init) ?? "none")")
        guard codex.isActive else { return .failed("Codex is not active") }
        guard !Keyboard.userInteracted(since: started) else { return .cancelledForTyping }
        if let owner = AX.keyboardOwnerPID(), owner != pid {
            DispatchQueue.main.sync { NSApp.activate(ignoringOtherApps: true) } // Release Agent Flow's non-activating panel as the model switcher already does.
            guard ModelSwitcher.waitUntil(timeout: 0.6, { NSRunningApplication.current.isActive }) else {
                return .failed("Could not release the floating panel's keyboard focus")
            }
            guard !Keyboard.userInteracted(since: started) else { return .cancelledForTyping }
            DispatchQueue.main.sync { _ = codex.activate() }
        }
        guard ModelSwitcher.waitUntil(timeout: 1, { codex.isActive && AX.keyboardOwnerPID() == pid }) else {
            return .failed("Codex did not receive keyboard focus")
        }
        guard !Keyboard.userInteracted(since: started) else { return .cancelledForTyping }
        AX.enableWebAccessibility(pid: pid)
        guard let window = AX.focusedWindow(pid: pid) else { return .failed("No Codex window") }
        let located = CodexUI.Cache.current(window: window, models: models, forceRefresh: true)
        guard let composer = located.composer, let original = located.identity,
              let modelButton = located.modelButton, let draft = CodexUI.composerText(composer) else {
            return .failed("No task composer")
        }
        let modelID = CurrentModelMatcher.selection(forButtonTitle: AX.title(modelButton), among: models).modelID
        AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard ModelSwitcher.waitUntil(timeout: 0.6, { CodexUI.composerHasFocus(composer, pid: pid) }),
              AX.string(composer, kAXSelectedTextAttribute).isEmpty, CodexUI.modelMenu(near: composer) == nil else {
            return .failed("Close the picker or clear the text selection first")
        }
        func sameComposer() -> Bool {
            guard codex.isActive, !Keyboard.userInteracted(since: started),
                  AX.focusedWindow(pid: pid).map({ CFEqual($0, window) }) == true,
                  CodexUI.composerHasFocus(composer, pid: pid) else { return false }
            let current = CodexUI.Cache.current(window: window, models: models, forceRefresh: true)
            return current.identity.map { original.matches($0, equals: { CFEqual($0, $1) }) } == true
                && current.modelButton.map { CurrentModelMatcher.selection(forButtonTitle: AX.title($0), among: models).modelID } == modelID
        }
        var typed = ""
        func cleanup() -> Bool {
            guard sameComposer() else { return false }
            let state = ComposerText.cleanupState(typed, before: draft, after: CodexUI.composerText(composer))
            if state == .remaining {
                for _ in typed {
                    guard sameComposer(), Keyboard.pressUnlessTyping(Keyboard.backspace, pid: pid) else { return false }
                }
            } else if state != .restored { return false }
            guard ModelSwitcher.waitUntil(timeout: 0.8, { CodexUI.composerText(composer) == draft }) else { return false }
            typed = ""
            return true
        }
        defer { _ = cleanup() } // A failed command lookup can leave our query in the draft; remove only the exact insertion we can prove.
        func inspect(_ query: String) -> [ResponseSpeed: (AXUIElement, SpeedCommandState)]? {
            guard sameComposer(), cleanup(), CodexUI.composerText(composer) == draft else { return nil }
            for character in query {
                guard sameComposer(), Keyboard.typeUnlessTyping(character, pid: pid) else { return nil }
                typed.append(character)
                usleep(8_000)
            }
            return ModelSwitcher.poll(timeout: 1.5) {
                guard sameComposer(), ComposerText.cleanupState(query, before: draft, after: CodexUI.composerText(composer)) == .remaining else { return nil }
                return CodexUI.speedCommands(near: composer)
            }
        }
        guard let commands = inspect("/") else { return .failed("Speed commands are unavailable in this composer") }
        let enabled = commands.filter { $0.value.1 == .enabled }.map(\.key)
        guard enabled.count <= 1 else { return .failed("Codex's current speed is ambiguous") }
        let current = enabled.first ?? .standard
        let target: ResponseSpeed
        switch request {
        case .select(let speed): target = speed
        case .increase: target = current.stepped(up: true, available: Set(commands.keys))
        case .decrease: target = current.stepped(up: false, available: Set(commands.keys))
        }
        if current == target {
            return cleanup() ? .changed(target) : .failed("Could not restore the draft after checking speed")
        }
        let commandSpeed = target == .standard ? current : target // Standard turns the currently active slash toggle off; there is no /standard command.
        guard commands[commandSpeed] != nil else { return .failed("\(target.rawValue) is unavailable for this model") }
        let query = "/\(commandSpeed.rawValue.lowercased())"
        let expected: SpeedCommandState = target == .standard ? .enabled : .disabled
        guard let filtered = inspect(query), filtered.count == 1, filtered[commandSpeed]?.1 == expected else {
            return .failed("Could not isolate \(query) in Codex's command menu")
        }
        usleep(37_500)
        guard sameComposer(), ComposerText.cleanupState(query, before: draft, after: CodexUI.composerText(composer)) == .remaining,
              let finalCommands = CodexUI.speedCommands(near: composer), finalCommands.count == 1,
              finalCommands[commandSpeed]?.1 == expected, Keyboard.pressUnlessTyping(Keyboard.returnKey, pid: pid) else {
            return .failed("Speed command changed before selection")
        }
        guard ModelSwitcher.waitUntil(timeout: 1.5, { CodexUI.composerText(composer) == draft }),
              let confirmed = inspect(query), confirmed.count == 1,
              confirmed[commandSpeed]?.1 == (target == .standard ? .disabled : .enabled), cleanup() else {
            return .failed("Could not confirm \(target.rawValue) speed")
        }
        return .changed(target)
    }
}

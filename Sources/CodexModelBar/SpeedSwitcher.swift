import AppKit
import ApplicationServices
import CodexModelBarCore

/// Uses the slash route Ethan requested. Do not restore the rejected picker fallback,
/// per-character tree scans or repeated confirmation queries (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
/// Fast and Ultrafast now use ordinary foreground paste/Return, not command-menu isolation.
final class SpeedSwitcher {
    enum Request { case select(ResponseSpeed), command(ResponseSpeed) }
    enum Result { case changed(ResponseSpeed), requested(ResponseSpeed), cancelled, cancelledForTyping, failed(String) }
    private var pendingCount = 0
    private var mouseGeneration = 0
    private var selectionGeneration = 0
    var isBusy: Bool { pendingCount > 0 }

    /// Release cancels queued mouse actions; an admitted command may finish while its input stays valid.
    func cancelMouseCommands() { mouseGeneration += 1 }

    func setSpeed(_ target: ResponseSpeed, allModels: [CodexModel], codex: NSRunningApplication,
                  completion: @escaping (Result) -> Void) {
        change(.select(target), allModels: allModels, codex: codex, completion: completion)
    }

    func change(_ request: Request, allModels: [CodexModel], codex: NSRunningApplication,
                completion: @escaping (Result) -> Void) {
        if case .select = request { selectionGeneration += 1 }
        let mouseGeneration = self.mouseGeneration
        let selectionGeneration = self.selectionGeneration
        pendingCount += 1
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let attempt = String(UUID().uuidString.prefix(8))
        Log.info("speed-switch attempt=\(attempt) phase=start request=\(request)")
        AX.queue.async {
            var admitted = false
            func isCurrent() -> Bool {
                DispatchQueue.main.sync {
                    switch request {
                    case .command:
                        return (admitted || self.mouseGeneration == mouseGeneration)
                            && ProcessInfo.processInfo.systemUptime - requestedAt < 2 // A slow tree read must not deliver a mouse command several seconds after the gesture.
                    case .select: return self.selectionGeneration == selectionGeneration
                    }
                }
            }
            let result: Result
            if !isCurrent() { result = .cancelled }
            else if case .command = request, ProcessInfo.processInfo.systemUptime - requestedAt > 0.5 {
                result = .cancelled // Slow AX work previously replayed ratchets after release; expire them instead.
                Log.info("speed-switch attempt=\(attempt) phase=expired")
            } else {
                admitted = true // Quick release must not erase an already-started ratchet; it only clears the queue.
                Log.info("speed-switch attempt=\(attempt) phase=admitted")
                result = Self.perform(request, models: allModels, codex: codex, since: requestedAt, isCurrent: isCurrent)
            }
            Log.info("speed-switch attempt=\(attempt) phase=finish result=\(result)")
            DispatchQueue.main.async {
                self.pendingCount -= 1
                completion(result)
            }
        }
    }

    private static func perform(_ request: Request, models: [CodexModel], codex: NSRunningApplication,
                                since started: TimeInterval, isCurrent: () -> Bool) -> Result {
        let pid = codex.processIdentifier
        Log.info("speed-switch phase=focus active=\(codex.isActive) pid=\(pid) owner=\(AX.keyboardOwnerPID().map(String.init) ?? "none")")
        guard isCurrent() else { return .cancelled }
        guard codex.isActive, AX.keyboardOwnerPID() == pid else { return .failed("Codex did not receive keyboard focus") } // Mouse URLs must never activate the bar or steal focus back from Agent Flow.
        guard !Keyboard.userInteracted(since: started) else { return .cancelledForTyping }
        let speed: ResponseSpeed
        switch request {
        case .select(let selected), .command(let selected): speed = selected
        }
        if speed != .standard {
            let command = "/\(speed.rawValue.lowercased())"
            guard SpeedCommandPaste.post(command, canPost: { isCurrent() && codex.isActive }) else {
                return isCurrent() ? .failed("Speed commands are unavailable in this composer") : .cancelled
            }
            return .requested(speed) // Ethan rejected per-click isolation and verification under lag; keep Agent Flow's paste/Return route, not the old query-and-Backspace flow (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
        }
        guard case .select = request else { return .failed("Speed commands are unavailable in this composer") }
        AX.enableWebAccessibility(pid: pid)
        guard let window = AX.focusedWindow(pid: pid) else { return .failed("No Codex window") }
        let located = CodexUI.Cache.current(window: window, models: models)
        guard let composer = located.composer, let modelButton = located.modelButton,
              let draft = CodexUI.composerText(composer) else {
            return .failed("No task composer")
        }
        let modelID = CurrentModelMatcher.selection(forButtonTitle: AX.title(modelButton), among: models).modelID
        AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard ModelSwitcher.waitUntil(timeout: 0.3, { CodexUI.composerHasFocus(composer, pid: pid) }),
              AX.string(composer, kAXSelectedTextAttribute).isEmpty, CodexUI.modelMenu(near: composer) == nil else {
            return .failed("Close the picker or clear the text selection first")
        }
        func sameFocus() -> Bool {
            codex.isActive && !Keyboard.userInteracted(since: started)
                && AX.focusedWindow(pid: pid).map({ CFEqual($0, window) }) == true
                && CodexUI.composerHasFocus(composer, pid: pid)
        }
        func sameComposer() -> Bool {
            sameFocus() && AX.role(modelButton) == kAXPopUpButtonRole as String
                && CurrentModelMatcher.selection(forButtonTitle: AX.title(modelButton), among: models).modelID == modelID // Speed commands keep the original input; re-read its live controls instead of walking the whole window again.
        }
        var inserted = ""
        func cleanup() -> Bool {
            guard !inserted.isEmpty else { return true }
            guard sameComposer() else { return false }
            let state = ComposerText.cleanupState(inserted, before: draft, after: CodexUI.composerText(composer))
            if state == .remaining {
                for _ in inserted {
                    guard sameFocus(), Keyboard.pressUnlessTyping(Keyboard.backspace, pid: pid) else { return false }
                }
            } else if state != .restored { return false }
            guard ModelSwitcher.waitUntil(timeout: 0.5, { CodexUI.composerText(composer) == draft }) else { return false }
            inserted = ""
            return true
        }
        defer { _ = cleanup() } // Cancellation can leave our query behind; restore only its proven insertion, never an edited draft.
        func inspect(_ query: String) -> [ResponseSpeed: (AXUIElement, SpeedCommandState)]? {
            guard isCurrent(), sameComposer(), cleanup(), CodexUI.composerText(composer) == draft, isCurrent(), sameFocus(),
                  Keyboard.insertUnlessTyping(query, pid: pid) else { return nil }
            inserted = query
            return ModelSwitcher.poll(timeout: 0.5) {
                guard isCurrent(), sameFocus(), ComposerText.cleanupState(query, before: draft, after: CodexUI.composerText(composer)) == .remaining else { return nil }
                guard let commands = CodexUI.speedCommands(near: composer) else { return nil }
                return commands
            }
        }
        guard let commands = inspect("/") else { return .failed("Speed commands are unavailable in this composer") }
        let enabled = commands.filter { $0.value.1 == .enabled }.map(\.key)
        guard enabled.count <= 1 else { return .failed("Codex's current speed is ambiguous") }
        guard let current = enabled.first else {
            return cleanup() ? .changed(.standard) : .failed("Could not restore the draft after checking speed")
        }
        guard cleanup(), isCurrent(), sameFocus(),
              SpeedCommandPaste.post("/\(current.rawValue.lowercased())", canPost: { isCurrent() && codex.isActive }) else {
            return isCurrent() ? .failed("Speed command changed before selection") : .cancelled
        }
        return .requested(.standard) // Codex has no /standard command, so only this button reads the active toggle once; the actual paste/Return is never retyped to verify it.
    }
}

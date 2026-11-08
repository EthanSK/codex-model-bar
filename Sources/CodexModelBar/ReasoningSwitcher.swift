// Changes reasoning through Codex’s configured native commands for the bar and mouse.
import AppKit
import ApplicationServices
import CodexModelBarCore

/// Moves to a chosen effort using Codex's own increase/decrease commands. The
/// user's keybindings are read on each change so the bar never sends an unbound key.
/// Never verify: press best effort and assume it worked; do not gate presses on model, level or focus reads (Ethan, 2026-10-29, Claude session f9500cd2).
final class ReasoningSwitcher {
    enum Request {
        case select(String, modelID: String), increase, decrease

        var isRelative: Bool {
            switch self {
            case .select: return false
            case .increase, .decrease: return true
            }
        }

        /// Mouse ratchets choose one neighbouring level from the freshly focused model, never toolbar state.
        func targetIndex(in model: CodexModel, from current: Int) -> Int? {
            guard model.supportedEfforts.indices.contains(current) else { return nil }
            switch self {
            case .select(let effort, let modelID):
                return model.id == modelID ? model.supportedEfforts.firstIndex(of: effort) : nil
            case .increase: return min(current + 1, model.supportedEfforts.count - 1)
            case .decrease: return max(current - 1, 0)
            }
        }
    }

    enum Result {
        case changed(CurrentSelection)
        case requested // Keys were sent; the bar assumes they worked and never waits to confirm the result.
        case cancelled
        case cancelledForTyping
        case failed(String)
    }

    private var pendingCount = 0
    private var mouseGeneration = 0
    var isBusy: Bool { pendingCount > 0 }

    /// As with speed release, cancel queued ratchets while allowing the admitted focus handoff to finish.
    func cancelMouseCommands() { mouseGeneration += 1 }

    func change(_ request: Request, allModels: [CodexModel], codex: NSRunningApplication,
                completion: @escaping (Result) -> Void) {
        if !request.isRelative && isBusy { completion(.cancelled); return }
        pendingCount += 1
        let generation = mouseGeneration
        let requestedAt = ProcessInfo.processInfo.systemUptime
        var origin: SpeedInputFocus?
        let attempt = String(UUID().uuidString.prefix(8))
        Log.info("reasoning-switch attempt=\(attempt) phase=start request=\(request)")
        let finish: (Result) -> Void = { result in
            if let origin, !Keyboard.userInteracted(since: requestedAt), codex.isActive || NSRunningApplication.current.isActive {
                origin.restore { !Keyboard.userInteracted(since: requestedAt) } // Return to Agent Flow only while this action still owns the handoff, before reporting completion.
            }
            Log.info("reasoning-switch attempt=\(attempt) phase=finish result=\(result)")
            DispatchQueue.main.async {
                self.pendingCount -= 1
                completion(result)
            }
        }
        let pid = codex.processIdentifier
        AX.enqueueAction {
            var admitted = false
            func isCurrent() -> Bool {
                guard request.isRelative else { return true }
                return DispatchQueue.main.sync {
                    (admitted || self.mouseGeneration == generation)
                        && ProcessInfo.processInfo.systemUptime - requestedAt < 2
                }
            }
            guard isCurrent(), !request.isRelative || ProcessInfo.processInfo.systemUptime - requestedAt <= 0.5 else {
                finish(.cancelled); return // Reuse speed's bounded mouse queue: never replay old ratchets after release or a slow AX walk.
            }
            admitted = true
            guard !Keyboard.userInteracted(since: requestedAt) else { finish(.cancelledForTyping); return }
            guard let shortcuts = CodexShortcuts.reasoning() else {
                finish(.failed("Set reasoning shortcuts in Codex"))
                return
            }
            AX.enableWebAccessibility(pid: pid)
            let window = AX.focusedWindow(pid: pid) // Best effort: never verify, just send (Ethan, 2026-10-29, Claude session f9500cd2). A missing window or input no longer stops the keys; do not restore those failure gates.
            var readyInput = window.flatMap(CodexUI.focusedSpeedInput(in:))
            let conversation = readyInput == nil ? window.flatMap(CodexUI.speedConversation(in:)) : nil // Reuse speed's main/side and question-card targeting before activation can restore a different input.
            // Codex's command handler belongs to the composer. This also identifies
            // the right composer when a split view has two tasks open.
            if let previous = SpeedInputFocus.capture(), previous.application.processIdentifier != pid { origin = previous } // No capturable focus only means there is nothing to restore afterwards.
            guard isCurrent() else { finish(.cancelled); return }
            _ = SpeedInputFocus.activate(codex, canFocus: isCurrent) // Shortcuts are posted to Codex's process, so a slow handoff is not a reason to stop.
            if readyInput == nil {
                ModelSwitcher.waitUntil(timeout: 1.5) {
                    guard isCurrent() else { return true }
                    readyInput = conversation.flatMap(CodexUI.speedInput(in:))
                        ?? AX.focusedWindow(pid: pid).flatMap(CodexUI.focusedSpeedInput(in:))
                    return readyInput != nil
                } // Codex swaps its composer after a send; wait up to 1.5 s for it, then press anyway (2026-10-29 19:07:52 "No task composer").
            }
            guard isCurrent() else { finish(.cancelled); return }
            if let composer = readyInput {
                _ = SpeedInputFocus.focus(composer, pid: pid, placeCaret: false, timeout: 0.6,
                                          canFocus: { isCurrent() && codex.isActive }) // Best effort; the press below is not gated on reading focus back.
            }
            Log.info("reasoning-switch attempt=\(attempt) phase=focused owner=\(origin.map { String($0.application.processIdentifier) } ?? "codex") composer=\(CodexUI.identity(readyInput))")
            let steps: Int
            let ascending: Bool
            switch request {
            case .increase:
                steps = 1; ascending = true // One press; Codex itself stops at the highest level, so no model or level read is needed.
            case .decrease:
                steps = 1; ascending = false
            case .select:
                var located = window.map { CodexUI.Cache.current(window: $0, models: allModels) } ?? CodexUI.Located() // The background poll has usually paired the input just focused; its button title is still read live.
                let pairedWithFocusedInput = located.modelButton != nil
                    && readyInput.map { input in located.composer.map { CFEqual($0, input) } ?? false } == true
                if !pairedWithFocusedInput, let window {
                    located = CodexUI.Cache.current(window: window, models: allModels, forceRefresh: true) // Another pane's pair, no button or no focused input keeps 1.2.55's fresh walk; skipping it saves that walk (median 182 ms, up to 3 s, 2026-10-31 log).
                }
                let before = CurrentModelMatcher.selection(forButtonTitle: located.modelButton.map(AX.title) ?? "", among: allModels) // The slider needs the starting level to count presses; this one read is not a confirmation.
                guard let model = allModels.first(where: { $0.id == before.modelID }),
                      let current = before.effort,
                      let from = model.supportedEfforts.firstIndex(of: current),
                      let to = request.targetIndex(in: model, from: from) else {
                    finish(.failed("Could not read the current reasoning level")); return
                }
                if from == to { finish(.changed(CurrentSelection(modelID: model.id, effort: current))); return } // A slider click still focuses the intended input when its effort is already selected.
                steps = abs(to - from); ascending = to > from
            }
            let shortcut = ascending ? shortcuts.increase : shortcuts.decrease
            for step in 0..<steps {
                guard isCurrent() else { finish(.cancelled); return }
                guard Keyboard.pressUnlessTyping(shortcut.keyCode, flags: shortcut.flags, pid: pid) else {
                    finish(.cancelledForTyping); return
                }
                if step < steps - 1 { usleep(150_000) } // Paced presses replace the per-step confirmation Ethan rejected on 2026-10-29: under heavy lag a press can land before Codex re-renders and fall one level short, which is accepted over locking up.
            }
            finish(.requested)
        }
    }
}

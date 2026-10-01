import AppKit
import ApplicationServices
import CodexModelBarCore

/// Switches the open Codex chat to a chosen model through Codex's **`/model` menu**,
/// opened with Codex's own keyboard shortcut (Control+Command+M, the
/// `composer.openRecentModels` command), so Codex applies the change through its
/// normal code path.
///
/// Why this route (inline search observed on 26.917; shortcut updated for 26.924):
///  - No deep link, setting or public API switches the model of the *open* chat.
///  - The composer's model dropdown was redesigned (effort slider + model list view) and
///    driving it needed fragile focus-and-Space tricks that broke with the redesign.
///  - The `/model` menu opens next to the message box without inserting text or moving
///    the caret, and its own keyboard handling picks entries: keys 1–3 choose a recent
///    entry while the search is empty, Return chooses the highlighted entry. (Its
///    entries ignore Accessibility "press" and clicks posted to the process.)
///
/// Sequence:
///  1. Find the composer the user is working in (model button + message box).
///  2. Focus the message box, verify, send Control+Command+M, wait for the menu.
///  3. Type the model's id as the menu's search (the menu reads its search
///     from the message box). Once every visible result is the target model, press
///     Return. Choosing removes the search text again; Codex keeps the current effort
///     when the new model supports it.
///  4. Confirm the model button now names the target.
///
/// Safety rules:
///  - Before **every** synthetic key, check that no real key was pressed in the last
///    second. If the user is typing we stop, so our keys can never interleave with
///    theirs (a probe that ignored this once mixed letters into a live draft).
///  - Letters, digits and Return are sent only right after proving the `/model` menu is
///    open and the message box has keyboard focus: while the menu is open it consumes
///    Return and digits, so they cannot send or edit the draft.
///  - If a search has to be abandoned, Backspace is pressed exactly once per typed
///    letter, and only when the message box differs from before by exactly that search.
final class ModelSwitcher {
    enum Result: CustomStringConvertible {
        case switched(CurrentSelection)
        case alreadyCurrent(CurrentSelection)
        /// Stopped before sending another key because the user was typing.
        case cancelledForTyping
        /// `searchLeft` is the search text that could not be removed safely (nil when
        /// the message box is back to how it was).
        case failed(String, searchLeft: String? = nil)

        var description: String {
            switch self {
            case .switched: return "switched"
            case .alreadyCurrent: return "alreadyCurrent"
            case .cancelledForTyping: return "cancelledForTyping"
            case .failed(let reason, let searchLeft):
                return "failed(\(reason)\(searchLeft.map { ", left '\($0)' in message box" } ?? ""))"
            }
        }
    }

    private var busy = false

    /// Starts a switch. `completion` runs on the main thread.
    func switchModel(to target: CodexModel, allModels: [CodexModel], codex: NSRunningApplication,
                     enableUltrafast: Bool = false, completion: @escaping (Result) -> Void) {
        guard !busy else { completion(.failed("Another model switch is in progress")); return }
        busy = true
        let attempt = String(UUID().uuidString.prefix(8))
        Log.info("model-switch attempt=\(attempt) phase=request target=\(target.id)")
        let finish: (Result) -> Void = { result in
            DispatchQueue.main.async {
                self.busy = false
                completion(result)
            }
        }

        let pid = codex.processIdentifier
        let requestedAt = ProcessInfo.processInfo.systemUptime
        AX.queue.async {
            Log.info("model-switch attempt=\(attempt) phase=start pid=\(pid) target=\(target.id)")
            guard !Keyboard.userInteracted(since: requestedAt) else {
                finish(.cancelledForTyping)
                return
            }
            if codex.isActive, let owner = AX.keyboardOwnerPID(), owner != pid {
                // Agent Flow's non-activating typing panel can own keys while Codex
                // stays active. Native testing proved reactivating Codex alone does
                // nothing; activating our accessory first releases that panel's key
                // ownership without closing it or changing the typing route.
                Log.info("model-switch attempt=\(attempt) phase=release-panel-keyboard owner=\(owner)")
                DispatchQueue.main.sync { NSApp.activate(ignoringOtherApps: true) }
                guard Self.waitUntil(timeout: 0.6, { NSRunningApplication.current.isActive }) else {
                    finish(.failed("could not release the floating panel's keyboard focus"))
                    return
                }
            }
            guard !Keyboard.userInteracted(since: requestedAt) else {
                finish(.cancelledForTyping)
                return
            }
            DispatchQueue.main.sync { _ = codex.activate() }
            guard Self.waitUntil(timeout: 1.0, { codex.isActive && AX.keyboardOwnerPID() == pid }) else {
                Log.info("model-switch attempt=\(attempt) phase=finish result=inactive")
                finish(.failed("Codex did not receive keyboard focus"))
                return
            }
            AX.enableWebAccessibility(pid: pid)
            let started = Date()
            let result = Self.performSwitch(to: target, allModels: allModels, pid: pid, attempt: attempt,
                                           enableUltrafast: enableUltrafast)
            Log.info("model-switch attempt=\(attempt) phase=finish target=\(target.id) result=\(result) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            finish(result)
        }
    }

    // MARK: - Steps (all on AX.queue)

    private static func performSwitch(to target: CodexModel, allModels: [CodexModel], pid: pid_t,
                                      attempt: String, retriesRemaining: Int = 1, enableUltrafast: Bool = false) -> Result {
        // Step 1: current model and message box.
        let switchStartedAt = ProcessInfo.processInfo.systemUptime
        guard let window = AX.focusedWindow(pid: pid) else { return .failed("no Codex window") }
        let initialFocus: AXUIElement? = AX.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
        var located = CodexUI.Cache.current(window: window, models: allModels, forceRefresh: true)
        if (located.modelButton == nil || located.composer == nil),
           let initialFocus, AX.role(initialFocus) == kAXTextAreaRole as String {
            Log.info("model-switch phase=wait-for-composer input=\(CodexUI.identity(initialFocus))")
            // A newly opened side task briefly exposes its input before the model
            // control. Wait for that same input, without retargeting a later focus.
            if let ready = poll(timeout: 1.0, { () -> CodexUI.Located? in
                guard isFocused(initialFocus, pid: pid) else { return nil }
                let candidate = CodexUI.Cache.current(window: window, models: allModels, forceRefresh: true)
                guard candidate.modelButton != nil, let input = candidate.composer, CFEqual(input, initialFocus)
                else { return nil }
                return candidate
            }) { located = ready }
        }
        guard let button = located.modelButton, let composer = located.composer else {
            Log.info("model-switch phase=locate-failed \(CodexUI.lookupDiagnostic)")
            return .failed("model button or message box not found (no chat composer on screen?)")
        }
        Log.info("model-switch attempt=\(attempt) phase=located composer=\(CodexUI.identity(composer)) button=\(CodexUI.identity(button)) scopes=[\(located.scopeAncestors.map(CodexUI.identity).joined(separator: ","))]")
        let current = CurrentModelMatcher.selection(forButtonTitle: AX.title(button), among: allModels)
        if current.modelID == target.id {
            if enableUltrafast { return selectUltrafast(original: located, window: window, pid: pid, models: allModels, selection: current, since: switchStartedAt) }
            return .alreadyCurrent(current)
        }

        // Step 2: open the /model menu, unless the user already has it open.
        var menu = CodexUI.modelMenu(near: composer)
        if menu == nil {
            Log.info("model-switch phase=open-menu shortcut=control-command-m")
            let focusingAt = ProcessInfo.processInfo.systemUptime
            guard focus(composer, pid: pid) else { return .failed("could not focus the message box") }
            // Ethan requested the previously working inline route with a short pause,
            // without the unverified dropdown adapter (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
            usleep(37_500)
            guard !Keyboard.userInteracted(since: focusingAt), isFocused(composer, pid: pid) else {
                return .cancelledForTyping
            }
            guard Keyboard.pressUnlessTyping(Keyboard.m, flags: [.maskControl, .maskCommand], pid: pid) else {
                return .cancelledForTyping
            }
            menu = poll(timeout: 1.5) { CodexUI.modelMenu(near: composer) }
        }
        guard menu != nil else {
            // Only close this composer's menu while it still owns keyboard focus.
            closeMenuIfOpen(composer: composer, pid: pid)
            return .failed("Codex's /model menu did not open")
        }

        // Allow the opened menu to settle before selecting; the existing live-menu
        // and focus checks below still protect the draft.
        let readyAt = ProcessInfo.processInfo.systemUptime
        usleep(37_500)
        guard !Keyboard.userInteracted(since: readyAt) else { return .cancelledForTyping }

        // Always use the previously working typed search. Ethan rejected picker
        // selection experiments; keep the pauses on this path (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
        guard let query = searchQuery(for: target) else {
            closeMenuIfOpen(composer: composer, pid: pid)
            return .failed("cannot search for \(target.id)")
        }
        guard isFocused(composer, pid: pid) else {
            closeMenuIfOpen(composer: composer, pid: pid)
            return .failed("message box lost focus before searching")
        }
        guard let before = CodexUI.composerText(composer) else {
            return .failed("message box became unavailable before searching")
        }
        let searchStartedAt = ProcessInfo.processInfo.systemUptime
        var typed = ""
        let retryAfterPanelLoss: (() -> Result)? = retriesRemaining > 0 ? {
            performSwitch(to: target, allModels: allModels, pid: pid, attempt: attempt, retriesRemaining: 0,
                          enableUltrafast: enableUltrafast)
        } : nil
        for character in query {
            guard isFocused(composer, pid: pid) else {
                return abandonSearch(typed, before: before, composer: composer, pid: pid,
                                     since: searchStartedAt, result: .failed("message box lost focus while searching"),
                                     window: window, models: allModels, allowPanelRecovery: true,
                                     retryAfterPanelLoss: retryAfterPanelLoss)
            }
            guard Keyboard.typeUnlessTyping(character, pid: pid) else {
                return abandonSearch(typed, before: before, composer: composer, pid: pid,
                                     since: searchStartedAt, result: .cancelledForTyping,
                                     window: window, models: allModels, retryAfterPanelLoss: nil)
            }
            typed.append(character)
            usleep(8_000)
        }
        // Recent configurations and catalogue hits can repeat the target. Return picks
        // the highlighted result, so every visible result must name that same model.
        let onlyTarget = poll(timeout: 1.5) { () -> Bool? in
            guard let menu = CodexUI.modelMenu(near: composer) else { return nil }
            let entries = menu.recent + menu.matching
            guard CurrentModelMatcher.searchResultsOnlyMatch(target.id, titles: entries.map(AX.title), among: allModels)
            else { return nil }
            return true
        }
        guard onlyTarget == true else {
            let menu = CodexUI.modelMenu(near: composer)
            Log.info("model-switch attempt=\(attempt) phase=search-not-isolated target=\(target.id) keyboardOwner=\(AX.keyboardOwnerPID().map(String.init) ?? "none") entries=\(((menu?.recent ?? []) + (menu?.matching ?? [])).map(AX.title))")
            return abandonSearch(typed, before: before, composer: composer, pid: pid,
                                 since: searchStartedAt, result: .failed("\(target.displayName) is not in Codex's /model menu"),
                                 window: window, models: allModels, allowPanelRecovery: true,
                                 retryAfterPanelLoss: retryAfterPanelLoss)
        }
        // Let the filtered result settle, then recheck before Return.
        usleep(37_500)
        guard !Keyboard.userInteracted(since: searchStartedAt) else {
            return abandonSearch(typed, before: before, composer: composer, pid: pid,
                                 since: searchStartedAt, result: .cancelledForTyping,
                                 window: window, models: allModels, retryAfterPanelLoss: nil)
        }
        // Return is safe only while the menu is open: Codex's menu handles it first. Check
        // the menu and focus immediately before sending it.
        guard let finalMenu = CodexUI.modelMenu(near: composer), isFocused(composer, pid: pid),
              CurrentModelMatcher.searchResultsOnlyMatch(target.id,
                  titles: (finalMenu.recent + finalMenu.matching).map(AX.title), among: allModels) else {
            Log.info("model-switch attempt=\(attempt) phase=before-choice-lost keyboardOwner=\(AX.keyboardOwnerPID().map(String.init) ?? "none")")
            return abandonSearch(typed, before: before, composer: composer, pid: pid,
                                 since: searchStartedAt, result: .failed("Codex's /model menu closed before choosing"),
                                 window: window, models: allModels, allowPanelRecovery: true,
                                 retryAfterPanelLoss: retryAfterPanelLoss)
        }
        Log.info("choosing search result for '\(query)' with Return")
        let chosenAt = ProcessInfo.processInfo.systemUptime
        guard Keyboard.pressUnlessTyping(Keyboard.returnKey, pid: pid) else {
            return abandonSearch(typed, before: before, composer: composer, pid: pid,
                                 since: searchStartedAt, result: .cancelledForTyping,
                                 window: window, models: allModels, retryAfterPanelLoss: nil)
        }
        let confirmed = CodexUI.confirmSelection(modelID: target.id, original: located, window: window,
            pid: pid, models: allModels, since: chosenAt, readOriginalAfterUserInput: true,
            logPrefix: "model-switch attempt=\(attempt)")

        // Model confirmation and draft verification are separate observations.
        // A remounted/edited input cannot prove that search text was left behind.
        let currentComposer = confirmed?.located.composer ?? composer
        _ = waitUntil(timeout: 0.5, { CodexUI.composerText(currentComposer) == before })
        var cleanup = ComposerText.cleanupState(typed, before: before, after: CodexUI.composerText(currentComposer))
        // A replacement has a new caret; never backspace into it automatically.
        if cleanup == .remaining, CFEqual(currentComposer, composer) {
            cleanup = removeTyped(typed, before: before, composer: composer, pid: pid, since: searchStartedAt)
        }
        Log.info("model-switch attempt=\(attempt) phase=search-cleanup result=\(cleanup) modelConfirmed=\(confirmed != nil)")
        if confirmed == nil { closeMenuIfOpen(composer: composer, pid: pid) }
        if enableUltrafast, let confirmed, cleanup == .restored,
           !Keyboard.userInteracted(since: searchStartedAt) {
            return selectUltrafast(original: confirmed.located, window: window, pid: pid,
                                  models: allModels, selection: confirmed.selection, since: switchStartedAt)
        }
        if enableUltrafast { return .failed("Astra/Ultrafast change could not be confirmed") }
        return searchResult(confirmed: confirmed?.selection, cleanup: cleanup, query: typed)
    }

    /// Inspect /ultrafast in the same composer, choose it only when OFF, then
    /// inspect again to confirm ON. Return is never sent without the exact live
    /// command entry, so an unavailable command cannot submit the user's draft.
    private static func selectUltrafast(original: CodexUI.Located, window: AXUIElement, pid: pid_t,
                                       models: [CodexModel], selection: CurrentSelection, since started: TimeInterval) -> Result {
        guard !Keyboard.userInteracted(since: started), selection.modelID == MouseShortcut.astraModelID,
              let identity = original.identity, let composer = original.composer,
              focus(composer, pid: pid), CodexUI.modelMenu(near: composer) == nil,
              let before = CodexUI.composerText(composer),
              AX.string(composer, kAXSelectedTextAttribute).isEmpty else {
            return .failed("Could not safely open Ultrafast in this composer")
        }
        func sameComposer() -> Bool {
            guard !Keyboard.userInteracted(since: started),
                  AX.focusedWindow(pid: pid).map({ CFEqual($0, window) }) == true,
                  isFocused(composer, pid: pid) else { return false }
            let current = CodexUI.Cache.current(window: window, models: models, forceRefresh: true)
            return current.identity.map { identity.matches($0, equals: { CFEqual($0, $1) }) } == true
                && current.modelButton.map { CurrentModelMatcher.selection(forButtonTitle: AX.title($0), among: models).modelID } == selection.modelID
        }
        let query = "/ultrafast"
        func inspectCommand() -> (AXUIElement, UltrafastCommandState)? {
            guard sameComposer(), CodexUI.composerText(composer) == before else { return nil }
            var typed = ""
            for character in query {
                guard !Keyboard.userInteracted(since: started), isFocused(composer, pid: pid),
                      Keyboard.typeUnlessTyping(character, pid: pid) else {
                    _ = removeTyped(typed, before: before, composer: composer, pid: pid, since: started)
                    return nil
                }
                typed.append(character)
                usleep(8_000)
            }
            return poll(timeout: 1.5) {
                guard sameComposer(), ComposerText.cleanupState(query, before: before, after: CodexUI.composerText(composer)) == .remaining else { return nil }
                return CodexUI.ultrafastCommand(near: composer)
            }
        }
        func cleanup() -> Bool {
            guard !Keyboard.userInteracted(since: started), isFocused(composer, pid: pid) else { return false }
            let restored = removeTyped(query, before: before, composer: composer, pid: pid, since: started) == .restored
            if restored { _ = Keyboard.pressUnlessTyping(Keyboard.escape, pid: pid) }
            return restored
        }
        guard let (_, state) = inspectCommand() else {
            let restored = cleanup()
            return .failed("Ultrafast is unavailable or its command could not be read", searchLeft: restored ? nil : (ComposerText.cleanupState(query, before: before, after: CodexUI.composerText(composer)) == .remaining ? query : nil))
        }
        if state == .enabled {
            guard cleanup() else { return .failed("Could not restore the draft after checking Ultrafast") }
            Log.info("mouse-shortcut result=confirmed model=gpt-6-astra speed=ultrafast alreadyEnabled=true")
            return .alreadyCurrent(selection)
        }
        guard sameComposer(), CodexUI.ultrafastCommand(near: composer)?.1 == .disabled,
              Keyboard.pressUnlessTyping(Keyboard.returnKey, pid: pid) else {
            _ = cleanup()
            return .failed("Ultrafast command changed before selection")
        }
        guard waitUntil(timeout: 1.5, { CodexUI.composerText(composer) == before }),
              let _ = inspectCommand(),
              poll(timeout: 1.5, { sameComposer() && CodexUI.ultrafastCommand(near: composer)?.1 == .enabled ? true : nil }) == true else {
            _ = cleanup()
            return .failed("Astra selected; Ultrafast could not be confirmed")
        }
        guard cleanup() else { return .failed("Ultrafast enabled; draft restoration could not be confirmed") }
        Log.info("mouse-shortcut result=confirmed model=gpt-6-astra speed=ultrafast alreadyEnabled=false")
        return .switched(selection)
    }

    static func searchResult(confirmed: CurrentSelection?, cleanup: ComposerText.CleanupState, query: String) -> Result {
        if cleanup == .remaining { return .failed("search text stayed in the message box", searchLeft: query) }
        if let confirmed { return .switched(confirmed) }
        return .failed("Codex did not confirm the new model")
    }

    /// The text to type into the /model search: the model id (it matches Codex's entry
    /// id exactly), or the display name when the id starts with a digit.
    private static func searchQuery(for model: CodexModel) -> String? {
        [model.id, model.displayName].first { $0.first?.isLetter == true }
    }

    /// Removes the search we typed (only if it is provably the sole change), then
    /// closes the menu. Returns `result`, marked when the search could not be removed.
    private static func abandonSearch(_ typed: String, before: String, composer: AXUIElement,
                                      pid: pid_t, since started: TimeInterval, result: Result,
                                      window: AXUIElement, models: [CodexModel],
                                      allowPanelRecovery: Bool = false,
                                      retryAfterPanelLoss: (() -> Result)?) -> Result {
        if allowPanelRecovery,
           !Keyboard.userInteracted(since: started),
           NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
           let owner = AX.keyboardOwnerPID(), owner != pid,
           let codex = NSRunningApplication(processIdentifier: pid), codex.isActive {
            // Agent Flow can make its non-activating panel key again after the search
            // starts. Retry only after reclaiming focus, proving the same composer is
            // still live, and removing exactly the search we typed.
            Log.info("model-switch phase=panel-interrupted-search owner=\(owner)")
            DispatchQueue.main.sync { NSApp.activate(ignoringOtherApps: true) }
            if waitUntil(timeout: 0.6, { NSRunningApplication.current.isActive }),
               !Keyboard.userInteracted(since: started) {
                DispatchQueue.main.sync { _ = codex.activate() }
                if waitUntil(timeout: 1.0, { codex.isActive && AX.keyboardOwnerPID() == pid }),
                   !Keyboard.userInteracted(since: started),
                   AX.focusedWindow(pid: pid).map({ CFEqual($0, window) }) == true,
                   let current = CodexUI.Cache.current(window: window, models: models, forceRefresh: true).composer,
                   CFEqual(current, composer) {
                    let recovered = removeTyped(typed, before: before, composer: composer, pid: pid, since: started)
                    Log.info("model-switch phase=panel-search-recovery cleanup=\(recovered)")
                    if recovered == .restored {
                        closeMenuIfOpen(composer: composer, pid: pid)
                        guard !Keyboard.userInteracted(since: started) else { return .cancelledForTyping }
                        if let retryAfterPanelLoss {
                            Log.info("model-switch phase=retry-after-panel-focus-loss")
                            return retryAfterPanelLoss()
                        }
                        return result
                    }
                    if recovered == .remaining { return markSearchLeft(typed, result) }
                    return result
                }
            }
        }
        let cleanup = removeTyped(typed, before: before, composer: composer, pid: pid, since: started)
        Log.info("model-switch phase=cleanup result=\(cleanup)")
        if cleanup == .remaining {
            return markSearchLeft(typed, result)
        }
        closeMenuIfOpen(composer: composer, pid: pid)
        return result
    }

    /// Deletes `typed` from the message box with one Backspace per character, but only
    /// when the box differs from `before` by exactly that text (so the caret sits right
    /// after it and nothing of the user's is touched). New hardware input prevents
    /// cleanup even when the user has since stopped typing or moved the caret.
    private static func removeTyped(_ typed: String, before: String, composer: AXUIElement,
                                    pid: pid_t, since started: TimeInterval) -> ComposerText.CleanupState {
        var now = CodexUI.composerText(composer)
        // Accessibility can lag a keystroke or two behind; give it a moment to settle.
        _ = waitUntil(timeout: 0.5) {
            now = CodexUI.composerText(composer)
            return ComposerText.cleanupState(typed, before: before, after: now) != .unverified
        }
        let state = ComposerText.cleanupState(typed, before: before, after: now)
        guard state == .remaining, isFocused(composer, pid: pid), !Keyboard.userInteracted(since: started)
        else { return state }
        for _ in typed {
            guard !Keyboard.userInteracted(since: started), isFocused(composer, pid: pid),
                  Keyboard.pressUnlessTyping(Keyboard.backspace, pid: pid)
            else { return ComposerText.cleanupState(typed, before: before, after: CodexUI.composerText(composer)) }
        }
        _ = waitUntil(timeout: 0.8) { CodexUI.composerText(composer) == before }
        return ComposerText.cleanupState(typed, before: before, after: CodexUI.composerText(composer))
    }

    private static func markSearchLeft(_ typed: String, _ result: Result) -> Result {
        switch result {
        case .failed(let reason, _): return .failed(reason, searchLeft: typed)
        default: return .failed("stopped while searching", searchLeft: typed)
        }
    }

    /// Closes the /model menu with Escape when it is still open. With an empty search,
    /// Escape only closes the menu; it never edits the message box.
    private static func closeMenuIfOpen(composer: AXUIElement, pid: pid_t) {
        usleep(120_000)   // let Codex finish closing the menu after a successful pick
        guard isFocused(composer, pid: pid), CodexUI.modelMenu(near: composer) != nil else { return }
        guard Keyboard.pressUnlessTyping(Keyboard.escape, pid: pid) else { return }
        _ = waitUntil(timeout: 0.5) { CodexUI.modelMenu(near: composer) == nil }
    }

    /// Gives the message box keyboard focus and proves it.
    private static func focus(_ composer: AXUIElement, pid: pid_t) -> Bool {
        if isFocused(composer, pid: pid) { return true }
        let app = AXUIElementCreateApplication(pid)
        if let focused: AXUIElement = AX.attribute(app, kAXFocusedUIElementAttribute),
           AX.role(focused) == kAXTextAreaRole as String { return false }
        AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return waitUntil(timeout: 0.6) { isFocused(composer, pid: pid) }
    }

    private static func isFocused(_ element: AXUIElement, pid: pid_t) -> Bool {
        CodexUI.composerHasFocus(element, pid: pid)
    }

    // MARK: - Polling helpers

    /// Re-evaluates `condition` every 40 ms until true or `timeout` seconds pass.
    @discardableResult
    static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        poll(timeout: timeout) { condition() ? true : nil } ?? false
    }

    /// Re-evaluates `body` every 40 ms until it returns a value or `timeout` passes.
    static func poll<T>(timeout: TimeInterval, _ body: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = body() { return value }
            usleep(40_000)
        } while Date() < deadline
        return nil
    }
}

/// Synthetic key presses delivered straight to Codex's process (not the global event
/// stream), so they can never land in another app.
enum Keyboard {
    static let m: CGKeyCode = 46
    static let escape: CGKeyCode = 53
    static let backspace: CGKeyCode = 51
    static let returnKey: CGKeyCode = 36

    /// True when a real (hardware) key went down within `interval` seconds. Our own
    /// synthetic events are private-source events posted to one process, so they do not
    /// count (verified: `.hidSystemState` ignores `postToPid` events).
    static func userIsTyping(within interval: TimeInterval = 1.0) -> Bool {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < interval
    }

    /// A new hardware key or mouse press during confirmation means the user may
    /// have navigated to a different task. Private process-targeted keys do not count.
    static func userInteracted(since started: TimeInterval) -> Bool {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        return [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) < elapsed
        }
    }

    /// Presses `key` unless the user is typing. Returns false when it held back.
    static func pressUnlessTyping(_ key: CGKeyCode, flags: CGEventFlags = [], pid: pid_t) -> Bool {
        guard !userIsTyping() else { return false }
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown) else { continue }
            event.flags = flags
            event.postToPid(pid)
        }
        return true
    }

    /// Types one character (as Unicode, independent of keyboard layout) unless the user
    /// is typing. Returns false when it held back.
    static func typeUnlessTyping(_ character: Character, pid: pid_t) -> Bool {
        guard !userIsTyping() else { return false }
        let source = CGEventSource(stateID: .privateState)
        var units = Array(String(character).utf16)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event.postToPid(pid)
        }
        return true
    }
}

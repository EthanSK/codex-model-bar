import CodexNativeControls
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
///     from its popup input, or the message box on older Codex). Once every visible
///     result is the target model, choose a row under Matching models. Codex applies
///     the model without restoring a recent preset's speed or reasoning. — GPT-6.2 Sol
///  4. Return immediately after choosing; the existing watcher reads the actual model.
///     Only the combined Astra/Ultrafast action waits before its dependent speed step.
///
/// Safety rules:
///  - Before **every** synthetic key, check that no real key was pressed in the last
///    second. If the user is typing we stop, so our keys can never interleave with
///    theirs (a probe that ignored this once mixed letters into a live draft).
///  - Prove menu readiness and keyboard ownership before typing, then watch hardware
///    input while sending the search. Read the filtered target once before Return;
///    while the menu is open it consumes Return instead of sending the draft.
///  - An abandoned popup search is closed without editing the draft. For the older
///    inline search, Backspace is pressed exactly once per typed
///    letter, and only when the message box differs from before by exactly that search.
final class ModelSwitcher {
    enum Result: CustomStringConvertible {
        case switched(CurrentSelection)
        case alreadyCurrent(CurrentSelection)
        /// The native choice was sent; the background watcher reports the actual selection.
        case requested
        /// Stopped before sending another key because the user was typing.
        case cancelledForTyping
        /// `searchLeft` is the search text that could not be removed safely (nil when
        /// the message box is back to how it was).
        case failed(String, searchLeft: String? = nil)

        var description: String {
            switch self {
            case .switched: return "switched"
            case .alreadyCurrent: return "alreadyCurrent"
            case .requested: return "requested"
            case .cancelledForTyping: return "cancelledForTyping"
            case .failed(let reason, let searchLeft):
                return "failed(\(reason)\(searchLeft.map { ", left '\($0)' in message box" } ?? ""))"
            }
        }
    }

    private var busy = false
    // The updater waits for the same operation boundary as normal model requests.
    var isBusy: Bool { busy }

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
        AX.enqueueAction {
            Log.info("model-switch attempt=\(attempt) phase=start pid=\(pid) target=\(target.id)")
            guard !Keyboard.userInteracted(since: requestedAt) else {
                finish(.cancelledForTyping)
                return
            }
            AX.enableWebAccessibility(pid: pid)
            let started = Date()
            let result = Self.performSwitch(to: target, allModels: allModels, codex: codex, attempt: attempt,
                                           enableUltrafast: enableUltrafast)
            Log.info("model-switch attempt=\(attempt) phase=finish target=\(target.id) result=\(result) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            finish(result)
        }
    }

    /// Applies the same explicit Ultrafast command to an already open, exact Voice composer. — GPT-6.2 Sol
    func selectVoiceUltrafast(_ request: VoiceSpeedRequest, models: [CodexModel], codex: NSRunningApplication,
                              completion: @escaping (Result, CGRect?, AXUIElement?) -> Void) {
        guard !busy else { completion(.failed("busy"), nil, nil); return }
        busy = true
        let started = ProcessInfo.processInfo.systemUptime
        AX.enqueueAction {
            let outcome = Self.performVoiceSpeed(request, models: models, codex: codex, started: started)
            DispatchQueue.main.async {
                self.busy = false
                completion(outcome.0, outcome.1, outcome.2)
            }
        }
    }

    // MARK: - Steps (all on AX.queue)

    private static func performVoiceSpeed(_ request: VoiceSpeedRequest, models: [CodexModel],
                                          codex: NSRunningApplication, started: TimeInterval) -> (Result, CGRect?, AXUIElement?) {
        let pid = codex.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard request.isCurrent, HChatVoiceIdentity.matches(request), !Keyboard.userInteracted(since: started),
              codex.isActive, let window: AXUIElement = AX.attribute(app, kAXFocusedWindowAttribute),
              AX.title(window) == request.chatTitle,
              let windows: [AXUIElement] = AX.attribute(app, kAXWindowsAttribute),
              windows.filter({ AX.title($0) == request.chatTitle }).count == 1,
              let bounds = CodexWindowTracker.axFrame(window) else {
            return (.failed("call-or-window-unavailable"), nil, nil)
        }
        // A focused composer alone can be a side chat. — GPT-6.2 Sol
        guard let pane = CodexUI.exactConversation(in: window, title: request.chatTitle) else {
            return (.failed("ambiguous-chat"), nil, nil)
        }
        let located = CodexUI.Cache.current(window: window, models: models, forceRefresh: true)
        guard let composer = located.composer, let button = located.modelButton,
              CodexUI.isInConversation(composer, pane: pane), let draft = CodexUI.composerText(composer) else {
            return (.failed("composer-unavailable"), nil, nil)
        }
        let modelTitle = AX.title(button)
        let selection = CurrentModelMatcher.selection(forButtonTitle: modelTitle, among: models)
        guard let modelID = selection.modelID, selection.effort != nil,
              models.contains(where: { $0.id == modelID && $0.speedTiers.contains(.ultrafast) }) else {
            return (.failed("model-effort-or-tier-unavailable"), nil, nil)
        }
        func ownsComposer() -> Bool {
            codex.isActive && !Keyboard.userInteracted(since: started) && AX.title(window) == request.chatTitle
                && (AX.attribute(app, kAXFocusedWindowAttribute) as AXUIElement?).map { CFEqual($0, window) } == true
                && CodexUI.isInConversation(composer, pane: pane) && CodexUI.composerText(composer) == draft
        }
        func trigger() -> AXUIElement? {
            func matches(_ node: AXUIElement) -> Bool {
                guard AX.role(node) == kAXPopUpButtonRole as String else { return false }
                let title = AX.title(node)
                return title == modelTitle || title == "Select effort"
            }
            if matches(button), CodexUI.isInConversation(button, pane: pane) { return button }
            let buttons = AX.all(in: pane, limit: 2_000, where: matches)
            return buttons.count == 1 ? buttons.first : nil
        }
        let result = CodexSpeedMenu.ultrafast(in: window, trigger: trigger, readOnly: request.verifyOnly == true,
                                              ownsComposer: ownsComposer, maySelect: {
            HChatVoiceIdentity.matches(request) && ownsComposer()
                && CodexUI.exactConversation(in: window, title: request.chatTitle).map { CFEqual($0, pane) } == true
        }, stillCurrent: { request.isCurrent })
        switch result {
        case .applied, .alreadySelected:
            guard HChatVoiceIdentity.matches(request), ownsComposer(),
                  CodexUI.exactConversation(in: window, title: request.chatTitle).map({ CFEqual($0, pane) }) == true,
                  poll(timeout: 0.6, {
                      guard request.isCurrent, ownsComposer(), let button = trigger() else { return nil }
                      return CurrentModelMatcher.selection(forButtonTitle: AX.title(button), among: models) == selection ? true : nil
                  }) == true else {
                return (.failed("selection-or-composer-changed"), nil, nil)
            }
            if result == .applied { return (.switched(selection), bounds, composer) }
            return (.alreadyCurrent(selection), bounds, composer)
        case .refused(let reason):
            return (.failed(reason), nil, nil)
        }
    }

    private static func performSwitch(to target: CodexModel, allModels: [CodexModel], codex: NSRunningApplication,
                                      attempt: String, retriesRemaining: Int = 1, enableUltrafast: Bool = false) -> Result {
        let pid = codex.processIdentifier
        // Step 1: current model and message box.
        let switchStartedAt = ProcessInfo.processInfo.systemUptime
        guard let window = AX.focusedWindow(pid: pid) else { return .failed("no Codex window") }
        let initialFocus: AXUIElement? = AX.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
        var located = CodexUI.Cache.current(window: window, models: allModels)
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
        func canFocus() -> Bool {
            !Keyboard.userInteracted(since: switchStartedAt)
                && AX.focusedWindow(pid: pid).map { CFEqual($0, window) } == true
                && AX.role(composer) == kAXTextAreaRole as String
        }
        guard canFocus(), SpeedInputFocus.activate(codex, canFocus: canFocus),
              SpeedInputFocus.focus(composer, pid: pid, placeCaret: false, timeout: 0.6,
                                    canFocus: { canFocus() && codex.isActive }) else {
            return .failed("Could not focus the task composer")
        } // Resolve the intended pane before activation; reuse speed/reasoning's focus write without moving the draft selection (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
        let current = CurrentModelMatcher.selection(forButtonTitle: AX.title(button), among: allModels)
        if current.modelID == target.id {
            if enableUltrafast { return selectUltrafast(original: located, window: window, pid: pid, models: allModels, selection: current, requestedModelID: target.id, since: switchStartedAt) }
            return .alreadyCurrent(current)
        }

        // Step 2: open the /model menu, unless the user already has it open.
        var menu = CodexUI.modelMenu(near: composer)
        let openedMenu = menu == nil
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
        guard let menu else {
            // Only close this composer's menu while it still owns keyboard focus.
            Log.info("model-switch attempt=\(attempt) phase=menu-not-found miss=\(CodexUI.lastMenuMiss)") // Read before closeMenuIfOpen overwrites it.
            closeMenuIfOpen(composer: composer, pid: pid)
            return .failed("Codex's /model menu did not open")
        }

        // Allow the opened menu to settle before selecting; the existing live-menu
        // and focus checks below still protect the draft.
        let readyAt = ProcessInfo.processInfo.systemUptime
        usleep(SpeedShortcut.commandStepDelay) // All toolbar text routes use the same 100 ms after input focus; keep the model menu's own typing route (Ethan, 2026-10-31).
        guard !Keyboard.userInteracted(since: readyAt) else { return .cancelledForTyping }

        // Always use the previously working typed search. Ethan rejected picker
        // selection experiments; keep the pauses on this path (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
        guard let query = searchQuery(for: target) else {
            closeMenuIfOpen(composer: composer, pid: pid)
            return .failed("cannot search for \(target.id)")
        }
        let searchInput = menu.searchInput ?? composer
        guard isFocused(searchInput, pid: pid) else {
            closeMenuIfOpen(composer: composer, pid: pid)
            return .failed("message box lost focus before searching")
        }
        guard let before = CodexUI.composerText(composer) else {
            return .failed("message box became unavailable before searching")
        }
        if menu.searchInput != nil, AX.role(searchInput) == kAXListRole as String {
            guard openedMenu else { return .cancelledForTyping } // A hidden popup query can't be read; only a menu the bar just opened is known to start empty.
        } else if menu.searchInput != nil {
            guard let queryText: String = AX.attribute(searchInput, kAXValueAttribute), queryText.isEmpty,
                  AX.string(searchInput, kAXSelectedTextAttribute).isEmpty else { return .cancelledForTyping }
        } // Do not append to an existing popup query or alter the user's chat draft.
        let searchStartedAt = ProcessInfo.processInfo.systemUptime
        var typed = ""
        let retryAfterPanelLoss: (() -> Result)? = retriesRemaining > 0 ? {
            performSwitch(to: target, allModels: allModels, codex: codex, attempt: attempt, retriesRemaining: 0,
                          enableUltrafast: enableUltrafast)
        } : nil
        for character in query {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  !Keyboard.userInteracted(since: searchStartedAt),
                  (menu.searchInput == nil || AX.isFocused(searchInput) || CodexUI.searchHasFocus(searchInput, pid: pid)) else {
                return abandonSearch(typed, before: before, composer: composer, pid: pid, searchInput: searchInput,
                                     since: searchStartedAt, result: .failed("message box lost focus while searching"),
                                     window: window, models: allModels, allowPanelRecovery: true,
                                     retryAfterPanelLoss: retryAfterPanelLoss)
            }
            guard Keyboard.typeUnlessTyping(character, pid: pid) else {
                return abandonSearch(typed, before: before, composer: composer, pid: pid, searchInput: searchInput,
                                     since: searchStartedAt, result: .cancelledForTyping,
                                     window: window, models: allModels, retryAfterPanelLoss: nil)
            }
            typed.append(character)
            usleep(8_000)
        }
        // Preserve the user-confirmed typing cadence before the single target-readiness poll.
        usleep(37_500)
        // A recent preset can name the right model but restore its saved speed and reasoning.
        // Require a catalogue hit and keep the existing exact-model guard for visible results.
        let matchingMenu = poll(timeout: 1.5) { () -> CodexUI.ModelMenu? in
            guard let menu = CodexUI.modelMenu(near: composer), !menu.matching.isEmpty,
                  CFEqual(menu.searchInput ?? composer, searchInput) else { return nil }
            let entries = menu.recent + menu.matching
            guard CurrentModelMatcher.searchResultsOnlyMatch(target.id, titles: entries.map(CodexUI.modelMenuEntryTitle), among: allModels)
            else { return nil }
            return menu
        }
        guard let matchingMenu else {
            let menu = CodexUI.modelMenu(near: composer)
            Log.info("model-switch attempt=\(attempt) phase=search-not-isolated target=\(target.id) keyboardOwner=\(AX.keyboardOwnerPID().map(String.init) ?? "none") entries=\(((menu?.recent ?? []) + (menu?.matching ?? [])).map(CodexUI.modelMenuEntryTitle))")
            return abandonSearch(typed, before: before, composer: composer, pid: pid, searchInput: searchInput,
                                 since: searchStartedAt, result: .failed("\(target.displayName) is not in Codex's /model menu"),
                                 window: window, models: allModels, allowPanelRecovery: true,
                                 retryAfterPanelLoss: retryAfterPanelLoss)
        }
        guard !Keyboard.userInteracted(since: searchStartedAt) else {
            return abandonSearch(typed, before: before, composer: composer, pid: pid, searchInput: searchInput,
                                 since: searchStartedAt, result: .cancelledForTyping,
                                 window: window, models: allModels, retryAfterPanelLoss: nil)
        }
        // The readiness read just proved the target menu; check keyboard ownership before Return.
        guard isFocused(searchInput, pid: pid) else {
            Log.info("model-switch attempt=\(attempt) phase=before-choice-lost keyboardOwner=\(AX.keyboardOwnerPID().map(String.init) ?? "none")")
            return abandonSearch(typed, before: before, composer: composer, pid: pid, searchInput: searchInput,
                                 since: searchStartedAt, result: .failed("Codex's /model menu closed before choosing"),
                                 window: window, models: allModels, allowPanelRecovery: true,
                                 retryAfterPanelLoss: retryAfterPanelLoss)
        }
        func isSelected(_ row: AXUIElement) -> Bool {
            (AX.attribute(row, kAXSelectedAttribute) as Bool?) == true
        }
        func menuStillOwnsKeys() -> Bool {
            !Keyboard.userInteracted(since: searchStartedAt)
                && AX.focusedWindow(pid: pid).map { CFEqual($0, window) } == true
                && isFocused(searchInput, pid: pid)
        }
        for _ in matchingMenu.recent {
            if matchingMenu.canChooseMatchingModel(isSelected: isSelected) { break }
            // Codex's popup advances one row with Down. Wait for the highlight
            // to leave the previous preset before sending another key.
            guard let preset = matchingMenu.recent.first(where: isSelected),
                  menuStillOwnsKeys(), Keyboard.pressUnlessTyping(Keyboard.downArrow, pid: pid),
                  waitUntil(timeout: 0.45, {
                      menuStillOwnsKeys() && !isSelected(preset)
                          && (matchingMenu.recent + matchingMenu.matching).contains(where: isSelected)
                  }) else { break }
        }
        guard matchingMenu.canChooseMatchingModel(isSelected: isSelected), menuStillOwnsKeys() else {
            let result: Result = Keyboard.userInteracted(since: searchStartedAt)
                ? .cancelledForTyping : .failed("Could not highlight the matching model without restoring a recent preset")
            return abandonSearch(typed, before: before, composer: composer, pid: pid, searchInput: searchInput,
                                 since: searchStartedAt, result: result, window: window, models: allModels,
                                 retryAfterPanelLoss: nil)
        }
        Log.info("choosing catalogue result for '\(query)' with Return")
        let chosenAt = ProcessInfo.processInfo.systemUptime
        guard Keyboard.pressUnlessTyping(Keyboard.returnKey, pid: pid) else {
            return abandonSearch(typed, before: before, composer: composer, pid: pid, searchInput: searchInput,
                                 since: searchStartedAt, result: .cancelledForTyping,
                                 window: window, models: allModels, retryAfterPanelLoss: nil)
        }
        if !enableUltrafast { return .requested } // Ethan rejected blocking verification; do not restore final model/draft polling or post-choice Backspace cleanup for ordinary buttons (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
        let confirmed = CodexUI.confirmSelection(modelID: target.id, original: located, window: window,
            pid: pid, models: allModels, since: chosenAt, readOriginalAfterUserInput: true,
            logPrefix: "model-switch attempt=\(attempt)")

        // Model confirmation and draft verification are separate observations.
        // A remounted/edited input cannot prove that search text was left behind.
        let currentComposer = confirmed?.located.composer ?? composer
        _ = waitUntil(timeout: 0.5, { CodexUI.composerText(currentComposer) == before })
        let inlineSearch = CFEqual(searchInput, composer)
        var cleanup = ComposerText.cleanupState(inlineSearch ? typed : "", before: before, after: CodexUI.composerText(currentComposer))
        // A replacement has a new caret; never backspace into it automatically.
        if inlineSearch, cleanup == .remaining, CFEqual(currentComposer, composer) {
            cleanup = removeTyped(typed, before: before, composer: composer, pid: pid, since: searchStartedAt)
        }
        Log.info("model-switch attempt=\(attempt) phase=search-cleanup result=\(cleanup) modelConfirmed=\(confirmed != nil)")
        if confirmed == nil { closeMenuIfOpen(composer: composer, pid: pid) }
        if let confirmed, cleanup == .restored,
           !Keyboard.userInteracted(since: searchStartedAt) {
            return selectUltrafast(original: confirmed.located, window: window, pid: pid,
                                  models: allModels, selection: confirmed.selection, requestedModelID: target.id, since: switchStartedAt)
        }
        return .failed("Astra/Ultrafast change could not be confirmed")
    }

    /// Inspect /ultrafast in the same composer, choose it only when OFF, then
    /// inspect again to confirm ON. Return is never sent without the exact live
    /// command entry, so an unavailable command cannot submit the user's draft.
    private static func selectUltrafast(original: CodexUI.Located, window: AXUIElement, pid: pid_t,
                                       models: [CodexModel], selection: CurrentSelection, requestedModelID: String, since started: TimeInterval) -> Result {
        guard !Keyboard.userInteracted(since: started), selection.modelID == requestedModelID,
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
        func inspectCommand() -> (AXUIElement, SpeedCommandState)? {
            guard sameComposer(), CodexUI.composerText(composer) == before else { return nil }
            usleep(SpeedShortcut.commandStepDelay) // The combined model/speed action also lets its focused input settle before each command it types (Ethan, 2026-10-31).
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
            usleep(37_500) // Keep the same post-typing gap as ordinary model search before this path can press Return (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
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
            Log.info("mouse-shortcut result=confirmed model=\(requestedModelID) speed=ultrafast alreadyEnabled=true")
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
        Log.info("mouse-shortcut result=confirmed model=\(requestedModelID) speed=ultrafast alreadyEnabled=false")
        return .switched(selection)
    }

    /// The text to type into the /model search: the model id (it matches Codex's entry
    /// id exactly), or the display name when the id starts with a digit.
    private static func searchQuery(for model: CodexModel) -> String? {
        [model.id, model.displayName].first { $0.first?.isLetter == true }
    }

    /// Removes the search we typed (only if it is provably the sole change), then
    /// closes the menu. Returns `result`, marked when the search could not be removed.
    private static func abandonSearch(_ typed: String, before: String, composer: AXUIElement,
                                      pid: pid_t, searchInput: AXUIElement, since started: TimeInterval, result: Result,
                                      window: AXUIElement, models: [CodexModel],
                                      allowPanelRecovery: Bool = false,
                                      retryAfterPanelLoss: (() -> Result)?) -> Result {
        if !CFEqual(searchInput, composer) {
            if !Keyboard.userInteracted(since: started), isFocused(searchInput, pid: pid) {
                closeMenuIfOpen(composer: composer, pid: pid)
            }
            return result // The query belongs to the popup; never Backspace into a restored chat draft or retry in another input.
        }
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
        guard CodexUI.modelMenu(near: composer) != nil else { return }
        guard Keyboard.pressUnlessTyping(Keyboard.escape, pid: pid) else { return }
        _ = waitUntil(timeout: 0.5) { CodexUI.modelMenu(near: composer) == nil }
    }

    /// Gives the message box keyboard focus and proves it.
    private static func focus(_ composer: AXUIElement, pid: pid_t) -> Bool {
        if isFocused(composer, pid: pid) { return true }
        let app = AXUIElementCreateApplication(pid)
        if let focused: AXUIElement = AX.attribute(app, kAXFocusedUIElementAttribute),
           AX.role(focused) == kAXTextAreaRole as String { return false }
        return SpeedInputFocus.focus(composer, pid: pid, placeCaret: false, timeout: 0.6,
                                     canFocus: { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid })
    }

    private static func isFocused(_ element: AXUIElement, pid: pid_t) -> Bool {
        CodexUI.searchHasFocus(element, pid: pid)
    }

    // MARK: - Polling helpers

    /// Extraction of existing readiness polling into the shared native-control library.
    @discardableResult
    static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        CodexNativeControls.CodexControlWait.until(timeout: timeout, condition)
    }
    static func poll<T>(timeout: TimeInterval, _ body: () -> T?) -> T? {
        CodexNativeControls.CodexControlWait.poll(timeout: timeout, body)
    }
}

/// Synthetic key presses delivered straight to Codex's process (not the global event
/// stream), so they can never land in another app.
enum Keyboard {
    static let m: CGKeyCode = 46
    static let escape: CGKeyCode = 53
    static let backspace: CGKeyCode = 51
    static let returnKey: CGKeyCode = 36
    static let downArrow: CGKeyCode = 125

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

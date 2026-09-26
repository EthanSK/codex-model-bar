import AppKit
import ApplicationServices
import CodexModelBarCore

/// Knowledge of Codex's UI as exposed to Accessibility (verified on desktop 26.917).
///
/// Composer area, simplified. The `/model` menu (opened with Codex's own Control+Command+M
/// shortcut) appears above the message box. Desktop 26.924 renders it in a portal;
/// older versions exposed the following adjacent layout:
/// ```
/// AXGroup                                  ← shared parent of menu + composer
///  ├ AXGroup                               ← `/model` menu (only while open)
///  │   └ AXGroup                           ← one section
///  │      ├ AXGroup [AXStaticText "Recent models", "⌃⇧M"]   ← section header
///  │      ├ AXButton "1 Opus 5.5 Extra High Standard"        ← recent configuration
///  │      └ AXButton "2 GPT-6 Sol Max Standard"
///  │   (while searching, a "Matching models" section lists
///  │    AXButton "GPT-6 Sol Workhorse model for coding…")
///  └ AXGroup                               ← composer
///     ├ AXTextArea "Do anything"           ← the message box (title = placeholder)
///     └ AXGroup … AXPopUpButton "Opus 5.5 Extra High"   ← composer model button
/// ```
/// Menu entries are web buttons, but they ignore Accessibility "press"; the switcher
/// picks them with the menu's own keys (1–3, Return). The bar only reads them.
enum CodexUI {
    /// Result of one pass over the chat.
    struct Located {
        var modelButton: AXUIElement?
        var composer: AXUIElement?
        var scopeAncestors: [AXUIElement] = []

        var identity: ComposerIdentity<AXUIElement>? {
            composer.map { ComposerIdentity(input: $0, scopeAncestors: scopeAncestors) }
        }
    }

    // Accessed only on AX.queue. Avoid repeating unchanged polling diagnostics.
    private static var lastDiagnostic = ""
    private static var lastDiagnosticAt = Date.distantPast
    static var lookupDiagnostic = "not-read"

    static func identity(_ element: AXUIElement?) -> String {
        guard let element else { return "none" }
        return "\(AX.role(element))#\(String(CFHash(element), radix: 16))"
    }

    /// Chromium can temporarily expose a group/web area as app focus while the
    /// input itself retains AXFocused. Never accept a different focused input.
    static func composerHasFocus(_ composer: AXUIElement, pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused: AXUIElement = AX.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
        else { return false }
        if CFEqual(focused, composer) { return true }
        return [kAXGroupRole as String, kAXWindowRole as String, "AXWebArea"].contains(AX.role(focused))
            && AX.isFocused(composer)
    }

    /// Resolve the focused input first, then a still-attached previous input.
    /// Multiple composers without either identity are deliberately ambiguous.
    static func locate(in window: AXUIElement, models: [CodexModel], previousComposer: AXUIElement?) -> Located {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return Located() }
        let focused: AXUIElement? = AX.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
        var trace: [String] = []
        var inputFlags: Set<String> = []
        let resolver = ComposerLocator<AXUIElement>(
            children: AX.children, parent: AX.parent,
            isTextArea: {
                let isInput = AX.role($0) == kAXTextAreaRole as String
                if isInput { inputFlags.insert("\(identity($0)):focused=\(AX.isFocused($0))") }
                return isInput
            },
            isModelButton: {
                AX.role($0) == kAXPopUpButtonRole as String
                    && CurrentModelMatcher.isModelButtonTitle(AX.title($0), among: models)
            }, equals: { CFEqual($0, $1) }, hasKeyboardFocus: AX.isFocused,
            diagnostic: { if trace.count < 40 { trace.append($0) } }
        )
        let result = resolver.locate(in: window, focused: focused, previousComposer: previousComposer)
        let selection = CurrentModelMatcher.selection(forButtonTitle: result.map { AX.title($0.modelButton) } ?? "", among: models)
        lookupDiagnostic = "window=\(identity(window)) focused=\(identity(focused)) previous=\(identity(previousComposer)) selected=\(identity(result?.composer)) model=\(selection.modelID ?? "none") effort=\(selection.effort ?? "none") inputs=[\(inputFlags.sorted().joined(separator: ","))] trace=[\(trace.joined(separator: ";"))]"
        if lookupDiagnostic != lastDiagnostic || Date().timeIntervalSince(lastDiagnosticAt) > 10 {
            Log.info("composer-lookup \(lookupDiagnostic)")
            lastDiagnostic = lookupDiagnostic
            lastDiagnosticAt = Date()
        }
        guard let result else { return Located() }
        return Located(modelButton: result.modelButton, composer: result.composer,
                       scopeAncestors: result.scopeAncestors)
    }

    /// The message box's real text (its placeholder counts as empty).
    static func composerText(_ composer: AXUIElement) -> String? {
        guard AX.role(composer) == kAXTextAreaRole as String,
              let value: String = AX.attribute(composer, kAXValueAttribute) else { return nil }
        return ComposerText.visibleText(value: value, placeholder: AX.title(composer))
    }

    /// Confirmation is read-only. Re-read the live tree even when the old input
    /// stops answering AX calls; otherwise a remount can never be discovered.
    /// User input or a window change ends the attempt rather than retargeting it.
    struct ConfirmedSelection {
        let located: Located
        let selection: CurrentSelection
    }

    /// `readOriginalAfterUserInput` lets a final step (a model switch presses no further keys)
    /// still read the original input once after a click or key press, instead of reporting a
    /// switch that already happened as failed. Reasoning steps leave it off: they keep pressing
    /// keys, and a click on another task can leave the same input showing a different chat.
    static func confirmSelection(modelID: String, effort: String? = nil, original: Located,
                                 window: AXUIElement, pid: pid_t, models: [CodexModel],
                                 since started: TimeInterval, timeout: TimeInterval = 5,
                                 readOriginalAfterUserInput: Bool = false,
                                 logPrefix: String) -> ConfirmedSelection? {
        guard let identity = original.identity else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var lastState = ""
        repeat {
            let undisturbed = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                && AX.focusedWindow(pid: pid).map { CFEqual($0, window) } == true
                && !Keyboard.userInteracted(since: started)
            guard undisturbed || readOriginalAfterUserInput else {
                Log.info("\(logPrefix) phase=confirm-stopped reason=user-or-window-changed")
                return nil
            }
            let located = Cache.current(window: window, models: models, forceRefresh: true)
            let selection = CurrentModelMatcher.selection(forButtonTitle: located.modelButton.map(AX.title) ?? "",
                                                           among: models)
            let sameContext = located.identity.map { identity.matches($0, equals: { CFEqual($0, $1) }) } ?? false
            let focused = located.composer.map { composerHasFocus($0, pid: pid) } ?? false
            let replaced = located.composer.map { !CFEqual($0, identity.input) } ?? false
            let state = "input=\(self.identity(located.composer)) original=\(self.identity(identity.input)) sameContext=\(sameContext) focused=\(focused) replaced=\(replaced) model=\(selection.modelID ?? "none") effort=\(selection.effort ?? "none") scopes=[\(located.scopeAncestors.map(self.identity).joined(separator: ","))]"
            if state != lastState {
                Log.info("\(logPrefix) phase=confirm \(state)")
                lastState = state
            }
            let userInteracted = Keyboard.userInteracted(since: started)
            if provesSelection(sameContext: sameContext, replaced: replaced, focused: focused,
                               userInteracted: userInteracted, readOriginalAfterUserInput: readOriginalAfterUserInput,
                               selection: selection, modelID: modelID, effort: effort) {
                Log.info("\(logPrefix) phase=confirmed replaced=\(replaced) afterUserInput=\(userInteracted)")
                return ConfirmedSelection(located: located, selection: selection)
            }
            // After a click, key press or window change, that one read is all; never keep polling a context the user left.
            guard undisturbed else {
                Log.info("\(logPrefix) phase=confirm-stopped reason=user-or-window-changed")
                return nil
            }
            usleep(40_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        Log.info("\(logPrefix) phase=confirm-timeout")
        return nil
    }

    /// Whether one confirmation read proves the requested model and effort.
    ///
    /// The original input's own model button is direct evidence, so with
    /// `readOriginalAfterUserInput` it proves the switch even after a click or key press
    /// (the 2026-09-25 log showed six switches Codex had already applied being reported as
    /// "Failed to switch" this way). A replaced input only matches through a shared scope,
    /// so it still needs keyboard focus and no user input to prove it is the same task.
    static func provesSelection(sameContext: Bool, replaced: Bool, focused: Bool, userInteracted: Bool,
                                readOriginalAfterUserInput: Bool, selection: CurrentSelection,
                                modelID: String, effort: String?) -> Bool {
        guard sameContext, selection.modelID == modelID, effort == nil || selection.effort == effort else { return false }
        return (readOriginalAfterUserInput && !replaced) || (focused && !userInteracted)
    }

    // MARK: - The `/model` menu

    /// Entries of the open `/model` menu, by section.
    struct ModelMenu {
        /// "Recent models": saved model + effort + speed configurations (no typing needed).
        var recent: [AXUIElement] = []
        /// "Matching models": catalogue entries shown only while a search is typed.
        var matching: [AXUIElement] = []
    }

    static let recentHeader = "Recent models"
    static let matchingHeader = "Matching models"

    /// The typing menu may be a portal anywhere in this composer's web area.
    /// Require focus on this input before using the window-wide menu lookup.
    static func modelMenu(near composer: AXUIElement) -> ModelMenu? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(composer, &pid) == .success,
              composerHasFocus(composer, pid: pid), let window = AX.focusedWindow(pid: pid) else { return nil }
        let locator = ModelMenuLocator<AXUIElement>(children: AX.children,
            isWebArea: { AX.role($0) == "AXWebArea" },
            isButton: { AX.role($0) == kAXButtonRole as String },
            header: {
                guard AX.role($0) == kAXStaticTextRole as String else { return nil }
                let text = AX.string($0, kAXValueAttribute)
                return [recentHeader, matchingHeader].contains(text) ? text : nil
            }, equals: { CFEqual($0, $1) })
        guard let menu = locator.locate(in: window, composer: composer) else { return nil }
        return ModelMenu(recent: menu.recent, matching: menu.matching)
    }

    /// The menu entry for `target`. Entry titles are Codex's UI-formatted name plus
    /// extras ("1 Opus 5.5 Extra High Standard", "GPT-6 Sol Workhorse model…"), which
    /// `CurrentModelMatcher` maps back to the catalogue entry.
    static func entry(for target: CodexModel, in items: [AXUIElement], among models: [CodexModel]) -> AXUIElement? {
        items.first { CurrentModelMatcher.model(forTitle: AX.title($0), among: models)?.id == target.id }
    }

    /// Shared cache of the located elements, touched only on `AX.queue`.
    /// Polls reuse a recent attached control; explicit switches always re-locate.
    enum Cache {
        static var located = Located()
        static var windowForLocated: AXUIElement?
        /// The text area that had keyboard focus at the last walk (see `focusMoved`).
        private static var focusedAtLastWalk: AXUIElement?
        private static var lastLocatedAt = Date.distantPast
        private static var rememberedComposer: AXUIElement?

        /// Returns cached elements when they still look right, otherwise re-locates.
        static func current(window: AXUIElement, models: [CodexModel], forceRefresh: Bool = false) -> Located {
            if windowForLocated.map({ !CFEqual($0, window) }) ?? true { rememberedComposer = nil }
            if !forceRefresh, let cachedWindow = windowForLocated, CFEqual(cachedWindow, window),
               let button = located.modelButton,
               Date().timeIntervalSince(lastLocatedAt) < 0.5,
               CurrentModelMatcher.isModelButtonTitle(AX.title(button), among: models),
               !focusMoved(window: window) {
                return located
            }
            located = locate(in: window, models: models, previousComposer: rememberedComposer)
            // A render gap should not erase the last input identity. The resolver
            // still requires it to be paired in the next live window scan.
            if let composer = located.composer { rememberedComposer = composer }
            windowForLocated = window
            focusedAtLastWalk = focusedTextArea(window: window)
            lastLocatedAt = Date()
            return located
        }

        /// True when keyboard focus is now in a text area that is neither the cached
        /// message box nor the one focused at the last walk, e.g. the user clicked into the
        /// other chat of a split view. Remembering the last one means a focused non-composer
        /// text area (such as a code viewer) triggers one walk, not one every poll.
        static func focusMoved(window: AXUIElement) -> Bool {
            guard let focused = focusedTextArea(window: window) else { return false }
            if let composer = located.composer, CFEqual(focused, composer) { return false }
            if let last = focusedAtLastWalk, CFEqual(last, focused) { return false }
            return true
        }

        /// The app's focused element when it is a text area. One or two AX calls.
        private static func focusedTextArea(window: AXUIElement) -> AXUIElement? {
            var pid: pid_t = 0
            guard AXUIElementGetPid(window, &pid) == .success,
                  let focused: AXUIElement = AX.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
                  AX.role(focused) == kAXTextAreaRole as String else { return nil }
            return focused
        }

        static func invalidate() {
            located = Located()
            windowForLocated = nil
            focusedAtLastWalk = nil
            rememberedComposer = nil
            lastLocatedAt = .distantPast
        }
    }
}

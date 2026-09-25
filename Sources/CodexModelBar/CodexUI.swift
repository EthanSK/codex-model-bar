import AppKit
import ApplicationServices
import CodexModelBarCore

/// Knowledge of Codex's UI as exposed to Accessibility (verified on desktop 26.917).
///
/// Composer area, simplified. The `/model` menu (opened with Codex's own Control+Shift+M
/// shortcut) is rendered **inline above the message box**, not in a portal:
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
        return Located(modelButton: result.modelButton, composer: result.composer)
    }

    /// The message box's real text (its placeholder counts as empty).
    static func composerText(_ composer: AXUIElement) -> String {
        ComposerText.visibleText(value: AX.string(composer, kAXValueAttribute), placeholder: AX.title(composer))
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

    /// The open `/model` menu next to `composer`, or nil when it is closed.
    ///
    /// Searches outward from the message box (the menu is its sibling), level by level,
    /// with a node cap per level so a long chat is never walked in full.
    static func modelMenu(near composer: AXUIElement) -> ModelMenu? {
        var ancestor = composer
        for _ in 0..<4 {
            guard let parent = AX.parent(ancestor) else { return nil }
            ancestor = parent
            let headers = AX.all(in: ancestor, limit: 2_500) {
                AX.role($0) == kAXStaticTextRole as String
                    && [recentHeader, matchingHeader].contains(AX.string($0, kAXValueAttribute))
            }
            guard !headers.isEmpty else { continue }
            var menu = ModelMenu()
            for header in headers {
                let items = sectionButtons(forHeader: header)
                if AX.string(header, kAXValueAttribute) == recentHeader {
                    menu.recent = items
                } else {
                    menu.matching = items
                }
            }
            return menu
        }
        return nil
    }

    /// The buttons of the section a header text belongs to: the closest ancestor (up
    /// to three levels) that has button children.
    private static func sectionButtons(forHeader header: AXUIElement) -> [AXUIElement] {
        var node = header
        for _ in 0..<3 {
            guard let parent = AX.parent(node) else { break }
            node = parent
            let buttons = AX.children(node).filter { AX.role($0) == kAXButtonRole as String }
            if !buttons.isEmpty { return buttons }
        }
        return []
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

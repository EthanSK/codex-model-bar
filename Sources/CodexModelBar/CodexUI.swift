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

    /// Finds the composer the user is working in: its model button and message box.
    ///
    /// Codex can show two chats at once (e.g. a side chat next to the main one), each
    /// with its own composer. The one whose message box has keyboard focus wins; with no
    /// focused message box, the first composer in the window is used.
    static func locate(in window: AXUIElement, models: [CodexModel]) -> Located {
        let all = locateAll(in: window, models: models)
        return all.first { $0.composer.map(AX.isFocused) == true } ?? all.first ?? Located()
    }

    /// Every composer in the window (model button + its message box), in document order.
    ///
    /// The message box is searched for near its button (the side panel can contain
    /// other text areas, e.g. a code viewer), with the first text area in the window as
    /// a fallback when no button is paired with one.
    static func locateAll(in window: AXUIElement, models: [CodexModel]) -> [Located] {
        var found: [Located] = []
        var firstTextArea: AXUIElement?
        var visited = 0
        var stack: [AXUIElement] = [window]
        while let element = stack.popLast(), visited < 30_000 {
            visited += 1
            let role = AX.role(element)
            if role == kAXPopUpButtonRole as String,
               CurrentModelMatcher.isModelButtonTitle(AX.title(element), among: models) {
                found.append(Located(modelButton: element, composer: messageBox(near: element)))
            } else if firstTextArea == nil, role == kAXTextAreaRole as String {
                firstTextArea = element
            }
            stack.append(contentsOf: AX.children(element).reversed())
        }
        if found.count == 1, found[0].composer == nil { found[0].composer = firstTextArea }
        return found
    }

    /// The text area sharing the nearest ancestor with the model button.
    private static func messageBox(near button: AXUIElement) -> AXUIElement? {
        var ancestor = button
        for _ in 0..<6 {
            guard let parent = AX.parent(ancestor) else { return nil }
            ancestor = parent
            if let area = AX.first(in: ancestor, limit: 400, where: { AX.role($0) == kAXTextAreaRole as String }) {
                return area
            }
        }
        return nil
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

    /// True when a `/model` menu is open anywhere in the window (bounded walk; used only
    /// on a failure path).
    static func anyModelMenuIsOpen(in window: AXUIElement) -> Bool {
        AX.first(in: window, limit: 30_000) {
            AX.role($0) == kAXStaticTextRole as String && AX.string($0, kAXValueAttribute) == recentHeader
        } != nil
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
    /// The watcher refreshes it; the switcher reuses it to skip a 0.5 s walk.
    enum Cache {
        static var located = Located()
        static var windowForLocated: AXUIElement?
        /// The text area that had keyboard focus at the last walk (see `focusMoved`).
        private static var focusedAtLastWalk: AXUIElement?

        /// Returns cached elements when they still look right, otherwise re-locates.
        static func current(window: AXUIElement, models: [CodexModel], forceRefresh: Bool = false) -> Located {
            if !forceRefresh, let cachedWindow = windowForLocated, CFEqual(cachedWindow, window),
               let button = located.modelButton,
               CurrentModelMatcher.isModelButtonTitle(AX.title(button), among: models),
               !focusMoved(window: window) {
                return located
            }
            located = locate(in: window, models: models)
            windowForLocated = window
            focusedAtLastWalk = focusedTextArea(window: window)
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
        }
    }
}

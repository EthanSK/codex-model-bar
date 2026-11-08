/*
 ============================================================================
 **MOVED FROM — MOVE HISTORY**
 2026-11-08: Sources/CodexModelBar/CodexUI.swift / composerHasFocus, focusedSpeedInput, speedConversation, speedInput, inputLocator. Extraction of existing native
 shortcut/focus code so Model Bar and Agentic Mouse embed the same implementation
 without depending on either running app. Task: Codex native shortcuts.
 ============================================================================
 */
import AppKit
import ApplicationServices
import CodexModelBarCore

public enum CodexComposerFocus {
    /// Chromium can temporarily expose a group/web area as app focus while the
    /// input itself retains AXFocused. Never accept a different focused input.
    public static func hasFocus(_ composer: AXUIElement, pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              CodexAX.keyboardOwnerPID() == pid,
              let focused: AXUIElement = CodexAX.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
        else { return false }
        if CFEqual(focused, composer) { return true }
        return [kAXGroupRole as String, kAXWindowRole as String, "AXWebArea"].contains(CodexAX.role(focused))
            && CodexAX.isFocused(composer)
    }

    /// Avoid transcript discovery when Codex already identifies an attached focused chat input.
    public static func focusedInput(in window: AXUIElement, previousComposer: AXUIElement? = nil) -> AXUIElement? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              let focused: AXUIElement = CodexAX.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
        else { return nil }
        if let input = inputLocator.focusedInput(in: window, focused: focused) { return input }
        guard let pairedComposer = previousComposer
        else { return nil }
        if CFEqual(pairedComposer, focused) { return focused } // Codex drops the Conversation landmark while a new or hidden transcript loads (2026-10-27 22:15:47 UTC: sole focused input, region=none); the composer the model lookup already paired is still this pane's input.
        return inputLocator.regionlessInput(pairedComposer, in: window, focused: focused)
    }

    /// Capture the intended pane before activation can restore the previously used input.
    public static func conversation(in window: AXUIElement, previousComposer: AXUIElement? = nil) -> AXUIElement? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return nil }
        let focused: AXUIElement? = CodexAX.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
        let previous = previousComposer
        let region = inputLocator.conversation(in: window, focused: focused, previousComposer: previous)
        return region
    }

    /// Speed needs the chat input, not the model button that may mount later.
    public static func input(in conversation: AXUIElement) -> AXUIElement? {
        inputLocator.input(inConversation: conversation) // The pane supplies identity; Codex changes its input label between new, working and Work-mode chats.
    }

    private static func isConversationRegion(_ node: AXUIElement) -> Bool {
        CodexAX.string(node, kAXSubroleAttribute) == "AXLandmarkRegion"
            && CodexAX.string(node, kAXDescriptionAttribute) == "Conversation" // Same structural identity measured by Agent Flow's pane_focuser.py; no app-version gate.
    }

    private static var inputLocator: ComposerLocator<AXUIElement> {
        ComposerLocator(children: CodexAX.children, parent: CodexAX.parent,
                        isTextArea: { CodexAX.role($0) == kAXTextAreaRole as String },
                        isModelButton: { _ in false }, equals: { CFEqual($0, $1) },
                        hasKeyboardFocus: CodexAX.isFocused,
                        isWebArea: { CodexAX.role($0) == "AXWebArea" },
                        isConversationRegion: isConversationRegion)
    }

}

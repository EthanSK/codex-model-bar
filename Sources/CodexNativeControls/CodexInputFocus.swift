/*
 ============================================================================
 **MOVED FROM — MOVE HISTORY**
 2026-11-08: Sources/CodexModelBar/SpeedInputFocus.swift. Extraction of existing native
 shortcut/focus code so Model Bar and Agentic Mouse embed the same implementation
 without depending on either running app. Task: Codex native shortcuts.
 ============================================================================
 */
import AppKit
import ApplicationServices

/// The actual keyboard owner can be Agent Flow's nonactivating panel while Codex remains the active app.
public struct CodexInputFocus {
    public let application: NSRunningApplication
    public let window: AXUIElement?
    public let input: AXUIElement
    public let selection: AXValue?

    /// Retain the exact input and selection, rather than restoring whichever window is frontmost later.
    public static func capture() -> Self? {
        guard let input: AXUIElement = CodexAX.attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
        else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(input, &pid) == .success,
              let application = NSRunningApplication(processIdentifier: pid) else { return nil }
        return Self(application: application,
                    window: CodexAX.attribute(input, kAXWindowAttribute) ?? CodexAX.focusedWindow(pid: pid),
                    input: input, selection: CodexAX.attribute(input, kAXSelectedTextRangeAttribute))
    }

    /// Shared by speed and reasoning: release Agent Flow's nonactivating keyboard panel before focusing Codex.
    public static func activate(_ codex: NSRunningApplication, canFocus: () -> Bool) -> Bool {
        guard canFocus() else { return false }
        if codex.isActive, CodexAX.keyboardOwnerPID() == codex.processIdentifier { return true }
        if codex.isActive { // Re-activating Codex alone cannot release Agent Flow's key panel; reuse the established accessory-first handoff.
            DispatchQueue.main.sync { NSApp.activate(ignoringOtherApps: true) }
            guard CodexControlWait.until(timeout: 0.6, { canFocus() && NSRunningApplication.current.isActive }) else { return false }
        }
        guard canFocus() else { return false }
        DispatchQueue.main.sync { _ = codex.activate() }
        return CodexControlWait.until(timeout: 1, { canFocus() && codex.isActive && CodexAX.keyboardOwnerPID() == codex.processIdentifier })
    }

    /// Reuse the click-focus helper's AX focus write and caret placement, without its diagnostic hold wait.
    public static func focus(_ input: AXUIElement, pid: pid_t, placeCaret: Bool, timeout: TimeInterval = 0.2,
                      canFocus: () -> Bool) -> Bool {
        let focused = CodexComposerFocus.hasFocus(input, pid: pid)
        if focused && !placeCaret { return true }
        if !focused {
            guard canFocus(), AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
                  CodexControlWait.until(timeout: timeout, { canFocus() && CodexComposerFocus.hasFocus(input, pid: pid) }) else { return false }
        }
        if !placeCaret { return true } // Reasoning shortcuts insert no text, so preserve the draft's existing selection.
        // The measured Agent Flow helper needed a caret range after AXFocused. Append instead of replacing a selected draft (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
        guard canFocus(), let count: Int = CodexAX.attribute(input, kAXNumberOfCharactersAttribute) else { return false }
        var range = CFRange(location: count, length: 0)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(input, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// Return to the captured typing panel/input only while the caller still owns the temporary handoff.
    public func restore(canRestore: () -> Bool, log: (String) -> Void = { _ in }) {
        guard canRestore(), !application.isTerminated else { return }
        DispatchQueue.main.sync { _ = application.activate(options: [.activateIgnoringOtherApps]) }
        guard CodexControlWait.until(timeout: 0.6, { canRestore() && application.isActive }) else {
            log("toolbar-focus phase=restore-focus pid=\(application.processIdentifier) result=activation-failed")
            return
        }
        if let window { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        guard canRestore() else { return }
        let error = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if error == .success, let selection, canRestore() {
            AXUIElementSetAttributeValue(input, kAXSelectedTextRangeAttribute as CFString, selection)
        }
        let restored = error == .success && CodexControlWait.until(timeout: 0.2, {
            canRestore() && CodexAX.keyboardOwnerPID() == application.processIdentifier && CodexAX.isFocused(input)
        })
        log("toolbar-focus phase=restore-focus pid=\(application.processIdentifier) result=\(error.rawValue) confirmed=\(restored)")
    }
}

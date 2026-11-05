import AppKit
import ApplicationServices

/// The actual keyboard owner can be Agent Flow's nonactivating panel while Codex remains the active app.
struct SpeedInputFocus {
    let application: NSRunningApplication
    let window: AXUIElement?
    let input: AXUIElement
    let selection: AXValue?

    /// Retain the exact input and selection, rather than restoring whichever window is frontmost later.
    static func capture() -> Self? {
        guard let input: AXUIElement = AX.attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
        else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(input, &pid) == .success,
              let application = NSRunningApplication(processIdentifier: pid) else { return nil }
        return Self(application: application,
                    window: AX.attribute(input, kAXWindowAttribute) ?? AX.focusedWindow(pid: pid),
                    input: input, selection: AX.attribute(input, kAXSelectedTextRangeAttribute))
    }

    /// Shared by speed and reasoning: release Agent Flow's nonactivating keyboard panel before focusing Codex.
    static func activate(_ codex: NSRunningApplication, canFocus: () -> Bool) -> Bool {
        guard canFocus() else { return false }
        if codex.isActive, AX.keyboardOwnerPID() == codex.processIdentifier { return true }
        if codex.isActive { // Re-activating Codex alone cannot release Agent Flow's key panel; reuse the established accessory-first handoff.
            DispatchQueue.main.sync { NSApp.activate(ignoringOtherApps: true) }
            guard ModelSwitcher.waitUntil(timeout: 0.6, { canFocus() && NSRunningApplication.current.isActive }) else { return false }
        }
        guard canFocus() else { return false }
        DispatchQueue.main.sync { _ = codex.activate() }
        return ModelSwitcher.waitUntil(timeout: 1, { canFocus() && codex.isActive && AX.keyboardOwnerPID() == codex.processIdentifier })
    }

    /// Reuse the click-focus helper's AX focus write and caret placement, without its diagnostic hold wait.
    static func focus(_ input: AXUIElement, pid: pid_t, placeCaret: Bool, timeout: TimeInterval = 0.2,
                      canFocus: () -> Bool) -> Bool {
        let focused = CodexUI.composerHasFocus(input, pid: pid)
        if focused && !placeCaret { return true }
        if !focused {
            guard canFocus(), AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
                  ModelSwitcher.waitUntil(timeout: timeout, { canFocus() && CodexUI.composerHasFocus(input, pid: pid) }) else { return false }
        }
        if !placeCaret { return true } // Reasoning shortcuts insert no text, so preserve the draft's existing selection.
        // The measured Agent Flow helper needed a caret range after AXFocused. Append instead of replacing a selected draft (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
        guard canFocus(), let count: Int = AX.attribute(input, kAXNumberOfCharactersAttribute) else { return false }
        var range = CFRange(location: count, length: 0)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(input, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// Return to the captured typing panel/input only while the caller still owns the temporary handoff.
    func restore(canRestore: () -> Bool) {
        guard canRestore(), !application.isTerminated else { return }
        DispatchQueue.main.sync { _ = application.activate(options: [.activateIgnoringOtherApps]) }
        guard ModelSwitcher.waitUntil(timeout: 0.6, { canRestore() && application.isActive }) else {
            Log.info("toolbar-focus phase=restore-focus pid=\(application.processIdentifier) result=activation-failed")
            return
        }
        if let window { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        guard canRestore() else { return }
        let error = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if error == .success, let selection, canRestore() {
            AXUIElementSetAttributeValue(input, kAXSelectedTextRangeAttribute as CFString, selection)
        }
        let restored = error == .success && ModelSwitcher.waitUntil(timeout: 0.2, {
            canRestore() && AX.keyboardOwnerPID() == application.processIdentifier && AX.isFocused(input)
        })
        Log.info("toolbar-focus phase=restore-focus pid=\(application.processIdentifier) result=\(error.rawValue) confirmed=\(restored)")
    }
}

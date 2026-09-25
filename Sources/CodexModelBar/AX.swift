import AppKit
import ApplicationServices

/// Thin, synchronous helpers over the macOS Accessibility (AX) C API.
///
/// Codex's UI is web content inside a Chromium-based shell; Chromium publishes that
/// content as an AX tree once an assistive client asks for it. We read it to:
///  - find the composer's model button (`AXPopUpButton`, title like "Opus 5.5 Extra High"),
///  - find entries in Codex's `/model` menu so we can press the exact one.
///
/// All calls block on IPC to Codex, so callers run them on `AX.queue`, never the
/// main thread (a full tree walk takes ~0.5 s on a busy chat).
enum AX {
    /// Serial queue for every AX call, so tree walks never overlap or block the UI.
    static let queue = DispatchQueue(label: "com.ethansk.codex-model-bar.ax", qos: .userInitiated)

    /// True when this app may use Accessibility (needed to read Codex and send keys).
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's "allow Accessibility" prompt (only has an effect when untrusted).
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func string(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) ?? ""
    }

    static func role(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute) }
    static func title(_ element: AXUIElement) -> String { string(element, kAXTitleAttribute) }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }

    static func parent(_ element: AXUIElement) -> AXUIElement? {
        attribute(element, kAXParentAttribute)
    }

    /// The element's own focused flag (for a text area: it has the caret).
    static func isFocused(_ element: AXUIElement) -> Bool {
        attribute(element, kAXFocusedAttribute) ?? false
    }

    /// Performs the element's default action (a click, for buttons and menu items).
    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Asks a Chromium/Electron-style app to build its web AX tree. Screen readers do
    /// the same; failure is harmless (some builds expose the tree regardless).
    static func enableWebAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// The window the user is working in: focused window first, then main window.
    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        if let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) { return window }
        return attribute(app, kAXMainWindowAttribute)
    }

    /// Depth-first search returning the first element that satisfies `match`.
    /// `limit` caps the number of visited nodes so a pathological tree can't hang us.
    static func first(in root: AXUIElement, limit: Int = 25_000, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        var visited = 0
        var stack: [AXUIElement] = [root]
        while let element = stack.popLast() {
            visited += 1
            if visited > limit { return nil }
            if match(element) { return element }
            // Reverse so children are visited in document order (stack is LIFO).
            stack.append(contentsOf: children(element).reversed())
        }
        return nil
    }

    /// Depth-first search collecting every element that satisfies `match`, in document order.
    static func all(in root: AXUIElement, limit: Int = 25_000, where match: (AXUIElement) -> Bool) -> [AXUIElement] {
        var visited = 0
        var found: [AXUIElement] = []
        var stack: [AXUIElement] = [root]
        while let element = stack.popLast() {
            visited += 1
            if visited > limit { break }
            if match(element) { found.append(element) }
            stack.append(contentsOf: children(element).reversed())
        }
        return found
    }
}

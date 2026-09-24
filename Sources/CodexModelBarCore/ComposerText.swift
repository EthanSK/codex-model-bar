import Foundation

/// Pure helpers for reasoning about the text in Codex's message box.
///
/// The bar never edits the message box directly. It sometimes types a search into
/// Codex's `/model` menu (the menu reads its search from the message box), and these
/// helpers decide whether that search can be removed again without touching anything
/// the user wrote.
public enum ComposerText {
    /// The message box's real text, given its Accessibility value and placeholder.
    ///
    /// When the box is empty, Chromium reports the placeholder paragraph as the value
    /// (observed on Codex desktop 26.917: value `"\nDo anything"`, title `Do anything`).
    /// Treat that as empty so before/after comparisons are about actual text.
    public static func visibleText(value: String, placeholder: String) -> String {
        guard !placeholder.isEmpty else { return value }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == placeholder ? "" : value
    }

    /// True when `after` is `before` with exactly `query` inserted at one position,
    /// i.e. the only change in the message box is the search the bar typed.
    ///
    /// Only then is it safe to press Backspace `query.count` times: the caret sits right
    /// after the search (we just typed it) and nothing else changed. Any other
    /// difference (lost keystrokes, user edits) means we must not delete anything.
    public static func onlyAdded(_ query: String, before: String, after: String) -> Bool {
        guard !query.isEmpty, after.count == before.count + query.count else { return false }
        let a = Array(after), b = Array(before), q = Array(query)
        // Try every insertion point; drafts are short enough that this is instant.
        for start in 0...b.count where Array(a[start..<(start + q.count)]) == q {
            if Array(a[..<start]) == Array(b[..<start]),
               Array(a[(start + q.count)...]) == Array(b[start...]) {
                return true
            }
        }
        return false
    }
}

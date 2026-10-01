import Foundation

/// One fixed local action; a URL cannot supply a model, text or arbitrary command.
public enum MouseShortcut {
    public static let astraModelID = "gpt-6-astra"
    public static func isAstraUltrafast(_ url: URL) -> Bool {
        url.scheme == "codex-model-bar" && url.host == "astra-ultrafast"
            && url.path.isEmpty && url.query == nil && url.fragment == nil
            && url.user == nil && url.password == nil && url.port == nil
    }
}

/// Codex exposes the speed slash command's state in its description. The command
/// toggles OFF when selected, so never choose that entry a second time.
public enum UltrafastCommandState: Equatable {
    case enabled, disabled

    public static func read(title: String) -> Self? {
        let text = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        guard text.hasPrefix("ultrafast ") || text.hasPrefix("/ultrafast ") else { return nil }
        if text.contains("turn off ultrafast and return to standard speed") { return .enabled }
        if text.contains("the fastest available responses for latency-sensitive work") { return .disabled }
        return nil
    }
}

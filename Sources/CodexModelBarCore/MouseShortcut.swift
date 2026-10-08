import Foundation

/// Fixed local actions only; a URL cannot supply text or an arbitrary command.
public enum MouseShortcut {
    public enum Action { case astraUltrafast, speedUp, speedDown }
    public static let astraModelID = "gpt-6-astra"
    public static func isAstraUltrafast(_ url: URL) -> Bool {
        action(for: url) == .astraUltrafast
    }
    public static func action(for url: URL) -> Action? {
        guard url.scheme == "codex-model-bar", url.path.isEmpty, url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        switch url.host {
        case "astra-ultrafast": return .astraUltrafast
        case "speed-up": return .speedUp
        case "speed-down": return .speedDown
        default: return nil
        }
    }
}

import Foundation

/// Fixed local actions only; a URL cannot supply text or an arbitrary command.
public enum MouseShortcut {
    public enum Action { case astraUltrafast, speedUp, speedDown, speedCancel, reasoningUp, reasoningDown, reasoningCancel }
    // "Astra Ultrafast" follows the newest visible Astra that advertises this speed.
    public static func astraUltrafastModel(in models: [CodexModel]) -> CodexModel? {
        models.filter {
            !$0.hidden && $0.speedTiers.contains(.ultrafast)
                && $0.id.range(of: #"^gpt-\d+(?:\.\d+)?-astra$"#, options: .regularExpression) != nil
        }.max { $0.id.compare($1.id, options: .numeric) == .orderedAscending }
    }
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
        case "speed-cancel": return .speedCancel
        case "reasoning-up": return .reasoningUp
        case "reasoning-down": return .reasoningDown
        case "reasoning-cancel": return .reasoningCancel
        default: return nil
        }
    }
}

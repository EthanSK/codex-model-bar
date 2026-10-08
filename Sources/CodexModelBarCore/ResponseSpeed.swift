import Foundation

/// The three explicit choices in Codex's Speed submenu, not its toggling slash commands.
public enum ResponseSpeed: String, CaseIterable, Sendable {
    case standard = "Standard"
    case fast = "Fast"
    case ultrafast = "Ultrafast"

    /// Codex gives its speed control the accessible name `Speed {speed}`.
    public static func controlValue(title: String) -> Self? {
        let title = normalized(title)
        return allCases.first { title == "speed \($0.rawValue.lowercased())" }
    }

    /// Match only the speed labels and their own descriptions, not a model or a slash command.
    public static func menuValue(title: String) -> Self? {
        let title = normalized(title)
        switch title {
        case "standard", "standard default speed": return .standard
        case "fast": return .fast
        case "ultrafast", "ultrafast the fastest available responses for latency-sensitive work": return .ultrafast
        default:
            guard title.hasPrefix("fast "), title.hasSuffix("x speed, more usage"),
                  let multiplier = Double(title.dropFirst(5).dropLast("x speed, more usage".count)),
                  multiplier.isFinite, multiplier > 0 else { return nil }
            return .fast
        }
    }

    private static func normalized(_ title: String) -> String {
        title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

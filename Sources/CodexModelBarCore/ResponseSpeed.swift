import Foundation

/// Codex's response speeds, ordered for the mouse wheel shortcuts.
public enum ResponseSpeed: String, CaseIterable, Sendable {
    case standard = "Standard"
    case fast = "Fast"
    case ultrafast = "Ultrafast"

    /// Step only through choices that Codex actually exposes, without wrapping.
    public func stepped(up: Bool, available: Set<Self>) -> Self {
        let choices = Self.allCases.filter { $0 == .standard || available.contains($0) }
        guard let index = choices.firstIndex(of: self) else { return self }
        return choices[max(0, min(choices.count - 1, index + (up ? 1 : -1)))]
    }
}

/// Slash commands toggle an already selected tier OFF. Read the native description
/// before Return so an icon remains an explicit selection, including repeated clicks.
public enum SpeedCommandState: Equatable {
    case enabled, disabled

    public static func read(title: String, speed: ResponseSpeed) -> Self? {
        guard speed != .standard else { return nil }
        let text = title.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        let name = speed.rawValue.lowercased()
        let description: String
        if text.hasPrefix("/\(name) ") { description = String(text.dropFirst(name.count + 2)) }
        else if text.hasPrefix("\(name) ") { description = String(text.dropFirst(name.count + 1)) }
        else { return nil }
        if description == "turn off \(name) and return to standard speed" { return .enabled }
        switch speed {
        case .standard: return nil
        case .fast:
            let suffix = "x speed, increased usage"
            guard description.hasSuffix(suffix), let multiplier = Double(description.dropLast(suffix.count)),
                  multiplier.isFinite, multiplier > 0 else { return nil }
            return .disabled
        case .ultrafast:
            return description == "the fastest available responses for latency-sensitive work" ? .disabled : nil
        }
    }
}

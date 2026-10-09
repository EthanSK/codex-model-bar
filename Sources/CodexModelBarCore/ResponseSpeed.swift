import Foundation

/// Codex's response speed choices.
public enum ResponseSpeed: String, CaseIterable, Sendable {
    case standard = "Standard"
    case fast = "Fast"
    case ultrafast = "Ultrafast"
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
            let expected = "the fastest available responses for latency-sensitive work"
            return description == expected || description == expected + "." ? .disabled : nil // Live model metadata adds a period; the renderer's default description omits it.
        }
    }
}

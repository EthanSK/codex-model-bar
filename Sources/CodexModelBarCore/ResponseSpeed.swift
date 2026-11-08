// Speed values, passive observations and native-cycle planning shared by the toolbar.
import Foundation

/// Codex's response speed choices.
public enum ResponseSpeed: String, CaseIterable, Codable, Sendable {
    case standard = "Standard"
    case fast = "Fast"
    case ultrafast = "Ultrafast"

    /// Reads one of a model's `additionalSpeedTiers` entries (`"fast"`, `"ultrafast"`); unknown tiers are ignored.
    public init?(speedTier: String) {
        guard let speed = Self.allCases.first(where: { $0 != .standard && $0.rawValue.lowercased() == speedTier }) else { return nil }
        self = speed
    }

    /// Reads the top-level `service_tier` from Codex's `~/.codex/config.toml`; nil when it is absent or unrecognised.
    ///
    /// Codex desktop (26.1027) saves every chat speed change there as the new-chat default, including a `/fast` or
    /// `/ultrafast` typed in Codex itself: `default` (Standard), `priority` (Fast) or `ultrafast`.
    public init?(codexConfig: String) {
        for line in codexConfig.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil } // Top-level keys end at the first table; a `profiles.<name>.service_tier` is not read because no profile is active here.
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "service_tier" else { continue }
            switch parts[1].prefix(while: { $0 != "#" }).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")) {
            case "default": self = .standard
            case "priority", "fast": self = .fast // Codex writes `priority` for Fast; `fast` is its catalogue name for the same tier.
            case "ultrafast": self = .ultrafast
            default: return nil
            }
            return
        }
        return nil
    }

    /// The slash command Codex runs for this tier. Codex has no `/standard`.
    public var command: String? {
        switch self {
        case .standard: return nil
        case .fast, .ultrafast: return "/\(rawValue.lowercased())"
        }
    }
}

/// Best-effort speed inferred from commands the bar posted, each starting from the speed the toolbar last showed; shared by its buttons and wheel.
public struct ResponseSpeedMemory {
    public var speed: ResponseSpeed? // Nil only when no valid saved estimate exists; the existing unknown-speed Ultrafast assumption still applies.

    public init() {}

    /// Restores the last recorded speed from one bounded, plain-text value.
    public init(contentsOf url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 11) ?? Data() // The longest stored value is "Ultrafast\n" (10 bytes); reject larger or corrupt files without reading them all.
        guard data.count <= 10, let text = String(data: data, encoding: .utf8),
              let restored = ResponseSpeed(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        speed = restored
    }

    /// Replaces the same tiny file after a command; never appends a growing history.
    public func write(to url: URL) throws {
        guard let speed else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((speed.rawValue + "\n").utf8).write(to: url, options: .atomic) // An interrupted write must not leave half a speed name for the next launch.
    }

    /// Standard repeats the remembered tier, assuming Ultrafast when no command has been tracked.
    public func toggle(for requested: ResponseSpeed) -> ResponseSpeed {
        requested == .standard ? (speed ?? .ultrafast) : requested // Ethan accepts an Ultrafast guess before the bar has tracked speed; do not restore UI discovery (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
    }

    /// Repeating a tier turns it off; switching tiers replaces the previous tier.
    public mutating func recordPostedToggle(_ toggled: ResponseSpeed) {
        guard toggled != .standard else { return }
        speed = speed == toggled ? .standard : toggled // From unknown, retain the posted tier so a second Standard click can undo it if the assumption was wrong.
    }

    /// The speed to show for a chat from Codex's model-button icon, the model's offered tiers and Codex's saved speed choice.
    ///
    /// Codex (desktop 26.1027) draws one 14 pt icon in the model button only while Fast or Ultrafast is on, so its absence
    /// proves Standard. Both bolts expose identical Accessibility data, so only a model offering both tiers (GPT-6.1 Sol,
    /// GPT-6 Astra) needs this estimate to choose between them. Ethan asked for best-effort detection on 2026-10-31 (Claude session 4901285c); this passive read of the already-located button replaces the "never read speed from the UI" rule only for display, never to verify a sent command.
    public func displayedSpeed(iconVisible: Bool, offered: [ResponseSpeed], saved: ResponseSpeed?) -> ResponseSpeed {
        guard iconVisible else { return .standard }
        if offered.count == 1, let only = offered.first { return only } // Most models offer only Fast, so the icon alone identifies it.
        for estimate in [saved, speed] { // Codex's saved choice comes first: it also records a `/ultrafast` Ethan types in Codex, which the bar's own memory missed and showed as Fast (2026-11-03, Claude session 719981e1).
            if let estimate, estimate != .standard, offered.isEmpty || offered.contains(estimate) { return estimate }
        }
        return .ultrafast // The existing unknown-speed assumption; it also matches Ethan's `service_tier = "ultrafast"` default for new chats.
    }
}

/// Slash commands toggle an already selected tier OFF. The combined Astra shortcut
/// reads their descriptions; ordinary speed buttons use only ResponseSpeedMemory.
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
            guard let suffix = ["x speed, increased usage", "x speed, more usage"].first(where: description.hasSuffix),
                  let multiplier = Double(description.dropLast(suffix.count)),
                  multiplier.isFinite, multiplier > 0 else { return nil }
            return .disabled
        case .ultrafast:
            let expected = "the fastest available responses for latency-sensitive work"
            return description == expected || description == expected + "." ? .disabled : nil // Live model metadata adds a period; the renderer's default description omits it.
        }
    }
}

/// Plans the native forward-only cycle without pretending that Shift reverses it.
/// Codex 26.1103 cycles Standard, then the model's offered tiers in catalog order.
/// Preserve the existing controls: repeating Fast/Ultrafast toggles it off, and
/// Standard turns the estimated active tier off. The passive estimate can be stale;
/// Ethan prefers a best-effort request to confirmation queries or retries.
public struct NativeSpeedPlan: Equatable {
    public let target: ResponseSpeed
    public let steps: [ResponseSpeed]
    public var presses: Int { steps.count }

    public init?(requested: ResponseSpeed, current: ResponseSpeed, offered: [ResponseSpeed]) {
        let cycle = [.standard] + offered.reduce(into: [ResponseSpeed]()) { result, speed in
            if speed != .standard && !result.contains(speed) { result.append(speed) }
        }
        let target: ResponseSpeed = requested == .standard || requested == current ? .standard : requested
        guard let to = cycle.firstIndex(of: target) else { return nil }
        self.target = target
        let from = cycle.firstIndex(of: current) ?? -1
        let count = from < 0 ? to + 1 : (to - from + cycle.count) % cycle.count
        steps = (0..<count).map { cycle[(from + $0 + 1) % cycle.count] }
    }
}

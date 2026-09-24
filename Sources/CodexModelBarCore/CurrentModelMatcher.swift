import Foundation

public struct CurrentSelection: Equatable, Sendable {
    public let modelID: String?
    public let effort: String?

    public init(modelID: String?, effort: String?) {
        self.modelID = modelID
        self.effort = effort
    }
}

/// Works out which model a piece of Codex UI refers to from its accessibility title.
///
/// Titles seen on Codex desktop 26.917 (AX titles of web buttons):
///  - composer model button:   `Opus 5.5 Extra High`, `GPT-6 Sol Medium`
///  - model menu, recent item: `1 Opus 5.5 Extra High Standard`
///  - model menu, search hit:  `GPT-6 Sol Workhorse model for coding and everyday work.`
///
/// Two quirks make a plain `hasPrefix(displayName)` wrong:
///  1. Codex **reformats** display names in its UI: the catalogue says `GPT-6-Sol` /
///     `GPT-5.6-Sol`, the UI shows `GPT-6 Sol` / `GPT-5.6 Sol`. We therefore compare a
///     normalised form where hyphens/underscores become spaces.
///  2. There is no separator between the name and what follows (effort label or
///     description), so we require a word boundary after the name and pick the
///     **longest** matching name (so `GPT-6` can never shadow `GPT-6-Sol`).
public enum CurrentModelMatcher {
    private static let effortLabels: [(slug: String, label: String)] = [
        ("xhigh", "extra high"), ("ultra", "ultra"), ("medium", "medium"),
        ("high", "high"), ("low", "low"), ("max", "max"),
    ]

    public static func selection(forButtonTitle title: String, among models: [CodexModel]) -> CurrentSelection {
        guard let model = model(forTitle: title, among: models) else {
            return CurrentSelection(modelID: nil, effort: nil)
        }
        let normalized = normalize(title)
        let name = normalize(model.displayName)
        let suffix = normalized.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        let effort = effortLabels.first { suffix == $0.label }.map(\.slug)
        return CurrentSelection(modelID: model.id, effort: effort)
    }

    public static func label(forEffort effort: String) -> String {
        switch effort {
        case "xhigh": return "Extra High"
        case "ultra": return "Ultra"
        case "max": return "Max"
        case "high": return "High"
        case "medium": return "Medium"
        case "low": return "Low"
        default: return effort.capitalized
        }
    }
    /// Lowercases, turns `-`/`_` into spaces and collapses whitespace.
    public static func normalize(_ text: String) -> String {
        let mapped = text.lowercased().map { ch -> Character in
            (ch == "-" || ch == "_") ? " " : ch
        }
        return String(mapped)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Returns the model whose (normalised) display name is the longest word-bounded
    /// prefix of the (normalised) title. A leading menu index such as `1 ` is ignored.
    public static func model(forTitle title: String, among models: [CodexModel]) -> CodexModel? {
        var text = normalize(title)
        // Recent-model menu items start with their 1…9 keyboard index.
        if let space = text.firstIndex(of: " "),
           text[..<space].allSatisfy(\.isNumber), text[..<space].count <= 2 {
            text = String(text[text.index(after: space)...])
        }
        guard !text.isEmpty else { return nil }

        var best: (model: CodexModel, length: Int)?
        for model in models {
            let name = normalize(model.displayName)
            guard !name.isEmpty, text.hasPrefix(name) else { continue }
            // Word boundary: end of title or a space right after the name.
            let rest = text.dropFirst(name.count)
            if let next = rest.first, next != " " { continue }
            if name.count > (best?.length ?? -1) { best = (model, name.count) }
        }
        return best?.model
    }

    /// Compatibility wrapper used for the composer's model button.
    public static func model(forButtonTitle title: String, among models: [CodexModel]) -> CodexModel? {
        model(forTitle: title, among: models)
    }

    /// True when `title` starts with one of the known model names. Used to pick the
    /// composer's model button out of all the window's popup buttons (the others —
    /// permissions, chat actions, sidebar menus — never match).
    public static func isModelButtonTitle(_ title: String, among models: [CodexModel]) -> Bool {
        model(forTitle: title, among: models) != nil
    }
}

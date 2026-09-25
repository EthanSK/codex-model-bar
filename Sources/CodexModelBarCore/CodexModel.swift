import Foundation

/// One model the Codex desktop app offers in its model picker.
///
/// Values come from Codex's cache or `model/list` on its bundled app-server,
/// including custom entries such as the Claude bridge models. The bar retains
/// previously observed entries through incomplete catalogue refreshes.
public struct CodexModel: Codable, Equatable, Hashable, Sendable {
    /// The model slug Codex uses internally, e.g. `gpt-6-sol` or `claude-opus-5-5`.
    /// The bar uses this as the stable identity for a model button.
    public var id: String
    /// The human name the picker shows, e.g. `GPT-6-Sol` or `Opus 5.5`.
    /// This is also the prefix of the composer's model button title
    /// ("Opus 5.5 Extra High"), which is how the bar detects the current model.
    public var displayName: String
    /// Codex's own one-line description of the model (used as the button tooltip
    /// because it adds information the button label does not already show).
    public var description: String
    /// Hidden models exist in the catalogue but Codex keeps them out of its picker,
    /// so the bar respects an observed hidden flag as well.
    public var hidden: Bool
    /// Effort levels the picker exposes, in increasing order.
    public var supportedEfforts: [String]
    public var defaultEffort: String?

    public init(id: String, displayName: String, description: String = "", hidden: Bool = false,
                supportedEfforts: [String] = [], defaultEffort: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.hidden = hidden
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, description, hidden, supportedEfforts, defaultEffort
    }

    /// Lists cached by older releases did not contain effort data.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        hidden = try values.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        supportedEfforts = try values.decodeIfPresent([String].self, forKey: .supportedEfforts) ?? []
        defaultEffort = try values.decodeIfPresent(String.self, forKey: .defaultEffort)
    }
}

/// Parsing helpers for the two places a model list can come from.
public enum CodexModelParsing {
    /// Parses the `result` object of an app-server `model/list` response.
    ///
    /// Shape observed on Codex 0.155 (desktop 26.917):
    /// `{"data":[{"id":"gpt-6-sol","model":"gpt-6-sol","displayName":"GPT-6-Sol",
    ///   "description":"…","hidden":false,"isDefault":false,…}],"nextCursor":null}`
    ///
    /// Returns the page's models plus the cursor for the next page (nil when done).
    public static func parseModelListResult(_ result: [String: Any]) -> (models: [CodexModel], nextCursor: String?) {
        let rows = result["data"] as? [[String: Any]] ?? []
        let models: [CodexModel] = rows.compactMap { row in
            // `model` is the slug the picker selects; fall back to `id` in case a
            // future backend drops one of the two duplicate fields.
            guard let slug = (row["model"] as? String) ?? (row["id"] as? String), !slug.isEmpty else { return nil }
            let name = (row["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
            return CodexModel(
                id: slug,
                displayName: name,
                description: row["description"] as? String ?? "",
                hidden: row["hidden"] as? Bool ?? false,
                supportedEfforts: (row["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                    .compactMap { $0["reasoningEffort"] as? String },
                defaultEffort: row["defaultReasoningEffort"] as? String
            )
        }
        let cursor = result["nextCursor"] as? String
        return (models, (cursor?.isEmpty ?? true) ? nil : cursor)
    }

    /// Parses Codex's shared on-disk `~/.codex/models_cache.json` observations.
    ///
    /// The cache uses snake_case and a `visibility` field ("list" = shown in the
    /// picker, "hide" = hidden). It can omit entries the desktop still offers;
    /// callers must merge it with saved observations rather than treating absence
    /// as a deletion.
    public static func parseModelsCache(_ data: Data) -> [CodexModel] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = root["models"] as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let slug = row["slug"] as? String, !slug.isEmpty else { return nil }
            let visibility = row["visibility"] as? String ?? "list"
            return CodexModel(
                id: slug,
                displayName: row["display_name"] as? String ?? slug,
                description: row["description"] as? String ?? "",
                hidden: visibility != "list",
                supportedEfforts: (row["supported_reasoning_levels"] as? [[String: Any]] ?? [])
                    .compactMap { $0["effort"] as? String },
                defaultEffort: row["default_reasoning_level"] as? String
            )
        }
    }
}

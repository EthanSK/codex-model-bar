import Foundation
import os
import CodexModelBarCore

/// App identity constants shared across files.
enum AppInfo {
    /// Bundle identifier of the Codex desktop app. The current build ships as
    /// "ChatGPT.app" but keeps the historical `com.openai.codex` identifier.
    static let codexBundleID = "com.openai.codex"

    /// Our own marketing version, read from Info.plist when running as an app
    /// bundle (falls back for `swift run` during development).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// Tiny wrapper over unified logging so problems can be inspected with:
///   log stream --predicate 'subsystem == "com.ethansk.codex-model-bar"'
enum Log {
    private static let logger = Logger(subsystem: "com.ethansk.codex-model-bar", category: "app")
    private static let file = DiagnosticLog(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Codex Model Bar/diagnostic.log"))
    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        file.append(message)
    }
}

/// User preferences, stored in the app's standard UserDefaults domain.
enum Preferences {
    private static let hiddenKey = "hiddenModelIDs"

    /// Model ids the user unticked in the right-click Models menu.
    static var hiddenModelIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: hiddenKey) }
    }
}

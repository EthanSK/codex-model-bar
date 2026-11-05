import Foundation
import Darwin
import os
import CodexModelBarCore

/// App identity constants shared across files.
enum AppInfo {
    /// Bundle identifier of the Codex desktop app. The current build ships as
    /// "ChatGPT.app" but keeps the historical `com.openai.codex` identifier.
    static let codexBundleID = "com.openai.codex"

    static let agentFlowBundleID = "com.ethansk.VoiceInkPlusPlus" // Agent Flow retains its earlier VoiceInk++ bundle identity.

    /// Our own marketing version, read from Info.plist when running as an app
    /// bundle (falls back for `swift run` during development).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// Tiny wrapper over unified logging so problems can be inspected with:
///   log stream --predicate 'subsystem == "com.ethansk.codex-model-bar"'
enum Log {
    private static var lastResourceSample = -Double.infinity
    private static let logger = Logger(subsystem: "com.ethansk.codex-model-bar", category: "app")
    private static let file = DiagnosticLog(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Codex Model Bar/diagnostic.log"))
    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        // Tests share this file with the running app; keep their attempts
        // distinguishable instead of counting synthetic cancellations as usage.
        file.append("pid=\(ProcessInfo.processInfo.processIdentifier) \(message)")
    }

    /// Uses the existing main-thread catalogue timer; sampling never scans Codex's UI.
    static func resourcesIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastResourceSample >= 60 else { return }
        lastResourceSample = now
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { info("resources sample-unavailable code=\(result)"); return }
        info("resources pid=\(getpid()) footprint-bytes=\(usage.ri_phys_footprint) peak-footprint-bytes=\(usage.ri_lifetime_max_phys_footprint) resident-bytes=\(usage.ri_resident_size) cpu-ns=\(usage.ri_user_time + usage.ri_system_time)")
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

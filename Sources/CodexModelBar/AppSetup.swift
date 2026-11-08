// First-launch setup supplies missing native shortcuts and, when Claude Code is
// installed, delegates Claude model setup to a pinned official bridge installer.
// Existing bindings, disabled commands and existing bridge services remain owned
// by the user; setup never changes model selection or restarts Codex.
import Foundation

final class AppSetup {
    // Verified working M5 bindings (Ethan: “same shortcuts I have on my M5”).
    // Keep defaults here, separate from the shared reader used for every action.
    static let requiredBindings = [
        ("composer.increaseReasoningEffort", "Command+Control+Up"),
        ("composer.decreaseReasoningEffort", "Ctrl+Command+Down"),
        ("composer.toggleFastMode", "Ctrl+Shift+S"),
    ]

    @discardableResult
    static func configureShortcuts(at url: URL) throws -> Int {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let before = exists ? try Data(contentsOf: url) : Data("[]".utf8)
        // Do not replace malformed files or discard fields newer Codex versions use.
        guard var bindings = try JSONSerialization.jsonObject(with: before) as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var added = 0
        for (command, key) in requiredBindings {
            // An explicit null is a deliberate disabled shortcut, not missing setup.
            guard !bindings.contains(where: { $0["command"] as? String == command }) else { continue }
            let candidate = CodexShortcuts.parse(key)
            let conflict = bindings.contains { binding in
                guard let existing = binding["key"] as? String,
                      let parsed = CodexShortcuts.parse(existing) else { return false }
                return parsed == candidate
            }
            guard !conflict else { continue } // Never steal another command's chord.
            bindings.append(["command": command, "key": key])
            added += 1
        }
        guard added > 0 else { return 0 }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if exists {
            guard try Data(contentsOf: url) == before else { throw CocoaError(.fileWriteFileExists) }
            // Retain a single setup backup; repeated launches do not rewrite it.
            let backup = url.appendingPathExtension("before-model-bar-setup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try before.write(to: backup, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        let data = try JSONSerialization.data(withJSONObject: bindings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return added
    }

    static func start(completion: @escaping () -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        do {
            let count = try configureShortcuts(at: home.appendingPathComponent(".codex/keybindings.json"))
            Log.info("setup shortcuts-added=\(count)")
        } catch { Log.info("setup shortcuts unchanged: \(error.localizedDescription)") }

        // Network/package work never blocks the toolbar, its input queue or Voice.
        DispatchQueue.global(qos: .utility).async {
            guard let script = Bundle.main.url(forResource: "setup-claude", withExtension: "sh") else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path]
            let base = home.appendingPathComponent("Library/Logs/Codex Model Bar", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let log = base.appendingPathComponent("setup.log")
                FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let output = try FileHandle(forWritingTo: log)
                defer { try? output.close() }
                process.standardOutput = output
                process.standardError = output
                try process.run()
                process.waitUntilExit()
                Log.info("setup claude exit=\(process.terminationStatus); details=setup.log")
                if process.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Codex Model Bar/claude-setup-complete").path) {
                    DispatchQueue.main.async(execute: completion)
                }
            } catch { Log.info("setup claude unavailable: \(error.localizedDescription)") }
        }
    }
}

import Foundation
import CodexModelBarCore

/// Loads the list of models to show as buttons.
///
/// Source of truth: Codex's own backend. We start the `codex` binary bundled inside
/// the Codex/ChatGPT app with `app-server` (JSON-RPC over stdin/stdout, one JSON
/// object per line), ask it for `model/list`, then stop it. That is the same call
/// Codex's model picker makes, so the buttons match the picker exactly — custom
/// entries such as the Claude bridge models included.
///
/// Fallbacks, in order:
///  1. Our last good list, cached in Application Support (instant startup, offline).
///  2. Codex's `~/.codex/models_cache.json` (may lag behind the desktop catalogue).
final class ModelCatalogService {
    /// Where the last successful list is cached between launches.
    private let cacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Model Bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("models.json")
    }()

    /// Reads the cached list, or Codex's own cache when we have never fetched one.
    func loadCachedModels() -> [CodexModel] {
        if let data = try? Data(contentsOf: cacheURL),
           let models = try? JSONDecoder().decode([CodexModel].self, from: data),
           !models.isEmpty {
            return models
        }
        let codexCache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
        if let data = try? Data(contentsOf: codexCache) {
            return CodexModelParsing.parseModelsCache(data)
        }
        return []
    }

    /// Fetches the live list from the Codex backend on a background thread and calls
    /// `completion` on the main thread. `nil` means the fetch failed (the caller keeps
    /// showing whatever it already has).
    func refresh(codexAppURL: URL?, completion: @escaping ([CodexModel]?) -> Void) {
        DispatchQueue.global(qos: .utility).async { [cacheURL] in
            let models = Self.fetchFromAppServer(codexAppURL: codexAppURL)
            if let models, !models.isEmpty,
               let data = try? JSONEncoder().encode(models) {
                // Atomic write so a crash mid-write never leaves a half-written cache.
                try? data.write(to: cacheURL, options: .atomic)
            }
            DispatchQueue.main.async { completion(models) }
        }
    }

    // MARK: - app-server client

    /// Candidate `codex` binaries, most specific first. The running app's own bundled
    /// binary is preferred because its catalogue matches the app the bar controls.
    private static func codexBinaryCandidates(codexAppURL: URL?) -> [String] {
        var paths: [String] = []
        if let app = codexAppURL {
            paths.append(app.appendingPathComponent("Contents/Resources/codex").path)
        }
        paths += [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        return paths
    }

    /// Runs one short-lived `codex app-server`, performs the JSON-RPC handshake and
    /// pages through `model/list`. Returns nil on any failure or after a 25s timeout.
    ///
    /// Protocol (documented Codex App Server):
    ///   → {"method":"initialize","id":1,"params":{"clientInfo":{…}}}
    ///   ← {"id":1,"result":{…}}
    ///   → {"method":"initialized"}                       (notification, no id)
    ///   → {"method":"model/list","id":2,"params":{"cursor":…}}
    ///   ← {"id":2,"result":{"data":[…],"nextCursor":…}}
    private static func fetchFromAppServer(codexAppURL: URL?) -> [CodexModel]? {
        guard let binary = codexBinaryCandidates(codexAppURL: codexAppURL)
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            Log.info("model fetch: no codex binary found")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        // Discard stderr: app-server logs there, and an unread pipe could fill up and
        // block the child.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            Log.info("model fetch: failed to start \(binary): \(error)")
            return nil
        }
        // Always stop the child, whatever path we leave by.
        defer {
            if process.isRunning { process.terminate() }
        }

        let reader = LineReader(handle: stdout.fileHandleForReading)
        let deadline = Date().addingTimeInterval(25)

        func send(_ object: [String: Any]) -> Bool {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            data.append(0x0A) // newline-delimited JSON
            do { try stdin.fileHandleForWriting.write(contentsOf: data) } catch { return false }
            return true
        }

        /// Reads lines until the response with `id` arrives (skipping notifications).
        func awaitResponse(id: Int) -> [String: Any]? {
            while Date() < deadline {
                guard let line = reader.nextLine(timeout: deadline.timeIntervalSinceNow) else { return nil }
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if let responseID = object["id"] as? Int, responseID == id { return object }
            }
            return nil
        }

        guard send([
            "method": "initialize", "id": 1,
            "params": ["clientInfo": ["name": "codex-model-bar", "title": "Codex Model Bar", "version": AppInfo.version]],
        ]), awaitResponse(id: 1)?["result"] != nil else {
            Log.info("model fetch: initialize failed")
            return nil
        }
        _ = send(["method": "initialized"])

        var all: [CodexModel] = []
        var cursor: String?
        var requestID = 2
        // Page through the list; the bound stops a misbehaving server looping forever.
        for _ in 0..<20 {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            guard send(["method": "model/list", "id": requestID, "params": params]),
                  let response = awaitResponse(id: requestID),
                  let result = response["result"] as? [String: Any] else {
                Log.info("model fetch: model/list failed")
                return all.isEmpty ? nil : all
            }
            let page = CodexModelParsing.parseModelListResult(result)
            all += page.models
            cursor = page.nextCursor
            requestID += 1
            if cursor == nil { break }
        }
        Log.info("model fetch: \(all.count) models from \(binary)")
        return all
    }
}

/// Minimal blocking line reader over a pipe with a timeout, used only on the
/// background fetch thread. Data arrives via `readabilityHandler` and is split on
/// newlines; `nextLine` waits on a semaphore for the next complete line.
private final class LineReader {
    private var buffer = Data()
    private var lines: [String] = []
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)

    init(handle: FileHandle) {
        handle.readabilityHandler = { [weak self] h in
            guard let self else {
                h.readabilityHandler = nil
                return
            }
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return } // EOF: child exited
            self.lock.lock()
            self.buffer.append(chunk)
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let lineData = self.buffer[self.buffer.startIndex..<newline]
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8) {
                    self.lines.append(line)
                    self.signal.signal()
                }
            }
            self.lock.unlock()
        }
    }

    func nextLine(timeout: TimeInterval) -> String? {
        guard timeout > 0, signal.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return lines.isEmpty ? nil : lines.removeFirst()
    }
}

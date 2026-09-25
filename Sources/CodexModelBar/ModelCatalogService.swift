import Foundation
import CodexModelBarCore

/// Loads the list of models to show as buttons.
///
/// Codex's shared cache can temporarily omit models that are still in use in
/// the desktop. Merge observations into the bar's saved catalogue: absence is
/// not a deletion. Explicit hidden flags and the user's show/hide choices apply.
final class ModelCatalogService {
    /// Where the last successful list is cached between launches.
    private let cacheURL: URL
    private let codexCacheURL: URL
    /// Serialise refresh/read/write so an older concurrent response cannot
    /// overwrite a newer, more complete saved catalogue.
    private let queue = DispatchQueue(label: "com.ethansk.codex-model-bar.catalog", qos: .utility)

    init(cacheURL: URL? = nil, codexCacheURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Model Bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.cacheURL = cacheURL ?? base.appendingPathComponent("models.json")
        self.codexCacheURL = codexCacheURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
    }

    var codexCacheModificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: codexCacheURL.path))?[.modificationDate] as? Date
    }

    private static func readCodexCache(at url: URL) -> [CodexModel] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return CodexModelParsing.parseModelsCache(data)
    }

    private func readSavedModels() -> [CodexModel] {
        guard let data = try? Data(contentsOf: cacheURL),
              let models = try? JSONDecoder().decode([CodexModel].self, from: data) else { return [] }
        return models
    }

    private func save(_ models: [CodexModel]) {
        guard !models.isEmpty, let data = try? JSONEncoder().encode(models) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Refresh metadata for observed entries, retaining missing entries and their
    /// positions. A short-lived cache rewrite must not erase buttons or the names
    /// used to recognise the focused composer's model control.
    static func merge(saved: [CodexModel], observed: [CodexModel]) -> [CodexModel] {
        var result = saved
        for model in observed {
            if let index = result.firstIndex(where: { $0.id == model.id }) {
                result[index] = model
            } else {
                result.append(model)
            }
        }
        return result
    }

    func loadCachedModels() -> [CodexModel] {
        queue.sync {
            let models = Self.merge(saved: readSavedModels(), observed: Self.readCodexCache(at: codexCacheURL))
            save(models)
            return models
        }
    }

    /// Merge shared-cache observations, falling back to app-server if it is missing.
    /// `nil` means no source or saved catalogue is available.
    func refresh(codexAppURL: URL?, completion: @escaping ([CodexModel]?) -> Void) {
        queue.async { [self] in
            let saved = readSavedModels()
            let current = Self.readCodexCache(at: codexCacheURL)
            let fetched = current.isEmpty ? Self.fetchFromAppServer(codexAppURL: codexAppURL) : nil
            // The real app may finish signing in while the fallback request runs.
            let latest = Self.readCodexCache(at: codexCacheURL)
            // Keep every successful observation, even if the shared file changes
            // again during this refresh. Later metadata wins for the same id.
            let observed = Self.merge(saved: fetched ?? [], observed: Self.merge(saved: current, observed: latest))
            let models = Self.merge(saved: saved, observed: observed)
            let observedIDs = Set(observed.map(\.id))
            let retained = saved.filter { !observedIDs.contains($0.id) }.map(\.id)
            Log.info("catalog-refresh observed=[\(observed.map(\.id).joined(separator: ","))] retained=[\(retained.joined(separator: ","))] total=\(models.count)")
            save(models)
            DispatchQueue.main.async { completion(models.isEmpty ? nil : models) }
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

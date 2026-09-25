import Foundation

/// Local, bounded diagnostics. Callers supply metadata, never draft or chat text.
public final class DiagnosticLog {
    private let url: URL
    private let maximumBytes: Int
    private let lock = NSLock()
    private let timestamp = ISO8601DateFormatter()

    public init(url: URL, maximumBytes: Int = 2 * 1024 * 1024) {
        self.url = url
        self.maximumBytes = maximumBytes
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let files = FileManager.default
        do {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            let line = "\(timestamp.string(from: Date())) \(message.replacingOccurrences(of: "\n", with: "\\n"))\n"
            let data = Data(line.utf8.prefix(maximumBytes))
            let size = (try? files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 0 && size + data.count > maximumBytes {
                let previous = url.appendingPathExtension("previous")
                if files.fileExists(atPath: previous.path) { try files.removeItem(at: previous) }
                try files.moveItem(at: url, to: previous)
            }
            if !files.fileExists(atPath: url.path) {
                files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: data)
        } catch {
            // Logging must never interrupt a model change.
        }
    }
}

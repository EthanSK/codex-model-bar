import CodexNativeControls
// Shared speed requests for the toolbar and Agentic Mouse.
import AppKit
import ApplicationServices
import CodexModelBarCore

/// Sends Codex's native Cycle speed shortcut for the toolbar button and mouse URLs.
/// Keep the existing focus handoff, quick-ratchet cancellation and best-effort sending;
/// never type slash text, send Return, or poll for a changed speed.
final class SpeedSwitcher {
    enum Request { case cycle, mouseCycle }
    typealias Result = CodexShortcutController.Result
    typealias Performer = (Request, NSRunningApplication, TimeInterval, () -> Bool) -> Result
    private var speedMemory = ResponseSpeedMemory() // Main thread only. Display fallback and the existing combined Astra action; native cycles never infer a target from this estimate.
    private var observedSpeed: ResponseSpeed? // Used only to log changes from the passive watcher.
    private let speedMemoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Codex Model Bar/speed.txt")
    private let native: CodexShortcutController
    var isBusy: Bool { native.isBusy }

    init(performer: Performer? = nil) {
        native = CodexShortcutController(focusHint: { window in
            CodexUI.Cache.windowForLocated.map { CFEqual($0, window) } == true ? CodexUI.Cache.located.composer : nil
        }, log: Log.info, performer: performer.map { perform in
            { _, source, app, started, current in
                perform(source == .mouse ? .mouseCycle : .cycle, app, started, current)
            }
        })
        do { speedMemory = try ResponseSpeedMemory(contentsOf: speedMemoryURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { }
        catch { Log.info("speed-memory phase=load result=failed error=\(error.localizedDescription)") }
    }

    private func saveSpeedMemory() {
        do { try speedMemory.write(to: speedMemoryURL) }
        catch { Log.info("speed-memory phase=save result=failed error=\(error.localizedDescription)") } // A disk error must not repeat a command that was already posted.
    }

    /// Release cancels later queued mouse actions; the first reserved command may finish while its input stays valid.
    func cancelMouseCommands() { native.cancelMouse(.speed) }

    /// The combined Astra action already confirms Ultrafast through its own existing path.
    func rememberSpeed(_ speed: ResponseSpeed) {
        speedMemory.speed = speed
        saveSpeedMemory()
    }

    /// Resolves the speed to show from the watcher's model-button read; nil when no button was read.
    func observe(iconVisible: Bool?, offered: [ResponseSpeed], saved: ResponseSpeed?) -> ResponseSpeed? {
        let observed = iconVisible.map { speedMemory.displayedSpeed(iconVisible: $0, offered: offered, saved: saved) }
        if observed != observedSpeed {
            Log.info("speed-display icon=\(iconVisible.map(String.init) ?? "unread") offered=[\(offered.map(\.rawValue).joined(separator: ","))] saved=\(saved?.rawValue ?? "unknown") remembered=\(speedMemory.speed?.rawValue ?? "unknown") shows=\(observed?.rawValue ?? "none")") // Changes only; lets a live check confirm the passive read without Computer Use.
        }
        observedSpeed = observed
        return observed
    }

    func change(_ request: Request, codex: NSRunningApplication,
                completion: @escaping (Result) -> Void) {
        native.change(.cycleSpeed, source: { if case .cycle = request { return .toolbar }; return .mouse }(),
                      codex: codex, completion: completion)
    }
    static func isExternalInput(_ event: CGEvent?) -> Bool { CodexShortcutController.isExternalInput(event) }
}

import AppKit
import ApplicationServices
import CodexModelBarCore

/// Uses the slash route Ethan requested. Do not restore the rejected picker fallback,
/// per-character tree scans or repeated confirmation queries (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
/// Fast and Ultrafast use direct whole-command Unicode text/Return, not command-menu isolation.
/// Never verify: send the best attempt and assume it worked; only keep Codex owning the keyboard for the global text events (Ethan, 2026-10-29, Claude session f9500cd2).
final class SpeedSwitcher {
    enum Request { case select(ResponseSpeed), command(ResponseSpeed) }
    enum Result { case changed(ResponseSpeed), requested(ResponseSpeed), cancelled, cancelledForTyping, failed(String) }
    typealias Performer = (Request, NSRunningApplication, TimeInterval, () -> Bool) -> Result
    private let performer: Performer?
    private var speedMemory = ResponseSpeedMemory() // Main thread only: the toolbar draws from it, and commands on AX.queue read and update it in order through main.sync. Never open the picker or slash menu to discover speed (task 01a0d315-7d5e-7be0-bc08-80626ca0729b); only the watcher's passive model-button and saved-config reads feed `observedSpeed`.
    private var observedSpeed: ResponseSpeed? // What the toolbar last showed from Codex's own icon; consumed by the next command so its toggle starts from Codex's state rather than another chat's.
    private let speedMemoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Codex Model Bar/speed.txt")
    private var pendingCount = 0
    private var mouseGeneration = 0
    private var selectionGeneration = 0
    var isBusy: Bool { pendingCount > 0 }

    init(performer: Performer? = nil) {
        self.performer = performer
        do {
            speedMemory = try ResponseSpeedMemory(contentsOf: speedMemoryURL)
            Log.info("speed-memory phase=load speed=\(speedMemory.speed?.rawValue ?? "unknown")")
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { // No saved value on first launch; preserve the approved unknown-speed behaviour.
        } catch {
            Log.info("speed-memory phase=load result=failed error=\(error.localizedDescription)") // Corrupt or unreadable state must not prevent the toolbar from launching.
        }
    }

    private func saveSpeedMemory() {
        do { try speedMemory.write(to: speedMemoryURL) }
        catch { Log.info("speed-memory phase=save result=failed error=\(error.localizedDescription)") } // A disk error must not repeat a command that was already posted.
    }

    /// Release cancels later queued mouse actions; the first reserved command may finish while its input stays valid.
    func cancelMouseCommands() { mouseGeneration += 1 }

    /// The combined Astra action already confirms Ultrafast through its own existing path.
    func rememberSpeed(_ speed: ResponseSpeed) {
        speedMemory.speed = speed
        saveSpeedMemory()
    }

    /// The bar's estimate after its last command, shown until the watcher reads Codex's icon again.
    var rememberedSpeed: ResponseSpeed? { speedMemory.speed }

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
        if case .select = request { selectionGeneration += 1 }
        let mouseGeneration = self.mouseGeneration
        let selectionGeneration = self.selectionGeneration
        // Ethan: "two attempts, usually not one". Reserve the first ratchet on
        // arrival, not when AX.queue eventually starts it: a quick release must
        // not erase this real request. Later queued ratchets remain cancellable.
        let reservedFirstCommand = pendingCount == 0
        pendingCount += 1
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let attempt = String(UUID().uuidString.prefix(8))
        var interrupted = false
        var inputMonitor: Any?
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            if Self.isExternalInput(event.cgEvent) { interrupted = true } // Mouse URLs now borrow focus too; ignore our own HID Return but let newer user input cancel restoration for either route (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
        }
        Log.info("speed-switch attempt=\(attempt) phase=start request=\(request)")
        AX.enqueueAction {
            var admitted = reservedFirstCommand
            func isCurrent() -> Bool {
                DispatchQueue.main.sync {
                    switch request {
                    case .command:
                        return !interrupted && (admitted || self.mouseGeneration == mouseGeneration)
                            && ProcessInfo.processInfo.systemUptime - requestedAt < 2 // A slow tree read must not deliver a mouse command several seconds after the gesture.
                    case .select: return self.selectionGeneration == selectionGeneration && !interrupted
                    }
                }
            }
            let result: Result
            if !isCurrent() { result = .cancelled }
            else if case .command = request, ProcessInfo.processInfo.systemUptime - requestedAt > 0.5 {
                result = .cancelled // Slow AX work previously replayed ratchets after release; expire them instead.
                Log.info("speed-switch attempt=\(attempt) phase=expired")
            } else {
                admitted = true // Quick release must not erase an already-started ratchet; it only clears the queue.
                Log.info("speed-switch attempt=\(attempt) phase=admitted")
                if let performer = self.performer {
                    result = performer(request, codex, requestedAt, isCurrent)
                } else {
                    result = self.perform(request, codex: codex, since: requestedAt, isCurrent: isCurrent)
                }
            }
            Log.info("speed-switch attempt=\(attempt) phase=finish result=\(result)")
            DispatchQueue.main.async {
                if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
                self.pendingCount -= 1
                completion(result)
            }
        }
    }

    /// Ignore only this process's posted keys, including the existing HID-source Return.
    static func isExternalInput(_ event: CGEvent?) -> Bool {
        event?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(ProcessInfo.processInfo.processIdentifier)
    }

    private func perform(_ request: Request, codex: NSRunningApplication,
                                since started: TimeInterval, isCurrent: () -> Bool) -> Result {
        let pid = codex.processIdentifier
        Log.info("speed-switch phase=focus active=\(codex.isActive) pid=\(pid) owner=\(AX.keyboardOwnerPID().map(String.init) ?? "none")")
        guard isCurrent() else { return .cancelled }
        guard !Keyboard.userInteracted(since: started) else { return .cancelledForTyping }
        let speed: ResponseSpeed
        switch request {
        case .select(let selected), .command(let selected): speed = selected
        }
        let toggle = DispatchQueue.main.sync { () -> ResponseSpeed in
            if let observed = observedSpeed { speedMemory.speed = observed } // Seed from Codex's icon once per watcher read: after Fast in one chat, Fast in a Standard chat must record Fast, not Standard.
            observedSpeed = nil // Queued ratchets behind this one follow the estimate it posts; the watcher stays suspended until they finish.
            return speedMemory.toggle(for: speed)
        }
        guard let command = toggle.command else { return .changed(.standard) }
        var origin: SpeedInputFocus?
        var borrowed = false
        defer {
            if borrowed, let origin, isCurrent(), codex.isActive || NSRunningApplication.current.isActive {
                origin.restore(canRestore: isCurrent) // No restoration after a newer click/key or app change; it would steal the user's newly chosen focus.
            }
        }
        AX.enableWebAccessibility(pid: pid)
        if let previous = SpeedInputFocus.capture(), previous.application.processIdentifier != pid { origin = previous } // Best effort: never verify, just send (Ethan, 2026-10-29, Claude session f9500cd2). No capturable focus only means there is nothing to restore afterwards; do not restore it as a failure gate.
        let window = AX.focusedWindow(pid: pid)
        let preparationStarted = ProcessInfo.processInfo.systemUptime
        var readyInput = window.flatMap(CodexUI.focusedSpeedInput(in:)) // Read Codex's retained input before borrowing Agent Flow's keyboard focus, too.
        let conversation = readyInput == nil ? window.flatMap(CodexUI.speedConversation(in:)) : nil // A focused attached input skips both transcript walks; missing/flattened parent links retain the existing exact-pane lookup.
        guard isCurrent() else { return .cancelled }
        borrowed = origin != nil
        _ = SpeedInputFocus.activate(codex, canFocus: isCurrent) // The text events below still require Codex to own the keyboard; activation itself is not a separate failure.
        if readyInput == nil {
            ModelSwitcher.waitUntil(timeout: 1.5) {
                guard isCurrent() else { return true }
                readyInput = conversation.flatMap(CodexUI.speedInput(in:))
                    ?? AX.focusedWindow(pid: pid).flatMap(CodexUI.focusedSpeedInput(in:))
                return readyInput != nil
            } // Codex swaps its composer after a send; wait up to 1.5 s for it, then type into Codex's focus anyway (2026-10-29 15:53:50 "No task composer").
        }
        guard isCurrent() else { return .cancelled }
        if let input = readyInput {
            _ = SpeedInputFocus.focus(input, pid: pid, placeCaret: true,
                                      canFocus: { isCurrent() && codex.isActive }) // Best effort; text delivery is not gated on reading the composer's focus back.
        }
        let preparationDuration = ProcessInfo.processInfo.systemUptime - preparationStarted
        Log.info("speed-switch phase=focused route=\(readyInput == nil ? "codex-focus" : conversation == nil ? "focused-input" : "pane-lookup") preparation-ms=\(Int(preparationDuration * 1000)) region=\(CodexUI.identity(conversation)) input=\(CodexUI.identity(readyInput))")
        guard SpeedCommandPaste.post(command, canPost: {
            isCurrent() && codex.isActive && AX.keyboardOwnerPID() == pid // Text and Return are global, so only post while Codex owns the keyboard, never into Agent Flow or another app.
        }) else {
            return isCurrent() ? .failed("Codex did not receive keyboard focus") : .cancelled
        }
        let remembered = DispatchQueue.main.sync { () -> ResponseSpeed? in
            speedMemory.recordPostedToggle(toggle)
            saveSpeedMemory()
            return speedMemory.speed
        }
        Log.info("speed-switch phase=remembered-speed speed=\(remembered?.rawValue ?? "unknown")")
        return .requested(speed) // Standard repeats the remembered active toggle; no native picker, speed read or delayed verification (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
    }
}

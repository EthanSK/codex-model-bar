/*
 ============================================================================
 **MOVED FROM — MOVE HISTORY**
 2026-11-08: CodexModelBar/SpeedSwitcher.swift. Extraction of existing serial
 requests, first-ratchet reservation, cancellation, expiry and intended-chat
 focus handoff. New: configurable native command, per-family cancellation and
 an owning app's live session-security gate. No running Model Bar dependency.
 ============================================================================
 */
import AppKit
import ApplicationServices

public final class CodexShortcutController {
    public enum Source: Equatable { case toolbar, mouse }
    public enum Family: Hashable {
        case speed, reasoning
        init(_ command: CodexShortcuts.Command) {
            self = command == .cycleSpeed ? .speed : .reasoning
        }
    }
    public enum Result { case requested, cancelled, cancelledForTyping, failed(String) }
    public typealias Performer = (CodexShortcuts.Command, Source, NSRunningApplication, TimeInterval, () -> Bool) -> Result
    private let performer: Performer?
    private let inputAllowed: () -> Bool
    private let log: (String) -> Void
    private let focusHint: (AXUIElement) -> AXUIElement?
    private var pendingCounts: [Family: Int] = [:]
    private var mouseGenerations: [Family: Int] = [:]
    private var selectionGenerations: [Family: Int] = [:]
    public var isBusy: Bool { pendingCounts.values.contains { $0 > 0 } }

    /// All entry points and the live host gate are called on the main thread.
    public init(inputAllowed: @escaping () -> Bool = { true },
                focusHint: @escaping (AXUIElement) -> AXUIElement? = { _ in nil },
                log: @escaping (String) -> Void = { _ in }, performer: Performer? = nil) {
        self.inputAllowed = inputAllowed; self.focusHint = focusHint
        self.log = log; self.performer = performer
    }
    public func cancelMouse(_ family: Family) {
        precondition(Thread.isMainThread)
        mouseGenerations[family, default: 0] += 1
    }
    private static func identity(_ element: AXUIElement?) -> String {
        element.map { "\(CodexAX.role($0))#\(String(CFHash($0), radix: 16))" } ?? "none"
    }
    private static func userInteracted(since started: TimeInterval) -> Bool {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        return [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) < elapsed
        }
    }
    public func change(_ command: CodexShortcuts.Command, source: Source, codex: NSRunningApplication,
                completion: @escaping (Result) -> Void) {
        precondition(Thread.isMainThread)
        guard inputAllowed() else { completion(.cancelled); return }
        let family = Family(command)
        if source == .toolbar { selectionGenerations[family, default: 0] += 1 }
        let request = source
        let mouseGeneration = self.mouseGenerations[family, default: 0]
        let selectionGeneration = self.selectionGenerations[family, default: 0]
        // Ethan: "two attempts, usually not one". Reserve the first ratchet on
        // arrival, not when CodexAX.queue eventually starts it: a quick release must
        // not erase this real request. Later queued ratchets remain cancellable.
        let reservedFirstCommand = pendingCounts[family, default: 0] == 0
        pendingCounts[family, default: 0] += 1
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let attempt = String(UUID().uuidString.prefix(8))
        var interrupted = false
        var inputMonitor: Any?
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            if Self.isExternalInput(event.cgEvent) { interrupted = true } // Mouse URLs now borrow focus too; ignore our own posted shortcut but let newer user input cancel restoration for either route (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
        }
        self.log("native-shortcut attempt=\(attempt) phase=start command=\(command.rawValue) request=\(request)")
        CodexAX.enqueueAction {
            var admitted = reservedFirstCommand
            func isCurrent() -> Bool {
                DispatchQueue.main.sync {
                    switch request {
                    case .mouse:
                        return self.inputAllowed() && !interrupted && (admitted || self.mouseGenerations[family, default: 0] == mouseGeneration)
                            && ProcessInfo.processInfo.systemUptime - requestedAt < 2 // A slow tree read must not deliver a mouse command several seconds after the gesture.
                    case .toolbar: return self.inputAllowed() && self.selectionGenerations[family, default: 0] == selectionGeneration && !interrupted
                    }
                }
            }
            let result: Result
            if !isCurrent() { result = .cancelled }
            else if case .mouse = request, ProcessInfo.processInfo.systemUptime - requestedAt > 0.5 {
                result = .cancelled // Slow AX work previously replayed ratchets after release; expire them instead.
                self.log("native-shortcut attempt=\(attempt) phase=expired")
            } else {
                admitted = true // Quick release must not erase an already-started ratchet; it only clears the queue.
                self.log("native-shortcut attempt=\(attempt) phase=admitted")
                if let performer = self.performer {
                    result = performer(command, source, codex, requestedAt, isCurrent)
                } else {
                    result = self.perform(command, codex: codex, since: requestedAt, isCurrent: isCurrent)
                }
            }
            self.log("native-shortcut attempt=\(attempt) phase=finish result=\(result)")
            DispatchQueue.main.async {
                if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
                self.pendingCounts[family, default: 0] -= 1
                completion(result)
            }
        }
    }

    /// Ignore only this process's posted keys; genuine user input still cancels the handoff.
    public static func isExternalInput(_ event: CGEvent?) -> Bool {
        event?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(ProcessInfo.processInfo.processIdentifier)
    }

    private func perform(_ command: CodexShortcuts.Command, codex: NSRunningApplication,
                                since started: TimeInterval, isCurrent: () -> Bool) -> Result {
        let pid = codex.processIdentifier
        self.log("native-shortcut phase=focus active=\(codex.isActive) pid=\(pid) owner=\(CodexAX.keyboardOwnerPID().map(String.init) ?? "none")")
        guard isCurrent() else { return .cancelled }
        guard !Self.userInteracted(since: started) else { return .cancelledForTyping }
        // Read the configured command each time, just as reasoning does. Missing or
        // unsupported bindings cancel safely; never substitute a text/Return fallback.
        guard let shortcut = CodexShortcuts.load(command) else {
            self.log("native-shortcut phase=missing-native-binding")
            return .cancelled
        }
        var origin: CodexInputFocus?
        var borrowed = false
        defer {
            if borrowed, let origin, isCurrent(), codex.isActive || NSRunningApplication.current.isActive {
                origin.restore(canRestore: isCurrent, log: log) // No restoration after a newer click/key or app change; it would steal the user's newly chosen focus.
            }
        }
        CodexAX.enableWebAccessibility(pid: pid)
        if let previous = CodexInputFocus.capture(), previous.application.processIdentifier != pid { origin = previous } // Best effort: never verify, just send (Ethan, 2026-10-29, Claude session f9500cd2). No capturable focus only means there is nothing to restore afterwards; do not restore it as a failure gate.
        let window = CodexAX.focusedWindow(pid: pid)
        let preparationStarted = ProcessInfo.processInfo.systemUptime
        var readyInput = window.flatMap { CodexComposerFocus.focusedInput(in: $0, previousComposer: focusHint($0)) } // Read Codex's retained input before borrowing Agent Flow's keyboard focus, too.
        let conversation = readyInput == nil ? window.flatMap { CodexComposerFocus.conversation(in: $0, previousComposer: focusHint($0)) } : nil // A focused attached input skips both transcript walks; missing/flattened parent links retain the existing exact-pane lookup.
        guard isCurrent() else { return .cancelled }
        borrowed = origin != nil
        _ = CodexInputFocus.activate(codex, canFocus: isCurrent) // The native events below still require Codex to own the keyboard; activation itself is not a separate failure.
        if readyInput == nil {
            CodexControlWait.until(timeout: 1.5) {
                guard isCurrent() else { return true }
                readyInput = conversation.flatMap(CodexComposerFocus.input(in:))
                    ?? CodexAX.focusedWindow(pid: pid).flatMap { CodexComposerFocus.focusedInput(in: $0, previousComposer: focusHint($0)) }
                return readyInput != nil
            } // Codex swaps its composer after a send; wait up to 1.5 s for it, then send to Codex's focus anyway (2026-10-29 15:53:50 "No task composer").
        }
        guard isCurrent() else { return .cancelled }
        if let input = readyInput {
            _ = CodexInputFocus.focus(input, pid: pid, placeCaret: false,
                                      canFocus: { isCurrent() && codex.isActive }) // Best effort; shortcut delivery is not gated on reading the composer's focus back.
        }
        let preparationDuration = ProcessInfo.processInfo.systemUptime - preparationStarted
        self.log("native-shortcut phase=focused route=\(readyInput == nil ? "codex-focus" : conversation == nil ? "focused-input" : "pane-lookup") preparation-ms=\(Int(preparationDuration * 1000)) region=\(Self.identity(conversation)) input=\(Self.identity(readyInput))")
        guard CodexNativeKey.post(shortcut, pid: pid, canPost: {
            isCurrent() && !Self.userInteracted(since: started)
                && codex.isActive && CodexAX.keyboardOwnerPID() == pid
        }) else {
            return isCurrent() ? .failed("Codex did not receive keyboard focus") : .cancelled
        }
        return .requested // The passive watcher supplies the actual state; do not guess a target.
    }
}

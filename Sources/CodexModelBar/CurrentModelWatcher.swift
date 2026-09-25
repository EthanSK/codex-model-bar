import AppKit
import ApplicationServices
import CodexModelBarCore

/// Follows the active composer without allowing slow AX reads to queue up or
/// publish a selection from a window/focus context the user has already left.
final class CurrentModelWatcher {
    typealias Reader = (pid_t, [CodexModel], Bool) -> CurrentSelection?
    var onChange: ((CurrentSelection) -> Void)?
    var onFocusChange: (() -> Void)?

    private var pid: pid_t?
    private var models: [CodexModel] = []
    private var timer: Timer?
    private var observer: AXObserver?
    private var lastReported: CurrentSelection?
    private var revision = 0
    private var inFlight = false
    private var forcePending = false
    private var suspended = false
    private var missingSince: Date?
    private let customReader: Reader?
    private let isTrusted: () -> Bool
    private let observesFocus: Bool

    // Only touched on AX.queue.
    private var enabledWebAXForPID: pid_t?

    init(readSelection: Reader? = nil, isTrusted: @escaping () -> Bool = { AX.isTrusted },
         observesFocus: Bool = true) {
        customReader = readSelection
        self.isTrusted = isTrusted
        self.observesFocus = observesFocus
    }

    deinit {
        timer?.invalidate()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    func update(pid: pid_t?, models: [CodexModel]) {
        let pidChanged = pid != self.pid
        let modelsChanged = models != self.models
        guard pidChanged || modelsChanged else { return }
        self.pid = pid
        self.models = models
        revision += 1
        missingSince = nil
        if pidChanged {
            lastReported = nil
            timer?.invalidate()
            timer = nil
            installObserver(pid: pid)
            if pid != nil {
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll(force: false) }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        poll(force: true)
    }

    /// A switch has its own AX reads. Suppress stale watcher results until it ends.
    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        revision += 1
        lastReported = nil
        if !value { poll(force: true) }
    }

    /// Focus events and completed switches invalidate even a plausible cached title.
    func refreshSoon() {
        revision += 1
        if observer == nil { installObserver(pid: pid) }
        poll(force: true)
    }

    private func installObserver(pid: pid_t?) {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        guard observesFocus, isTrusted(), let pid else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            let watcher = Unmanaged<CurrentModelWatcher>.fromOpaque(context).takeUnretainedValue()
            if !watcher.suspended { watcher.onFocusChange?() }
            watcher.refreshSoon()
        }, &created) == .success, let created else { return }
        observer = created
        let app = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(created, app, notification as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    private func poll(force: Bool) {
        guard let pid, !suspended, isTrusted(), !models.isEmpty else { return }
        if inFlight {
            forcePending = forcePending || force
            return
        }
        inFlight = true
        let requestRevision = revision
        let models = self.models
        AX.queue.async { [weak self] in
            guard let self else { return }
            let selection: CurrentSelection?
            if let reader = self.customReader {
                selection = reader(pid, models, force)
            } else {
                if self.enabledWebAXForPID != pid {
                    AX.enableWebAccessibility(pid: pid)
                    self.enabledWebAXForPID = pid
                }
                if let window = AX.focusedWindow(pid: pid) {
                    let located = CodexUI.Cache.current(window: window, models: models, forceRefresh: force)
                    selection = CurrentModelMatcher.selection(
                        forButtonTitle: located.modelButton.map(AX.title) ?? "", among: models)
                } else {
                    selection = nil
                }
            }
            DispatchQueue.main.async {
                self.inFlight = false
                let retry = self.forcePending || self.revision != requestRevision
                self.forcePending = false
                if self.revision == requestRevision, self.pid == pid, !self.suspended {
                    // Codex briefly removes its composer while a picker/chat renders.
                    // Allow a short gap without flashing the slider back to zero.
                    if let selection, selection.modelID != nil {
                        self.missingSince = nil
                        self.report(selection)
                    } else {
                        if self.missingSince == nil { self.missingSince = Date() }
                        if Date().timeIntervalSince(self.missingSince!) >= 0.75 {
                            self.report(CurrentSelection(modelID: nil, effort: nil))
                        }
                    }
                }
                if retry { self.poll(force: true) }
            }
        }
    }

    private func report(_ selection: CurrentSelection) {
        guard lastReported != selection else { return }
        lastReported = selection
        onChange?(selection)
    }
}

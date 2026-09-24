import AppKit
import ApplicationServices
import CodexModelBarCore

/// Keeps track of which model the open Codex chat uses, so the bar can highlight it.
///
/// Reads the composer's model button through Accessibility (title such as
/// `Opus 5.5 Extra High`). Locating that button walks the chat's AX tree (~0.5 s), so
/// the element lives in `CodexUI.Cache` and only its title is re-read each second. A new
/// walk happens only when the cached element stops looking like a model button (chat
/// switched, window rebuilt), throttled to once every 3 s. Runs on `AX.queue`; results
/// are delivered on the main thread.
final class CurrentModelWatcher {
    /// Called on the main thread with the current model id, or nil when unknown.
    var onChange: ((String?) -> Void)?

    private var pid: pid_t?
    private var models: [CodexModel] = []
    private var timer: Timer?
    private var hasReported = false
    private var lastReported: String?

    // Touched only on AX.queue.
    private var lastWalk = Date.distantPast
    private var enabledWebAXForPID: pid_t?

    /// Called whenever Codex's frontmost state or the model list changes.
    /// `pid == nil` pauses polling (Codex in the background: the bar is hidden anyway).
    func update(pid: pid_t?, models: [CodexModel]) {
        self.models = models
        if pid == self.pid, (pid == nil) == (timer == nil) { return }
        self.pid = pid
        timer?.invalidate()
        timer = nil
        guard pid != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll(force: false) }
        RunLoop.main.add(timer!, forMode: .common)
        poll(force: true)
    }

    /// Forces a fresh look shortly (after a switch, or once permission is granted).
    func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.poll(force: true) }
    }

    private func poll(force: Bool) {
        guard let pid, AX.isTrusted, !models.isEmpty else { return }
        let models = self.models
        AX.queue.async { [weak self] in
            guard let self else { return }
            if self.enabledWebAXForPID != pid {
                AX.enableWebAccessibility(pid: pid)
                self.enabledWebAXForPID = pid
            }
            guard let window = AX.focusedWindow(pid: pid) else { return }

            // Cheap path: the cached button's title. Expensive path: a throttled walk.
            var title = CodexUI.Cache.located.modelButton.map(AX.title) ?? ""
            // Also re-walk when the caret moved to another message box (split view), so
            // the highlight follows the chat the user is working in.
            let cachedLooksRight = CurrentModelMatcher.isModelButtonTitle(title, among: models)
                && CodexUI.Cache.windowForLocated.map { CFEqual($0, window) } == true
                && !CodexUI.Cache.focusMoved(window: window)
            if !cachedLooksRight {
                guard force || Date().timeIntervalSince(self.lastWalk) > 3 else { return }
                self.lastWalk = Date()
                title = CodexUI.Cache.current(window: window, models: models, forceRefresh: true)
                    .modelButton.map(AX.title) ?? ""
            }
            let id = CurrentModelMatcher.model(forTitle: title, among: models)?.id
            DispatchQueue.main.async {
                guard !self.hasReported || self.lastReported != id else { return }
                self.hasReported = true
                self.lastReported = id
                self.onChange?(id)
            }
        }
    }
}

import AppKit
import ApplicationServices
import CoreGraphics
import CodexModelBarCore
import CodexNativeControls

/// Follows every Codex task window so each one's bar can stay glued underneath it.
///
/// Uses Accessibility to identify task windows and CoreGraphics to follow their
/// bounds without walking Codex's web content. Two cadences:
///  - **Slow scan (1 s + on app activation or a Codex window change):** lists every
///    on-screen window, picks Codex's main window and its other task windows,
///    ignoring computer-use previews even when they are large.
///  - **Fast follow (30 Hz):** re-reads the task windows and known Agent Flow
///    panels, avoiding a full list while any of them is dragged.
///
/// Publishes a `Snapshot` whenever something the bar cares about changes.
final class CodexWindowTracker {
    /// One on-screen Codex task window; each gets its own bar (Ethan, 2026-11-08: "Want a bar per window", Claude session 1b5d58ef).
    struct TaskWindow: Equatable {
        let id: CGWindowID
        var bounds: CGRect // Top-left coordinates, the space CoreGraphics and Accessibility share: matches a watcher reading to this window and finds its AX element for a raise.
        var frame: CGRect // Cocoa coordinates, for placing its bar.
        var isMostlyCovered: Bool // Updated by the full scan, the only read of front-to-back order. Any normal window counts, so a bar never floats over Chrome covering an idle Codex window.
    }

    struct Snapshot: Equatable {
        /// Codex's running app, when it is running.
        var codexPID: pid_t?
        /// Tracked window frame in Cocoa coordinates; nil when no usable window is on screen.
        var windowFrame: CGRect?
        /// True when Codex is the active app; Flow can keep the toolbar visible while it owns focus.
        var codexIsFrontmost: Bool
        var toolbarContextIsActive = false
        var agentFlowPanelFrames: [CGRect] = [] // Keep Ethan’s “claude bar” (this model toolbar) clear of Agent Flow’s floating “flow bar”.
        /// Every Codex task window on screen, frontmost first.
        var taskWindows: [TaskWindow] = []
        /// The task window Codex has focused, whose bar reports Agentic Mouse actions.
        var focusedWindowID: CGWindowID?

        var shouldShowToolbar: Bool {
            codexPID != nil && (windowFrame != nil || !taskWindows.isEmpty) && (codexIsFrontmost || toolbarContextIsActive) // Keep Codex's Flow/accessory focus handoff visible, but do not float over unrelated work just because mirrored HUDs exist (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
        }

        /// Keep Flow or our accessory in Codex's context only until another ordinary app takes focus.
        mutating func updateForeground(pid: pid_t?, isCompanion: Bool, lastDirectApplicationPID: inout pid_t?) {
            if !isCompanion { lastDirectApplicationPID = pid }
            codexIsFrontmost = codexPID != nil && pid == codexPID
            toolbarContextIsActive = codexPID != nil && lastDirectApplicationPID == codexPID && (codexIsFrontmost || isCompanion)
        }

        /// Move beside Flow only when one of its visible surfaces covers the normal strip.
        func agentFlowHUDFrame(overlapping toolbarFrame: CGRect) -> CGRect? {
            agentFlowPanelFrames.filter { $0.intersects(toolbarFrame) }
                .max { $0.width * $0.height < $1.width * $1.height } // A distant or mirrored HUD must not move a bar the user can already see (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
        }

        /// The task window an Accessibility read came from. Frontmost first: two windows only share a frame when one hides the other.
        func taskWindow(matching bounds: CGRect) -> TaskWindow? {
            taskWindows.first { CodexWindowTracker.sameFrame($0.bounds, bounds) }
        }
    }

    var onChange: ((Snapshot) -> Void)?
    private(set) var snapshot = Snapshot(codexPID: nil, windowFrame: nil, codexIsFrontmost: false)

    private var trackedWindowID: CGWindowID?
    private var agentFlowPanelWindowIDs: [CGWindowID] = []
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var scanInFlight = false
    private var lastDirectApplicationPID: pid_t?

    /// Minimum size for a window to count as the Codex main window.
    private let minimumSize = CGSize(width: 480, height: 360)

    func start() {
        // Re-evaluate immediately when apps activate/launch/quit instead of waiting
        // for the next slow tick, so the bar appears/disappears without lag.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.followTrackedWindow() // Remember each activation even if a quick Codex → Chrome → Flow sequence fits between follow ticks.
                self?.fullScan()
            })
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.fullScan() }
        fastTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.followTrackedWindow() }
        // `.common` keeps the timers firing while a menu (our right-click menu) is open.
        [slowTimer, fastTimer].forEach { RunLoop.main.add($0!, forMode: .common) }
        fullScan()
    }

    /// The running Codex app, if any.
    var codexApp: NSRunningApplication? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.codexBundleID)
            .first(where: { !$0.isTerminated }) { return app }
        guard let pid = snapshot.codexPID, let previous = NSRunningApplication(processIdentifier: pid),
              !previous.isTerminated, previous.bundleIdentifier == AppInfo.codexBundleID else { return nil }
        Log.info("codex-discovery enumeration-miss retained-pid=\(pid)")
        return previous // Bundle enumeration can miss a still-running app; revalidate the exact known PID instead of silently hiding its toolbar.
    }

    // MARK: - Scanning

    /// Full window-list scan: choose the Codex windows to follow.
    func fullScan() {
        guard !scanInFlight else { return }
        guard let app = codexApp else {
            if let previousPID = snapshot.codexPID { Log.info("codex-discovery no-live-app previous-pid=\(previousPID)") }
            trackedWindowID = nil
            publish(Snapshot(codexPID: nil, windowFrame: nil, codexIsFrontmost: false))
            return
        }
        let pid = app.processIdentifier
        let agentFlowPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.agentFlowBundleID)
            .map(\.processIdentifier))
        scanInFlight = true
        AX.queue.async { [weak self] in
            let needsMainWindow = AX.isTrusted
            let mainWindow: AXUIElement? = AX.attribute(AXUIElementCreateApplication(pid), kAXMainWindowAttribute)
            let mainFrame = mainWindow.flatMap(Self.axFrame)
            let standardWindowFrames = Self.standardWindowFrames(pid: pid)
            let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanInFlight = false
                guard self.codexApp?.processIdentifier == pid else { self.fullScan(); return }
                let chosen = Self.chooseWindow(in: infos, pid: pid, mainFrame: mainFrame,
                                               needsMainWindow: needsMainWindow, minimumSize: self.minimumSize,
                                               previousWindowID: self.trackedWindowID)
                if self.trackedWindowID != chosen?.0 {
                    Log.info("window-anchor id=\(chosen.map { String($0.0) } ?? "none") source=\(needsMainWindow ? "ax-main-window-or-last-visible" : "permission-setup")")
                }
                self.trackedWindowID = chosen?.0
                let panels = Self.agentFlowPanels(in: infos, pids: agentFlowPIDs)
                self.agentFlowPanelWindowIDs = panels.map { $0.0 }
                let windows = Self.taskWindows(in: infos, pid: pid, standardWindowFrames: standardWindowFrames, chosenWindowID: chosen?.0,
                                               previousWindowIDs: needsMainWindow ? Set(self.snapshot.taskWindows.map(\.id)) : [], minimumSize: self.minimumSize) // Before Accessibility is granted only the permission bar shows, as before.
                var next = Snapshot(codexPID: pid, windowFrame: chosen.map { Self.cocoa($0.1) },
                                    codexIsFrontmost: false, agentFlowPanelFrames: panels.map { Self.cocoa($0.1) },
                                    taskWindows: windows, focusedWindowID: chosen?.0)
                self.updateForeground(in: &next)
                self.publish(next)
            }
        }
    }

    /// Agent Flow’s mini editor sits above floating level; its ordinary settings window is not an obstruction.
    static func agentFlowPanels(in infos: [[String: Any]], pids: Set<pid_t>) -> [(CGWindowID, CGRect)] {
        infos.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let layer = info[kCGWindowLayer as String] as? Int, layer > NSWindow.Level.floating.rawValue,
                  (info[kCGWindowIsOnscreen as String] as? Bool) == true,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let frame = bounds(of: info), !frame.isEmpty else { return nil }
            return (id, frame)
        }
    }

    /// Finds the on-screen main task window; a large, frontmost preview is not a task window.
    static func chooseWindow(in infos: [[String: Any]], pid: pid_t, mainFrame: CGRect?,
                             needsMainWindow: Bool, minimumSize: CGSize = CGSize(width: 480, height: 360),
                             previousWindowID: CGWindowID? = nil) -> (CGWindowID, CGRect)? {
        var previousWindow: (CGWindowID, CGRect)?
        for info in infos {
            guard let (number, bounds) = candidate(info, pid: pid, minimumSize: minimumSize) else { continue }
            if number == previousWindowID, (info[kCGWindowIsOnscreen as String] as? Bool) == true {
                previousWindow = (number, bounds) // An AX lookup can briefly disappear while Flow starts; keep only the already identified, still-visible task window until its replacement is ready (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
            }
            if needsMainWindow { // Never fall back to a preview when a granted AX lookup temporarily fails.
                guard let mainFrame, sameFrame(bounds, mainFrame) else { continue }
            }
            return (number, bounds) // Before Accessibility is granted, retain the visible bar so its permission action remains reachable.
        }
        return previousWindow
    }

    /// Lists the windows that get a bar, frontmost first. Only an Accessibility standard window counts, so large computer-use previews get none.
    static func taskWindows(in infos: [[String: Any]], pid: pid_t, standardWindowFrames: [CGRect], chosenWindowID: CGWindowID?,
                            previousWindowIDs: Set<CGWindowID>, minimumSize: CGSize = CGSize(width: 480, height: 360)) -> [TaskWindow] {
        var windowsInFront: [CGRect] = []
        var taskWindows: [TaskWindow] = []
        for info in infos {
            guard (info[kCGWindowLayer as String] as? Int) == 0, ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let bounds = Self.bounds(of: info) else { continue }
            defer { windowsInFront.append(bounds) }
            guard let (number, _) = candidate(info, pid: pid, minimumSize: minimumSize) else { continue }
            let isKnown = number == chosenWindowID // The main window always keeps its bar, as it did when it was the only one.
                || (previousWindowIDs.contains(number) && (info[kCGWindowIsOnscreen as String] as? Bool) == true) // A drag can separate the AX and CoreGraphics frames for a moment; keep the bar instead of flickering it, as `chooseWindow` does for the main window.
            guard isKnown || standardWindowFrames.contains(where: { sameFrame($0, bounds) }) else { continue }
            taskWindows.append(TaskWindow(id: number, bounds: bounds, frame: cocoa(bounds),
                                          isMostlyCovered: BarPlacement.isMostlyCovered(bounds, by: windowsInFront)))
        }
        return taskWindows
    }

    /// A normal-layer, visible Codex window large enough to be a task window.
    private static func candidate(_ info: [String: Any], pid: pid_t, minimumSize: CGSize) -> (CGWindowID, CGRect)? {
        guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
              (info[kCGWindowLayer as String] as? Int) == 0,
              let number = info[kCGWindowNumber as String] as? CGWindowID,
              let bounds = Self.bounds(of: info),
              bounds.width >= minimumSize.width, bounds.height >= minimumSize.height,
              ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01
        else { return nil }
        return (number, bounds)
    }

    /// CoreGraphics and Accessibility round a window's frame differently, by up to two points.
    static func sameFrame(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) <= 2 && abs(first.minY - second.minY) <= 2
            && abs(first.width - second.width) <= 2 && abs(first.height - second.height) <= 2
    }

    /// Frames of Codex's standard windows. This is one attribute list per second, not a walk of any chat's content.
    private static func standardWindowFrames(pid: pid_t) -> [CGRect] {
        let windows: [AXUIElement] = AX.attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
        return windows.filter { AX.string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole as String }.compactMap(axFrame)
    }

    /// Makes one Codex window the focused one, so the switcher that runs next acts on its composer. Call on `AX.queue`.
    static func raise(windowAt bounds: CGRect, pid: pid_t) {
        let windows: [AXUIElement] = AX.attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
        guard let window = windows.first(where: { axFrame($0).map { sameFrame($0, bounds) } ?? false }),
              AX.focusedWindow(pid: pid).map({ !CFEqual($0, window) }) ?? true else { return }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        CodexControlWait.until(timeout: 0.6) { AX.focusedWindow(pid: pid).map { CFEqual($0, window) } == true } // Readiness only: the action still goes ahead on timeout, because Ethan's rule is never to gate a send on verification (2026-10-29).
    }

    /// False once a window is closed; a window on another Space or minimised still exists and keeps its bar's last reading.
    static func windowExists(_ id: CGWindowID) -> Bool {
        !(CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []).isEmpty
    }

    /// Cheap per-frame update of the task windows and known floating panels.
    private func followTrackedWindow() {
        var next = snapshot
        updateForeground(in: &next) // Foreground changes must not wait behind slow composer reads on AX.queue.
        next.taskWindows = next.taskWindows.compactMap { window in
            let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, window.id) as? [[String: Any]] ?? []
            guard let info = list.first, (info[kCGWindowIsOnscreen as String] as? Bool) == true,
                  let bounds = Self.bounds(of: info) else { return nil }
            var followed = window
            followed.bounds = bounds
            followed.frame = Self.cocoa(bounds)
            return followed
        }
        guard let id = trackedWindowID else { publish(next); return }
        guard let tracked = next.taskWindows.first(where: { $0.id == id }) else {
            // Window closed/minimised/moved to another Space: rescan to pick another.
            next.windowFrame = nil
            publish(next)
            fullScan()
            return
        }
        next.windowFrame = tracked.frame
        next.agentFlowPanelFrames = agentFlowPanelWindowIDs.compactMap { id in
            let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
            guard let info = infos.first,
                  (info[kCGWindowIsOnscreen as String] as? Bool) == true,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let frame = Self.bounds(of: info) else { return nil }
            return Self.cocoa(frame)
        } // Reuse the existing follow timer and known IDs; no new window-list scan or Agent Flow input reads.
        publish(next)
    }

    private func updateForeground(in next: inout Snapshot) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        next.updateForeground(pid: frontmost?.processIdentifier,
                              isCompanion: frontmost?.bundleIdentifier == AppInfo.agentFlowBundleID || frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                              lastDirectApplicationPID: &lastDirectApplicationPID)
    }

    private func publish(_ next: Snapshot) {
        guard next != snapshot else { return }
        snapshot = next
        onChange?(next)
    }

    // MARK: - Geometry helpers

    static func axFrame(_ window: AXUIElement) -> CGRect? {
        guard let position: AXValue = AX.attribute(window, kAXPositionAttribute),
              let size: AXValue = AX.attribute(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private static func bounds(of info: [String: Any]) -> CGRect? {
        guard let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict)
    }

    /// CG bounds (top-left origin) → Cocoa frame (bottom-left origin of the primary screen).
    private static func cocoa(_ bounds: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CoordinateConversion.cocoaRect(fromCGBounds: bounds, primaryScreenHeight: primaryHeight)
    }
}

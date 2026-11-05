import AppKit
import ApplicationServices
import CoreGraphics
import CodexModelBarCore

/// Follows the Codex main window so the bar can stay glued underneath it.
///
/// Uses Accessibility to identify the main task window and CoreGraphics to follow
/// its bounds without walking Codex's web content. Two cadences:
///  - **Slow scan (1 s + on app activation):** lists every on-screen window and picks
///    Codex's main window, ignoring computer-use previews even when they are large.
///  - **Fast follow (30 Hz):** re-reads the tracked window and known Agent Flow
///    panels, avoiding a full list while either window is dragged.
///
/// Publishes a `Snapshot` whenever something the bar cares about changes.
final class CodexWindowTracker {
    struct Snapshot: Equatable {
        /// Codex's running app, when it is running.
        var codexPID: pid_t?
        /// Tracked window frame in Cocoa coordinates; nil when no usable window is on screen.
        var windowFrame: CGRect?
        /// True when Codex is the active app; Flow can keep the toolbar visible while it owns focus.
        var codexIsFrontmost: Bool
        var toolbarContextIsActive = false
        var agentFlowPanelFrames: [CGRect] = [] // Keep Ethan’s “claude bar” (this model toolbar) clear of Agent Flow’s floating “flow bar”.

        var shouldShowToolbar: Bool {
            codexPID != nil && windowFrame != nil && (codexIsFrontmost || toolbarContextIsActive) // Keep Codex's Flow/accessory focus handoff visible, but do not float over unrelated work just because mirrored HUDs exist (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
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

    /// Full window-list scan: choose the Codex window to follow.
    private func fullScan() {
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
                var next = Snapshot(codexPID: pid, windowFrame: chosen.map { Self.cocoa($0.1) },
                                    codexIsFrontmost: false, agentFlowPanelFrames: panels.map { Self.cocoa($0.1) })
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
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = Self.bounds(of: info),
                  bounds.width >= minimumSize.width, bounds.height >= minimumSize.height,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01
            else { continue }
            if number == previousWindowID, (info[kCGWindowIsOnscreen as String] as? Bool) == true {
                previousWindow = (number, bounds) // An AX lookup can briefly disappear while Flow starts; keep only the already identified, still-visible task window until its replacement is ready (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
            }
            if needsMainWindow { // Never fall back to a preview when a granted AX lookup temporarily fails.
                guard let mainFrame,
                      abs(bounds.minX - mainFrame.minX) <= 2, abs(bounds.minY - mainFrame.minY) <= 2,
                      abs(bounds.width - mainFrame.width) <= 2, abs(bounds.height - mainFrame.height) <= 2
                else { continue }
            }
            return (number, bounds) // Before Accessibility is granted, retain the visible bar so its permission action remains reachable.
        }
        return previousWindow
    }

    /// Cheap per-frame update of the tracked window and known floating panels.
    private func followTrackedWindow() {
        var next = snapshot
        updateForeground(in: &next) // Foreground changes must not wait behind slow composer reads on AX.queue.
        guard let id = trackedWindowID else { publish(next); return }
        let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        guard let info = list.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) ?? false,
              let bounds = Self.bounds(of: info) else {
            // Window closed/minimised/moved to another Space: rescan to pick another.
            next.windowFrame = nil
            publish(next)
            fullScan()
            return
        }
        next.windowFrame = Self.cocoa(bounds)
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

    private static func axFrame(_ window: AXUIElement) -> CGRect? {
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

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
///  - **Fast follow (30 Hz):** re-reads only that one window's bounds, which is far
///    cheaper than a full list, so the bar keeps up while the window is dragged.
///
/// Publishes a `Snapshot` whenever something the bar cares about changes.
final class CodexWindowTracker {
    struct Snapshot: Equatable {
        /// Codex's running app, when it is running.
        var codexPID: pid_t?
        /// Tracked window frame in Cocoa coordinates; nil when no usable window is on screen.
        var windowFrame: CGRect?
        /// True when Codex is the active app (the bar only shows then).
        var codexIsFrontmost: Bool
    }

    var onChange: ((Snapshot) -> Void)?
    private(set) var snapshot = Snapshot(codexPID: nil, windowFrame: nil, codexIsFrontmost: false)

    private var trackedWindowID: CGWindowID?
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var scanInFlight = false

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
        NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.codexBundleID)
            .first(where: { !$0.isTerminated })
    }

    // MARK: - Scanning

    /// Full window-list scan: choose the Codex window to follow.
    private func fullScan() {
        guard !scanInFlight else { return }
        guard let app = codexApp else {
            trackedWindowID = nil
            publish(Snapshot(codexPID: nil, windowFrame: nil, codexIsFrontmost: false))
            return
        }
        let pid = app.processIdentifier
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
                                               needsMainWindow: needsMainWindow, minimumSize: self.minimumSize)
                if self.trackedWindowID != chosen?.0 {
                    Log.info("window-anchor id=\(chosen.map { String($0.0) } ?? "none") source=\(needsMainWindow ? "ax-main-window" : "permission-setup")")
                }
                self.trackedWindowID = chosen?.0
                self.publish(Snapshot(codexPID: pid, windowFrame: chosen.map { Self.cocoa($0.1) },
                                      codexIsFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == pid))
            }
        }
    }

    /// Finds the on-screen main task window; a large, frontmost preview is not a task window.
    static func chooseWindow(in infos: [[String: Any]], pid: pid_t, mainFrame: CGRect?,
                             needsMainWindow: Bool, minimumSize: CGSize = CGSize(width: 480, height: 360)) -> (CGWindowID, CGRect)? {
        for info in infos {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = Self.bounds(of: info),
                  bounds.width >= minimumSize.width, bounds.height >= minimumSize.height,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01
            else { continue }
            if needsMainWindow { // Never fall back to a preview when a granted AX lookup temporarily fails.
                guard let mainFrame,
                      abs(bounds.minX - mainFrame.minX) <= 2, abs(bounds.minY - mainFrame.minY) <= 2,
                      abs(bounds.width - mainFrame.width) <= 2, abs(bounds.height - mainFrame.height) <= 2
                else { continue }
            }
            return (number, bounds) // Before Accessibility is granted, retain the visible bar so its permission action remains reachable.
        }
        return nil
    }

    /// Cheap per-frame update of just the tracked window's bounds.
    private func followTrackedWindow() {
        guard let id = trackedWindowID else { return }
        let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        guard let info = list.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) ?? false,
              let bounds = Self.bounds(of: info) else {
            // Window closed/minimised/moved to another Space: rescan to pick another.
            fullScan()
            return
        }
        var next = snapshot
        next.windowFrame = Self.cocoa(bounds)
        publish(next)
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

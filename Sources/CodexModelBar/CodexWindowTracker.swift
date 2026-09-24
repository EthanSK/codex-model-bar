import AppKit
import CoreGraphics
import CodexModelBarCore

/// Follows the Codex main window so the bar can stay glued underneath it.
///
/// Uses CoreGraphics window lists (no Accessibility needed, cheap, never touches
/// Codex). Two cadences:
///  - **Slow scan (1 s + on app activation):** lists every on-screen window and picks
///    Codex's frontmost "real" window (layer 0, at least 480×360 so the small
///    hotkey/quick-chat windows are ignored).
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
        guard let app = codexApp else {
            trackedWindowID = nil
            publish(Snapshot(codexPID: nil, windowFrame: nil, codexIsFrontmost: false))
            return
        }
        let pid = app.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid

        // The list is ordered front-to-back, so the first qualifying window is the
        // one the user is looking at (handles chats opened in extra windows).
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var chosen: (CGWindowID, CGRect)?
        for info in infos {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = Self.bounds(of: info),
                  bounds.width >= minimumSize.width, bounds.height >= minimumSize.height,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01
            else { continue }
            chosen = (number, bounds)
            break
        }
        trackedWindowID = chosen?.0
        publish(Snapshot(codexPID: pid, windowFrame: chosen.map { Self.cocoa($0.1) }, codexIsFrontmost: frontmost))
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

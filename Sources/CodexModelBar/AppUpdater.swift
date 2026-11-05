// Sparkle supplies signed update checks, downloads and standard installation UI.
// Hold a requested relaunch until the existing model, speed and reasoning actions
// finish; updating must not interrupt a keyboard handoff to the current chat.
import AppKit
import Sparkle

// AppController and Sparkle call this on AppKit's main thread. Keep its existing
// synchronous action completions intact rather than adding asynchronous hops.
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private var installWhenIdle: (() -> Void)?
    private let mayInstall: () -> Bool

    init(mayInstall: @escaping () -> Bool) {
        self.mayInstall = mayInstall
        super.init()
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }
    var automaticChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    func start() {
        guard controller == nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheck else { return }
        controller?.checkForUpdates(nil)
    }

    func resumeIfIdle() {
        guard mayInstall(), let install = installWhenIdle else { return }
        installWhenIdle = nil
        install()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeRelaunch(installHandler)
    }

    // Keep the busy-action boundary testable without starting an update or AX.
    func postponeRelaunch(_ installHandler: @escaping () -> Void) -> Bool {
        guard !mayInstall() else { return false }
        installWhenIdle = installHandler
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        cancelPendingRelaunch()
        Log.info("update aborted: \(error.localizedDescription)")
    }

    func cancelPendingRelaunch() { installWhenIdle = nil }
}

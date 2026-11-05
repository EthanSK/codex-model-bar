import XCTest
@testable import CodexModelBar

final class AppUpdaterTests: XCTestCase {
    @MainActor func testRelaunchWaitsForAnActiveActionAndResumesOnce() {
        var busy = true
        var installs = 0
        let updater = AppUpdater(mayInstall: { !busy })
        XCTAssertTrue(updater.postponeRelaunch { installs += 1 })
        updater.resumeIfIdle()
        XCTAssertEqual(installs, 0)
        busy = false
        updater.resumeIfIdle()
        updater.resumeIfIdle()
        XCTAssertEqual(installs, 1)
    }

    @MainActor func testIdleRelaunchStaysWithSparkle() {
        let updater = AppUpdater(mayInstall: { true })
        XCTAssertFalse(updater.postponeRelaunch { XCTFail("Sparkle owns an immediate relaunch") })
        updater.resumeIfIdle()
    }

    @MainActor func testAbortedUpdateDoesNotResumeLater() {
        var busy = true
        let updater = AppUpdater(mayInstall: { !busy })
        XCTAssertTrue(updater.postponeRelaunch { XCTFail("Aborted installation resumed") })
        updater.cancelPendingRelaunch()
        busy = false
        updater.resumeIfIdle()
    }
}

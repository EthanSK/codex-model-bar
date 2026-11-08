import AppKit
import ServiceManagement
import CodexModelBarCore

/// Wires everything together:
///  - `CodexWindowTracker` tells us where each Codex window is and whether Codex is in front,
///  - `BarPanel`/`BarView` draw one toolbar under each Codex window or beside the floating Flow HUD,
///  - `ModelCatalogService` supplies the model list,
///  - `CurrentModelWatcher` highlights the open chat's model,
///  - `ModelSwitcher` performs a switch when a button is clicked.
final class AppController: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// One toolbar for one Codex window. An idle window's bar keeps its last reading: only the focused window is read live, so no extra background Accessibility walks (Ethan's multi-window default, 2026-11-08, Claude session 1b5d58ef).
    private struct WindowBar {
        let panel = BarPanel()
        let view = BarView(frame: .zero)
    }

    private let tracker = CodexWindowTracker()
    private var bars: [CGWindowID: WindowBar] = [:]
    private var latestReading: (selection: CurrentSelection, windowBounds: CGRect)? // Kept so a window's first reading is not lost when it arrives before the tracker has listed that window.
    private let catalog = ModelCatalogService()
    private let watcher = CurrentModelWatcher()
    private let switcher = ModelSwitcher()
    private let reasoningSwitcher = ReasoningSwitcher()
    private let speedSwitcher = SpeedSwitcher()
    private var updater: AppUpdater?

    /// Every model Codex offers (before the user's show/hide choices).
    private var allModels: [CodexModel] = []
    private var refreshTimer: Timer?
    private var cacheWatchTimer: Timer?
    private var lastCodexCacheModification: Date?
    private var trustTimer: Timer?
    private var lastToolbarVisibilityContext: String?

    private var barViews: [BarView] { bars.values.map(\.view) }

    private var visibleModels: [CodexModel] {
        let hidden = Preferences.hiddenModelIDs
        return allModels.filter { !$0.hidden && !hidden.contains($0.id) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("startup version=\(AppInfo.version) build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "dev") pid=\(ProcessInfo.processInfo.processIdentifier)")
        Log.resourcesIfNeeded()
        AppSetup.start { [weak self] in self?.refreshModels(forceAppServer: true) }
        updater = AppUpdater(mayInstall: { [weak self] in
            guard let self else { return false }
            return !self.switcher.isBusy && !self.reasoningSwitcher.isBusy && !self.speedSwitcher.isBusy
        })
        updater?.start()
        // Instant startup from the cached list, then refresh from Codex itself.
        applyModels(catalog.loadCachedModels())
        refreshModels()
        // Codex clients share this cache. Merge new observations after sign-in or
        // refresh without discarding models missing from one client's snapshot.
        lastCodexCacheModification = catalog.codexCacheModificationDate
        cacheWatchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Log.resourcesIfNeeded()
            let modified = self.catalog.codexCacheModificationDate
            guard modified != self.lastCodexCacheModification else { return }
            self.lastCodexCacheModification = modified
            self.refreshModels()
        }
        // Codex's catalogue rarely changes; refresh every 30 minutes (and on demand
        // from the right-click menu).
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.refreshModels()
        }

        watcher.onChange = { [weak self] selection, windowBounds in
            guard let self, let windowBounds else { return } // With no window to credit it to, every bar keeps its last reading.
            self.latestReading = (selection, windowBounds)
            self.applyLatestReading()
        }
        watcher.onFocusChange = { [weak self] in
            self?.barViews.forEach { $0.cancelReasoningPreview() }
        }
        watcher.onFocusedWindowChange = { [weak self] in self?.tracker.fullScan() }
        tracker.onChange = { [weak self] snapshot in self?.layout(for: snapshot) }
        tracker.start() // Click-to-focus was removed after unreliable live targeting; do not restore a guessed pane resolver (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).

        registerLoginItemOnFirstLaunch()
        updateTrustStatus(prompt: true)
        // macOS gives no notification when Accessibility is granted, so poll gently.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updateTrustStatus(prompt: false)
        }
    }

    // MARK: - Layout and visibility

    /// Positions or hides one bar per Codex window for the latest tracker snapshot.
    private func layout(for snapshot: CodexWindowTracker.Snapshot) {
        watcher.update(pid: snapshot.codexIsFrontmost ? snapshot.codexPID : nil, models: allModels)

        let shownWindows = snapshot.shouldShowToolbar ? snapshot.taskWindows.filter { !$0.isMostlyCovered } : [] // A covered window's bar hides; it would otherwise float over the window hiding it (Ethan's multi-window default, Claude session 1b5d58ef).
        var shownWindowIDs = Set<CGWindowID>()
        var placedBarFrames: [CGRect] = [] // Frontmost windows place first, so two overlapping windows' bars cannot land on each other.
        var barContexts: [String] = []
        var barResults: [String] = []
        var madeBar = false
        for window in shownWindows {
            guard let windowScreen = screen(containing: window.frame) else { continue }
            let existingBar = bars[window.id]
            let bar = existingBar ?? makeBar(for: window.id)
            madeBar = madeBar || existingBar == nil
            bar.view.availableWidth = windowScreen.visibleFrame.width // Measure the normal strip every time; using the already-moved/wrapped bar would alternate between anchors.
            let normalFrame = BarPlacement.place(window: window.frame, visibleFrame: windowScreen.visibleFrame,
                                                 contentSize: bar.view.preferredSize)
            let flow = snapshot.agentFlowHUDFrame(overlapping: normalFrame) // Ethan only wants the bar beside Flow when Flow covers its normal position (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
            let targetScreen = flow.flatMap { screen(containing: $0) } ?? windowScreen
            let obstructingWindows = snapshot.agentFlowPanelFrames + shownWindows.filter { $0.id != window.id }.map(\.frame) + placedBarFrames // A covered window is left out: its bar is hidden and most of it cannot be seen, so a bar need not dodge it.
            bar.view.availableWidth = targetScreen.visibleFrame.width // Measure the normal horizontal row first; the placement rule compares both windows before choosing any narrower region.
            let frame = BarPlacement.place(
                window: window.frame,
                visibleFrame: targetScreen.visibleFrame,
                contentSize: bar.view.preferredSize,
                agentFlowHUD: flow,
                obstructingWindows: obstructingWindows,
                contentSizeForWidth: { width in
                    bar.view.availableWidth = width
                    return bar.view.preferredSize
                }
            )
            bar.view.availableWidth = frame.width // Drawing uses the same width that fitted the selected clear region, never the last rejected candidate.
            bar.view.obstructingWindows = [window.frame] + obstructingWindows // Floating notices must avoid the same Codex/Flow content as the toolbar.
            bar.panel.place(frame: frame, obstructingWindows: snapshot.agentFlowPanelFrames) // Only Flow's panels raise the bar's level; other Codex windows are normal level, below it already.
            placedBarFrames.append(frame)
            shownWindowIDs.insert(window.id)
            barContexts.append("\(window.id):has-flow=\(flow != nil):display=\(targetScreen.localizedName)")
            barResults.append("\(window.id):frame=\(frame):level=\(bar.panel.level.rawValue)")
        }
        for (id, bar) in bars where !shownWindowIDs.contains(id) {
            bar.panel.orderOut(nil)
            if !CodexWindowTracker.windowExists(id) { bars[id] = nil } // Only a closed window loses its bar; another Space or a minimise keeps the last reading for its return.
        }
        if madeBar { applyLatestReading() }

        let context = "requested=\(snapshot.shouldShowToolbar) codex-frontmost=\(snapshot.codexIsFrontmost) codex-context=\(snapshot.toolbarContextIsActive) frontmost-pid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) task-windows=\(snapshot.taskWindows.count) shown=[\(barContexts.joined(separator: ","))]"
        if lastToolbarVisibilityContext != context {
            Log.info("toolbar-presentation \(context) flow-panels=\(snapshot.agentFlowPanelFrames.count) bars=[\(barResults.joined(separator: ","))] app-hidden=\(NSApp.isHidden)") // Log the result and chosen display on visibility/context changes, without logging every drag frame.
            lastToolbarVisibilityContext = context
        }
    }

    /// Builds the bar for a newly seen window, already showing the current model list.
    private func makeBar(for windowID: CGWindowID) -> WindowBar {
        let bar = WindowBar()
        bar.panel.contentView = bar.view
        bar.view.onSelect = { [weak self] model in self?.switchTo(model, from: windowID) }
        bar.view.onSelectEffort = { [weak self] effort in self?.changeEffort(to: effort, from: windowID) }
        bar.view.onCycleSpeed = { [weak self] in self?.changeSpeed(.cycle, from: windowID) }
        bar.view.onStatusClick = { [weak self] in self?.statusClicked() }
        bar.view.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        bar.view.setCatalogModels(allModels)
        bar.view.setModels(visibleModels)
        bar.view.onSizeChange = { [weak self] in // Set after the first `setModels` so building a bar inside `layout` cannot restart it.
            guard let self else { return }
            self.layout(for: self.tracker.snapshot)
        }
        if lastTrusted == false { showAccessibilityStatus(on: bar.view) }
        bars[windowID] = bar
        return bar
    }

    /// Shows the watcher's newest reading on the bar of the window it came from.
    private func applyLatestReading() {
        guard let reading = latestReading,
              let window = tracker.snapshot.taskWindow(matching: reading.windowBounds), let bar = bars[window.id] else { return }
        bar.view.setCurrentSelection(reading.selection)
        let offered = allModels.first { $0.id == reading.selection.modelID }?.speedTiers ?? []
        bar.view.setCurrentSpeed(speedSwitcher.observe(iconVisible: reading.selection.speedIconVisible, offered: offered,
                                                       saved: reading.selection.savedSpeed))
    }

    /// The bar that reports an action: the clicked bar, or the focused window's for Agentic Mouse URLs.
    private func actingBar(for windowID: CGWindowID?) -> BarView? {
        (windowID ?? tracker.snapshot.focusedWindowID).flatMap { bars[$0]?.view }
    }

    /// A click on another window's bar acts on that window. The raise runs on the queue every switcher uses, so the action queued next finds it focused (Ethan's multi-window default, Claude session 1b5d58ef). Agentic Mouse passes nil and keeps targeting the focused window.
    private func raiseWindow(_ windowID: CGWindowID?, pid: pid_t) {
        guard let windowID, let bounds = tracker.snapshot.taskWindows.first(where: { $0.id == windowID })?.bounds else { return }
        AX.enqueueAction { CodexWindowTracker.raise(windowAt: bounds, pid: pid) }
    }

    /// The screen showing most of the window.
    private func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            a.frame.intersection(rect).area < b.frame.intersection(rect).area
        }.flatMap { $0.frame.intersects(rect) ? $0 : nil }
    }

    // MARK: - Models

    private func refreshModels(forceAppServer: Bool = false) {
        catalog.refresh(codexAppURL: tracker.codexApp?.bundleURL, forceAppServer: forceAppServer) { [weak self] models in
            guard let self else { return }
            if let models, !models.isEmpty {
                self.applyModels(models)
            } else if self.allModels.isEmpty {
                self.barViews.forEach { $0.showStatus("Failed to load models", color: .systemOrange) }
            }
        }
    }

    private func applyModels(_ models: [CodexModel]) {
        // Hidden catalogue entries can still be selected in an existing task.
        // Keep them available to the reader and slider, while hiding their buttons.
        allModels = models
        let hidden = Preferences.hiddenModelIDs
        Log.info("catalog-apply known=[\(models.map(\.id).joined(separator: ","))] visible=[\(models.filter { !$0.hidden && !hidden.contains($0.id) }.map(\.id).joined(separator: ","))]")
        barViews.forEach {
            $0.setCatalogModels(allModels)
            $0.setModels(visibleModels)
        }
        watcher.update(pid: tracker.snapshot.codexIsFrontmost ? tracker.snapshot.codexPID : nil, models: allModels)
        layout(for: tracker.snapshot)
    }

    // MARK: - Switching

    private func changeSpeed(_ request: SpeedSwitcher.Request, from windowID: CGWindowID? = nil) {
        guard AX.isTrusted else { updateTrustStatus(prompt: true); return }
        guard let codex = tracker.codexApp else { return }
        let bar = actingBar(for: windowID)
        barViews.forEach { $0.setBusySpeed(true) } // One keyboard handoff at a time across the whole app, so every bar locks.
        bar?.showStatus(nil)
        watcher.setSuspended(true)
        raiseWindow(windowID, pid: codex.processIdentifier)
        speedSwitcher.change(request, codex: codex) { [weak self] result in
            guard let self else { return }
            defer { self.updater?.resumeIfIdle() }
            switch result {
            case .requested:
                break // Let the passive watcher draw Codex's actual speed.
            case .cancelled:
                break
            case .cancelledForTyping:
                bar?.showStatus("Speed change cancelled while typing", color: .systemOrange)
            case .failed(let reason):
                bar?.showStatus(reason, color: .systemOrange)
            }
            if !self.speedSwitcher.isBusy {
                self.barViews.forEach { $0.setBusySpeed(false) }
                self.watcher.setSuspended(false)
                self.watcher.refreshSoon()
            }
        }
    }

    private func changeEffort(to effort: String, from windowID: CGWindowID) {
        guard let modelID = bars[windowID]?.view.currentModelIdentifier else { return }
        changeEffort(.select(effort, modelID: modelID), from: windowID)
    }

    /// The slider and Agentic Mouse use the same pane discovery, focus handoff and configured shortcuts.
    private func changeEffort(_ request: ReasoningSwitcher.Request, from windowID: CGWindowID? = nil) {
        guard AX.isTrusted else { updateTrustStatus(prompt: true); return }
        guard let codex = tracker.codexApp else { return }
        let bar = actingBar(for: windowID)
        barViews.forEach { $0.setBusyReasoning(true) }
        bar?.showStatus(nil)
        watcher.setSuspended(true)
        raiseWindow(windowID, pid: codex.processIdentifier)
        reasoningSwitcher.change(request, allModels: allModels, codex: codex) { [weak self] result in
            guard let self else { return }
            defer { self.updater?.resumeIfIdle() }
            switch result {
            case .changed(let selection):
                bar?.setCurrentSelection(selection)
                self.watcher.refreshSoon()
            case .requested:
                self.watcher.refreshSoon() // Never verify: the bar assumes the keys worked and simply shows Codex's next label (Ethan, 2026-10-29, Claude session f9500cd2).
            case .cancelledForTyping:
                bar?.showStatus("Reasoning change cancelled while typing", color: .systemOrange)
                self.watcher.refreshSoon()
            case .cancelled:
                break
            case .failed(let reason):
                Log.info("reasoning change \(request) failed: \(reason)")
                bar?.showStatus(reason, color: .systemOrange)
                self.watcher.refreshSoon()
            }
            if !self.reasoningSwitcher.isBusy {
                self.barViews.forEach { $0.setBusyReasoning(false) }
                self.watcher.setSuspended(false)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.count == 1, let url = urls.first, let action = MouseShortcut.action(for: url) else { return }
        switch action {
        case .speedUp:
            changeSpeed(.mouseCycle)
            return
        case .speedDown:
            changeSpeed(.mouseCycle)
            return
        case .speedCancel:
            speedSwitcher.cancelMouseCommands()
            return
        case .reasoningUp:
            changeEffort(.increase)
            return
        case .reasoningDown:
            changeEffort(.decrease)
            return
        case .reasoningCancel:
            reasoningSwitcher.cancelMouseCommands()
            return
        case .astraUltrafast: break
        }
        guard let model = allModels.first(where: { $0.id == MouseShortcut.astraModelID }) else {
            actingBar(for: nil)?.showStatus("GPT-6 Astra is unavailable", color: .systemOrange)
            return
        }
        Log.info("mouse-shortcut request=astra-ultrafast")
        switchTo(model, enableUltrafast: true)
    }

    private func switchTo(_ model: CodexModel, enableUltrafast: Bool = false, from windowID: CGWindowID? = nil) {
        guard AX.isTrusted else {
            updateTrustStatus(prompt: true)
            return
        }
        guard let codex = tracker.codexApp else { return }
        let bar = actingBar(for: windowID)
        barViews.forEach { $0.setBusyModel(id: model.id) }
        bar?.showStatus(nil)
        watcher.setSuspended(true)
        raiseWindow(windowID, pid: codex.processIdentifier)
        switcher.switchModel(to: model, allModels: allModels, codex: codex, enableUltrafast: enableUltrafast) { [weak self] result in
            guard let self else { return }
            defer { self.updater?.resumeIfIdle() }
            self.barViews.forEach { $0.setBusyModel(id: nil) }
            switch result {
            case .switched(let selection), .alreadyCurrent(let selection):
                bar?.setCurrentSelection(selection)
                if enableUltrafast {
                    self.speedSwitcher.rememberSpeed(.ultrafast)
                    bar?.showStatus("Astra Ultrafast enabled", color: .systemBlue)
                }
                self.watcher.refreshSoon()
            case .requested:
                self.watcher.refreshSoon() // The ordinary switch ends at Return; do not fabricate a model highlight from the requested target.
            case .cancelledForTyping:
                // The switcher stops rather than send keys while real keys are going down.
                bar?.showStatus("Switch cancelled while typing", color: .systemOrange)
                self.watcher.refreshSoon()
            case .failed(let reason, let searchLeft?):
                // The model search could not be removed without risking the user's own
                // text, so tell them exactly what to delete; stays until the next switch.
                Log.info("switch to \(model.id) failed: \(reason)")
                bar?.showStatus("Switch failed. Remove \"\(searchLeft)\" from message box",
                                color: .systemRed, sticky: true)
                self.watcher.refreshSoon()
            case .failed(let reason, nil):
                Log.info("switch to \(model.id) failed: \(reason)")
                bar?.showStatus(enableUltrafast ? reason : "Failed to switch to \(model.displayName)", color: .systemRed)
                self.watcher.refreshSoon()
            }
            self.watcher.setSuspended(false)
        }
    }

    // Background "did not confirm" checks were removed at Ethan's request on 2026-10-29: "never verify, just send the thing
    // assuming it's working" (Claude session f9500cd2). Do not reintroduce confirmation reads or failure notices for sent actions.

    // MARK: - Accessibility permission

    private var lastTrusted: Bool?

    private func updateTrustStatus(prompt: Bool) {
        let trusted = AX.isTrusted
        if !trusted && prompt { AX.requestTrust() }
        guard trusted != lastTrusted else { return }
        lastTrusted = trusted
        if trusted {
            barViews.forEach { $0.showStatus(nil) }
            watcher.refreshSoon()
        } else {
            barViews.forEach(showAccessibilityStatus(on:))
        }
    }

    private func showAccessibilityStatus(on view: BarView) {
        view.showStatus("Allow Accessibility access to switch models", color: .systemOrange, sticky: true)
    }

    private func statusClicked() {
        guard !AX.isTrusted else { return }
        // Opens System Settings › Privacy & Security › Accessibility.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Right-click menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        // Models submenu: tick to show a model in the bar, untick to hide it.
        let modelsItem = NSMenuItem(title: "Models", action: nil, keyEquivalent: "")
        let modelsMenu = NSMenu()
        let hidden = Preferences.hiddenModelIDs
        for model in allModels where !model.hidden {
            let item = NSMenuItem(title: model.displayName, action: #selector(toggleModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.id
            item.state = hidden.contains(model.id) ? .off : .on
            modelsMenu.addItem(item)
        }
        modelsItem.submenu = modelsMenu
        menu.addItem(modelsItem)

        let refresh = NSMenuItem(title: "Refresh models", action: #selector(refreshFromMenu), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())
        let check = NSMenuItem(title: "Check for updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        check.isEnabled = updater?.canCheck ?? false
        menu.addItem(check)
        let checks = NSMenuItem(title: "Check for updates automatically", action: #selector(toggleUpdateChecks), keyEquivalent: "")
        checks.target = self
        checks.state = updater?.automaticChecks == true ? .on : .off
        menu.addItem(checks)
        let downloads = NSMenuItem(title: "Download updates automatically", action: #selector(toggleUpdateDownloads), keyEquivalent: "")
        downloads.target = self
        downloads.state = updater?.automaticDownloads == true ? .on : .off
        downloads.isEnabled = updater?.automaticChecks == true
        menu.addItem(downloads)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit Codex Model Bar", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func toggleModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var hidden = Preferences.hiddenModelIDs
        if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
        Preferences.hiddenModelIDs = hidden
        barViews.forEach { $0.setModels(visibleModels) }
        layout(for: tracker.snapshot)
    }

    @objc private func refreshFromMenu() { refreshModels() }

    @objc private func checkForUpdates() { updater?.checkForUpdates() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(checkForUpdates): return updater?.canCheck ?? false
        case #selector(toggleUpdateDownloads): return updater?.automaticChecks == true
        default: return true
        }
    }
    @objc private func toggleUpdateChecks() {
        guard let updater else { return }
        updater.automaticChecks.toggle()
    }
    @objc private func toggleUpdateDownloads() {
        guard let updater else { return }
        updater.automaticDownloads.toggle()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Login item

    /// Registers "Open at login" once, on the very first launch, so the bar is simply
    /// there whenever Codex is. The user can turn it off from the right-click menu,
    /// and we never re-enable it after that.
    private func registerLoginItemOnFirstLaunch() {
        let key = "didOfferLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        // Only for the installed app bundle, not `swift run` development builds.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        try? SMAppService.mainApp.register()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.info("login item toggle failed: \(error)")
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

import AppKit
import ServiceManagement
import CodexModelBarCore

/// Wires everything together:
///  - `CodexWindowTracker` tells us where the Codex window is and whether Codex is in front,
///  - `BarPanel`/`BarView` draw the toolbar under Codex or beside the floating Flow HUD,
///  - `ModelCatalogService` supplies the model list,
///  - `CurrentModelWatcher` highlights the open chat's model,
///  - `ModelSwitcher` performs a switch when a button is clicked.
final class AppController: NSObject, NSApplicationDelegate {
    private let tracker = CodexWindowTracker()
    private let panel = BarPanel()
    private let barView = BarView(frame: .zero)
    private let catalog = ModelCatalogService()
    private let watcher = CurrentModelWatcher()
    private let switcher = ModelSwitcher()
    private let reasoningSwitcher = ReasoningSwitcher()
    private let speedSwitcher = SpeedSwitcher()

    /// Every model Codex offers (before the user's show/hide choices).
    private var allModels: [CodexModel] = []
    private var refreshTimer: Timer?
    private var cacheWatchTimer: Timer?
    private var lastCodexCacheModification: Date?
    private var trustTimer: Timer?
    private var lastToolbarVisibilityContext: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("startup version=\(AppInfo.version) build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "dev") pid=\(ProcessInfo.processInfo.processIdentifier)")
        Log.resourcesIfNeeded()
        panel.contentView = barView
        barView.onSelect = { [weak self] model in self?.switchTo(model) }
        barView.onSelectEffort = { [weak self] effort in self?.changeEffort(to: effort) }
        barView.onSelectSpeed = { [weak self] speed in self?.changeSpeed(to: speed) }
        barView.onStatusClick = { [weak self] in self?.statusClicked() }
        barView.onSizeChange = { [weak self] in
            guard let self else { return }
            self.layout(for: self.tracker.snapshot)
        }
        barView.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }

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

        watcher.onChange = { [weak self] selection in
            guard let self else { return }
            self.barView.setCurrentSelection(selection)
            let offered = self.allModels.first { $0.id == selection.modelID }?.speedTiers ?? []
            self.barView.setCurrentSpeed(self.speedSwitcher.observe(iconVisible: selection.speedIconVisible, offered: offered,
                                                                    saved: selection.savedSpeed))
        }
        watcher.onFocusChange = { [weak self] in
            self?.barView.cancelReasoningPreview()
        }
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

    /// Positions or hides the bar for the latest tracker snapshot.
    private func layout(for snapshot: CodexWindowTracker.Snapshot) {
        watcher.update(pid: snapshot.codexIsFrontmost ? snapshot.codexPID : nil, models: allModels)

        let windowScreen = snapshot.windowFrame.flatMap { screen(containing: $0) }
        let flow = windowScreen.flatMap { screen -> CGRect? in
            guard let window = snapshot.windowFrame else { return nil }
            barView.availableWidth = screen.visibleFrame.width // Measure the normal strip every time; using the already-moved/wrapped bar would alternate between anchors.
            let normalFrame = BarPlacement.place(window: window, visibleFrame: screen.visibleFrame,
                                                 contentSize: barView.preferredSize)
            return snapshot.agentFlowHUDFrame(overlapping: normalFrame) // Ethan only wants the bar beside Flow when Flow covers its normal position (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
        }
        let targetScreen = flow.flatMap { screen(containing: $0) } ?? windowScreen
        let visible = snapshot.shouldShowToolbar && targetScreen != nil
        let context = "requested=\(visible) codex-frontmost=\(snapshot.codexIsFrontmost) codex-context=\(snapshot.toolbarContextIsActive) frontmost-pid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) task-window=\(snapshot.windowFrame != nil) has-flow=\(flow != nil) display=\(targetScreen?.localizedName ?? "none")"
        defer {
            if lastToolbarVisibilityContext != context {
                Log.info("toolbar-presentation \(context) flow-panels=\(snapshot.agentFlowPanelFrames.count) hud=\(String(describing: flow)) frame=\(panel.frame) level=\(panel.level.rawValue) panel-visible=\(panel.isVisible) app-hidden=\(NSApp.isHidden)") // Log the result and chosen display on visibility/context changes, without logging every drag frame.
                lastToolbarVisibilityContext = context
            }
        }
        guard visible, let window = snapshot.windowFrame, let screen = targetScreen else {
            panel.orderOut(nil)
            return
        }
        barView.availableWidth = screen.visibleFrame.width // Measure the normal horizontal row first; the placement rule compares both windows before choosing any narrower region.
        let frame = BarPlacement.place(
            window: window,
            visibleFrame: screen.visibleFrame,
            contentSize: barView.preferredSize,
            agentFlowHUD: flow,
            obstructingWindows: snapshot.agentFlowPanelFrames,
            contentSizeForWidth: { width in
                self.barView.availableWidth = width
                return self.barView.preferredSize
            }
        )
        barView.availableWidth = frame.width // Drawing uses the same width that fitted the selected clear region, never the last rejected candidate.
        barView.obstructingWindows = [window] + snapshot.agentFlowPanelFrames // Floating notices must avoid the same Codex/Flow content as the toolbar.
        panel.place(frame: frame, obstructingWindows: snapshot.agentFlowPanelFrames)
    }

    /// The screen showing most of the window.
    private func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            a.frame.intersection(rect).area < b.frame.intersection(rect).area
        }.flatMap { $0.frame.intersects(rect) ? $0 : nil }
    }

    // MARK: - Models

    private func refreshModels() {
        catalog.refresh(codexAppURL: tracker.codexApp?.bundleURL) { [weak self] models in
            guard let self else { return }
            if let models, !models.isEmpty {
                self.applyModels(models)
            } else if self.allModels.isEmpty {
                self.barView.showStatus("Failed to load models", color: .systemOrange)
            }
        }
    }

    private func applyModels(_ models: [CodexModel]) {
        // Hidden catalogue entries can still be selected in an existing task.
        // Keep them available to the reader and slider, while hiding their buttons.
        allModels = models
        let hidden = Preferences.hiddenModelIDs
        Log.info("catalog-apply known=[\(models.map(\.id).joined(separator: ","))] visible=[\(models.filter { !$0.hidden && !hidden.contains($0.id) }.map(\.id).joined(separator: ","))]")
        barView.setCatalogModels(allModels)
        barView.setModels(allModels.filter { !$0.hidden && !hidden.contains($0.id) })
        watcher.update(pid: tracker.snapshot.codexIsFrontmost ? tracker.snapshot.codexPID : nil, models: allModels)
        layout(for: tracker.snapshot)
    }

    // MARK: - Switching

    private func changeSpeed(to speed: ResponseSpeed) {
        changeSpeed(.select(speed))
    }

    private func changeSpeed(_ request: SpeedSwitcher.Request) {
        guard AX.isTrusted else { updateTrustStatus(prompt: true); return }
        guard let codex = tracker.codexApp else { return }
        barView.setBusySpeed(true)
        barView.showStatus(nil)
        watcher.setSuspended(true)
        speedSwitcher.change(request, codex: codex) { [weak self] result in
            guard let self else { return }
            switch result {
            case .changed(let speed):
                self.barView.showStatus("Speed: \(speed.rawValue)")
            case .requested(let speed):
                self.barView.showStatus("Requested \(speed.rawValue)")
                self.barView.setCurrentSpeed(self.speedSwitcher.rememberedSpeed) // Fill the expected icon at once; the watcher's next read of Codex's icon replaces it.
            case .cancelled:
                break
            case .cancelledForTyping:
                self.barView.showStatus("Speed change cancelled while typing", color: .systemOrange)
            case .failed(let reason):
                self.barView.showStatus(reason, color: .systemOrange)
            }
            if !self.speedSwitcher.isBusy {
                self.barView.setBusySpeed(false)
                self.watcher.setSuspended(false)
                self.watcher.refreshSoon()
            }
        }
    }

    private func changeEffort(to effort: String) {
        guard let modelID = barView.currentModelIdentifier else { return }
        changeEffort(.select(effort, modelID: modelID))
    }

    /// The slider and Agentic Mouse use the same pane discovery, focus handoff and configured shortcuts.
    private func changeEffort(_ request: ReasoningSwitcher.Request) {
        guard AX.isTrusted else { updateTrustStatus(prompt: true); return }
        guard let codex = tracker.codexApp else { return }
        barView.setBusyReasoning(true)
        barView.showStatus(nil)
        watcher.setSuspended(true)
        reasoningSwitcher.change(request, allModels: allModels, codex: codex) { [weak self] result in
            guard let self else { return }
            switch result {
            case .changed(let selection):
                self.barView.setCurrentSelection(selection)
                self.watcher.refreshSoon()
            case .requested:
                self.watcher.refreshSoon() // Never verify: the bar assumes the keys worked and simply shows Codex's next label (Ethan, 2026-10-29, Claude session f9500cd2).
            case .cancelledForTyping:
                self.barView.showStatus("Reasoning change cancelled while typing", color: .systemOrange)
                self.watcher.refreshSoon()
            case .cancelled:
                break
            case .failed(let reason):
                Log.info("reasoning change \(request) failed: \(reason)")
                self.barView.showStatus(reason, color: .systemOrange)
                self.watcher.refreshSoon()
            }
            if !self.reasoningSwitcher.isBusy {
                self.barView.setBusyReasoning(false)
                self.watcher.setSuspended(false)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.count == 1, let url = urls.first, let action = MouseShortcut.action(for: url) else { return }
        switch action {
        case .speedUp:
            changeSpeed(.command(.ultrafast))
            return
        case .speedDown:
            changeSpeed(.command(.fast))
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
            barView.showStatus("GPT-6 Astra is unavailable", color: .systemOrange)
            return
        }
        Log.info("mouse-shortcut request=astra-ultrafast")
        switchTo(model, enableUltrafast: true)
    }

    private func switchTo(_ model: CodexModel, enableUltrafast: Bool = false) {
        guard AX.isTrusted else {
            updateTrustStatus(prompt: true)
            return
        }
        guard let codex = tracker.codexApp else { return }
        barView.setBusyModel(id: model.id)
        barView.showStatus(nil)
        watcher.setSuspended(true)
        switcher.switchModel(to: model, allModels: allModels, codex: codex, enableUltrafast: enableUltrafast) { [weak self] result in
            guard let self else { return }
            self.barView.setBusyModel(id: nil)
            switch result {
            case .switched(let selection), .alreadyCurrent(let selection):
                self.barView.setCurrentSelection(selection)
                if enableUltrafast {
                    self.speedSwitcher.rememberSpeed(.ultrafast)
                    self.barView.showStatus("Astra Ultrafast enabled", color: .systemBlue)
                }
                self.watcher.refreshSoon()
            case .requested:
                self.watcher.refreshSoon() // The ordinary switch ends at Return; do not fabricate a model highlight from the requested target.
            case .cancelledForTyping:
                // The switcher stops rather than send keys while real keys are going down.
                self.barView.showStatus("Switch cancelled while typing", color: .systemOrange)
                self.watcher.refreshSoon()
            case .failed(let reason, let searchLeft?):
                // The model search could not be removed without risking the user's own
                // text, so tell them exactly what to delete; stays until the next switch.
                Log.info("switch to \(model.id) failed: \(reason)")
                self.barView.showStatus("Switch failed. Remove \"\(searchLeft)\" from message box",
                                        color: .systemRed, sticky: true)
                self.watcher.refreshSoon()
            case .failed(let reason, nil):
                Log.info("switch to \(model.id) failed: \(reason)")
                self.barView.showStatus(enableUltrafast ? reason : "Failed to switch to \(model.displayName)", color: .systemRed)
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
            barView.showStatus(nil)
            watcher.refreshSoon()
        } else {
            barView.showStatus("Allow Accessibility access to switch models", color: .systemOrange, sticky: true)
        }
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
        barView.setModels(allModels.filter { !$0.hidden && !hidden.contains($0.id) })
        layout(for: tracker.snapshot)
    }

    @objc private func refreshFromMenu() { refreshModels() }

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

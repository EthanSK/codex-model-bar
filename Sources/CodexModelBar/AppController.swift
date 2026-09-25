import AppKit
import ServiceManagement
import CodexModelBarCore

/// Wires everything together:
///  - `CodexWindowTracker` tells us where the Codex window is and whether Codex is in front,
///  - `BarPanel`/`BarView` draw the strip of model buttons under that window,
///  - `ModelCatalogService` supplies the model list,
///  - `CurrentModelWatcher` highlights the open chat's model,
///  - `ModelSwitcher` performs a switch when a button is clicked.
final class AppController: NSObject, NSApplicationDelegate {
    private let tracker = CodexWindowTracker()
    private let panel = BarPanel()
    private let barView = BarView(frame: NSRect(x: 0, y: 0, width: 600, height: BarView.height))
    private let catalog = ModelCatalogService()
    private let watcher = CurrentModelWatcher()
    private let switcher = ModelSwitcher()
    private let reasoningSwitcher = ReasoningSwitcher()

    /// Every model Codex offers (before the user's show/hide choices).
    private var allModels: [CodexModel] = []
    private var refreshTimer: Timer?
    private var cacheWatchTimer: Timer?
    private var lastCodexCacheModification: Date?
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("startup version=\(AppInfo.version) build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "dev") pid=\(ProcessInfo.processInfo.processIdentifier)")
        panel.contentView = barView
        barView.onSelect = { [weak self] model in self?.switchTo(model) }
        barView.onSelectEffort = { [weak self] effort in self?.changeEffort(to: effort) }
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

        watcher.onChange = { [weak self] selection in self?.barView.setCurrentSelection(selection) }
        watcher.onFocusChange = { [weak self] in self?.barView.cancelReasoningPreview() }
        tracker.onChange = { [weak self] snapshot in self?.layout(for: snapshot) }
        tracker.start()

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

        // Show only while Codex is the active app and has a usable window on screen.
        // While a switch is running Codex is necessarily frontmost, so this also keeps
        // the bar visible during the switch.
        guard snapshot.codexIsFrontmost, let window = snapshot.windowFrame,
              let screen = screen(containing: window) else {
            panel.orderOut(nil)
            return
        }
        let placement = BarPlacement.place(
            window: window,
            visibleFrame: screen.visibleFrame,
            height: BarView.height,
            contentWidth: barView.preferredWidth
        )
        barView.apply(slot: placement.slot)
        if panel.frame != placement.frame {
            panel.setFrame(placement.frame, display: true)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
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

    private func changeEffort(to effort: String) {
        guard AX.isTrusted else { updateTrustStatus(prompt: true); return }
        guard let codex = tracker.codexApp,
              let modelID = barView.currentModelIdentifier,
              let model = allModels.first(where: { $0.id == modelID }) else { return }
        barView.setBusyReasoning(true)
        barView.showStatus(nil)
        watcher.setSuspended(true)
        reasoningSwitcher.setEffort(effort, model: model, allModels: allModels, codex: codex) { [weak self] result in
            guard let self else { return }
            switch result {
            case .changed:
                self.barView.setCurrentSelection(CurrentSelection(modelID: model.id, effort: effort))
                self.watcher.refreshSoon()
            case .cancelledForTyping:
                self.barView.showStatus("Reasoning change cancelled while typing", color: .systemOrange)
                self.watcher.refreshSoon()
            case .failed(let reason):
                Log.info("reasoning change to \(effort) failed: \(reason)")
                self.barView.showStatus(reason, color: .systemOrange)
                self.watcher.refreshSoon()
            }
            self.barView.setBusyReasoning(false)
            self.watcher.setSuspended(false)
        }
    }

    private func switchTo(_ model: CodexModel) {
        guard AX.isTrusted else {
            updateTrustStatus(prompt: true)
            return
        }
        guard let codex = tracker.codexApp else { return }
        barView.setBusyModel(id: model.id)
        barView.showStatus(nil)
        watcher.setSuspended(true)
        switcher.switchModel(to: model, allModels: allModels, codex: codex) { [weak self] result in
            guard let self else { return }
            self.barView.setBusyModel(id: nil)
            switch result {
            case .switched(let selection), .alreadyCurrent(let selection):
                self.barView.setCurrentSelection(selection)
                self.watcher.refreshSoon()
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
                self.barView.showStatus("Failed to switch to \(model.displayName)", color: .systemRed)
                self.watcher.refreshSoon()
            }
            self.watcher.setSuspended(false)
        }
    }

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

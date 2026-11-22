import AppKit
import ApplicationServices
import CodexModelBarCore

// MARK: - Voice chat jump
//
// A small round button that sits beside Codex's own floating Voice pill while a call
// is live. Clicking it reveals and selects the exact live Voice chat in Codex.
// Requested by Ethan 2026-11-11 (Claude session local_f5bfc491). Codex owns the pill,
// so this is a companion window that follows it; Codex itself is never patched.
//
// The bar owns only the floating button. H Chat's Show Voice command owns
// current-call identity and opening the conversation, including when the sidebar
// is closed or missing its live Voice marker.

enum HChatShowVoice {
    static let installedApp = URL(fileURLWithPath: "/Applications/HelloChat.app", isDirectory: true)
    private static let minimumBuild = 1054 // H Chat e063ed1 first handled --show-current-voice before normal app startup.
    private static let couldNotOpen = "Couldn't open the current Voice chat"

    /// Runs H Chat's command helper away from the main and Accessibility queues. — GPT-6.2 Sol
    static func openCurrentCall(in app: URL) -> String? {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.ethansk.HeyChat" else {
            return "Install H Chat to show the Voice chat"
        }
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let build = Int(version), build >= minimumBuild else {
            return "Update H Chat to show the Voice chat"
        }
        guard let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return couldNotOpen }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--show-current-voice"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.info("voice-jump h-chat launch failed")
            return couldNotOpen
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        Log.info("voice-jump h-chat exit=\(process.terminationStatus)")
        guard process.terminationReason == .exit else { return couldNotOpen }
        guard process.terminationStatus != 0 else { return nil }
        let message = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first
        return message.map { String($0.prefix(160)) } ?? couldNotOpen
    }
}

/// The floating companion window. Never takes focus, so clicking it leaves the
/// keyboard and the Voice call where they were until Codex itself navigates.
final class VoiceJumpPanel: NSPanel {
    static let buttonSize = CGSize(width: 32, height: 32)

    let button = NSButton()
    private let background = NSVisualEffectView()
    private let notice = NSTextField(labelWithString: "")
    private var noticeHideWork: DispatchWorkItem?
    var onClick: (() -> Void)?
    /// Called when the panel's size changes, so the controller can re-place it.
    var onSizeChange: (() -> Void)?

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: Self.buttonSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        // Codex's Voice overlay is a full-screen window at the floating level (CG layer 3),
        // so sit two levels above it like the toolbar does over Agent Flow.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false // The pill floats over every app, so the button must too.
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.buttonSize.height / 2
        background.layer?.masksToBounds = true
        contentView = background

        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Show Voice chat")
        button.contentTintColor = .labelColor
        button.toolTip = "Show this Voice chat in Codex"
        button.setAccessibilityLabel("Show Voice chat in Codex")
        button.target = self
        button.action = #selector(clicked)
        background.addSubview(button)

        notice.font = .systemFont(ofSize: 11, weight: .medium)
        notice.textColor = .systemOrange
        notice.lineBreakMode = .byTruncatingTail
        notice.isHidden = true
        background.addSubview(notice)
        layoutContent()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The size the panel needs now: the button alone, or the button plus a notice.
    var preferredSize: CGSize {
        guard !notice.isHidden else { return Self.buttonSize }
        let width = min(notice.intrinsicContentSize.width, 320)
        return CGSize(width: Self.buttonSize.width + 4 + width + 12, height: Self.buttonSize.height)
    }

    func setBusy(_ busy: Bool) {
        button.isEnabled = !busy
        button.alphaValue = busy ? 0.5 : 1
    }

    /// Shows a short failure notice beside the button for four seconds, matching the
    /// toolbar's notices. Passing nil clears it.
    func showNotice(_ text: String?) {
        noticeHideWork?.cancel()
        notice.stringValue = text ?? ""
        notice.toolTip = text
        notice.isHidden = (text ?? "").isEmpty
        layoutContent()
        onSizeChange?()
        guard !notice.isHidden else { return }
        let work = DispatchWorkItem { [weak self] in self?.showNotice(nil) }
        noticeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func place(frame: CGRect) {
        if self.frame != frame { setFrame(frame, display: true) }
        layoutContent()
        if !isVisible { orderFrontRegardless() }
    }

    override func orderOut(_ sender: Any?) {
        noticeHideWork?.cancel()
        notice.isHidden = true
        super.orderOut(sender)
    }

    private func layoutContent() {
        let size = frame.size == .zero ? Self.buttonSize : frame.size
        button.frame = CGRect(origin: .zero, size: Self.buttonSize)
        let noticeHeight = notice.intrinsicContentSize.height
        notice.frame = CGRect(x: Self.buttonSize.width + 4, y: (size.height - noticeHeight) / 2,
                              width: max(0, size.width - Self.buttonSize.width - 16), height: noticeHeight)
    }

    @objc private func clicked() { onClick?() }
}

/// Watches Codex's Voice pill and performs the jump.
final class VoiceChatJump {
    /// 0.5 s keeps the button beside a pill that Codex moves or restyles, at the cost of
    /// one AX window-list read per tick (plus ~80 overlay nodes while a call is live).
    static let pollInterval: TimeInterval = 0.5

    private let panel: VoiceJumpPanel
    private let codexApp: () -> NSRunningApplication?
    private let showCurrentCall: () -> String?
    private var timer: Timer?
    private var pollInFlight = false
    private var pillFrame: CGRect?
    private var isBusy = false
    private var webAccessibilityPID: pid_t?

    private static var locator: VoiceChatLocator<AXUIElement> {
        VoiceChatLocator<AXUIElement>(
            children: { AX.children($0) },
            parent: { AX.parent($0) },
            role: { AX.role($0) },
            subrole: { AX.string($0, kAXSubroleAttribute) },
            label: { element in
                let description = AX.string(element, kAXDescriptionAttribute)
                return description.isEmpty ? AX.title(element) : description
            },
            frame: { CodexWindowTracker.axFrame($0) }
        )
    }

    init(codexApp: @escaping () -> NSRunningApplication?, panel: VoiceJumpPanel? = nil,
         showCurrentCall: @escaping () -> String? = { HChatShowVoice.openCurrentCall(in: HChatShowVoice.installedApp) }) {
        self.codexApp = codexApp
        self.panel = panel ?? VoiceJumpPanel()
        self.showCurrentCall = showCurrentCall
        self.panel.onClick = { [weak self] in self?.jump() }
        self.panel.onSizeChange = { [weak self] in self?.placePanel() }
    }

    func start() {
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common) // `.common` keeps following while a menu is open, like the tracker's timers.
        self.timer = timer
        poll()
    }

    // MARK: Following the pill

    private func poll() {
        guard AX.isTrusted, let codex = codexApp(), !codex.isTerminated else { return show(pill: nil) }
        // A queued model/speed/reasoning click owns the serial AX queue; skip this tick
        // rather than make it wait (LEARNINGS 2026-10-28: polls starved gestures).
        guard !pollInFlight, !AX.hasQueuedAction else { return }
        pollInFlight = true
        let pid = codex.processIdentifier
        let enableWeb = webAccessibilityPID != pid
        webAccessibilityPID = pid
        let screenSizes = NSScreen.screens.map(\.frame.size) // Read on main; NSScreen is not for background queues.
        AX.queue.async {
            if enableWeb { AX.enableWebAccessibility(pid: pid) } // Once per Codex launch: ask Chromium to publish its web AX tree.
            let frame = Self.pillFrame(pid: pid, screenSizes: screenSizes)
            DispatchQueue.main.async { [weak self] in
                self?.pollInFlight = false
                self?.show(pill: frame)
            }
        }
    }

    /// Reads only Codex's large non-standard windows (its Voice overlay), never a task
    /// window's chat content. Call on `AX.queue`.
    ///
    /// Cost: with no such window this is one window-list read (0.2–0.3 ms measured
    /// 2026-11-11). Codex's Voice overlay was observed spanning its whole display, so
    /// small floating Codex windows, such as its Computer Use panels and menus, are
    /// skipped by size before any walk. The size test is deliberately loose (at least
    /// half a display each way, see `VoiceJumpPlacement.isOverlaySized`): the overlay's
    /// exact AX size was never recorded, and it may match the display's visible frame
    /// (menu bar and Dock removed) rather than its full frame. A strict match would have
    /// hidden the button silently on a mismatch. The 400-node cap bounds a live overlay
    /// walk: the measured overlay had about 80 nodes, with Stop voice chat early in
    /// document order. If Codex ever shrinks the overlay window, the button simply stops
    /// appearing; it can never act on the wrong chat.
    static func pillFrame(pid: pid_t, screenSizes: [CGSize]) -> CGRect? {
        let windows: [AXUIElement] = AX.attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
        for window in windows where AX.string(window, kAXSubroleAttribute) != kAXStandardWindowSubrole as String {
            guard let size = CodexWindowTracker.axFrame(window)?.size,
                  VoiceJumpPlacement.isOverlaySized(size, screenSizes: screenSizes) else { continue }
            if let frame = locator.voicePillFrame(inOverlay: window, limit: 400) { return frame }
        }
        return nil
    }

    private func show(pill: CGRect?) {
        pillFrame = pill
        placePanel()
    }

    private func placePanel() {
        guard let pill = pillFrame,
              let frame = VoiceJumpPlacement.frame(pill: pill, size: panel.preferredSize,
                                                   screens: NSScreen.screens.map(\.frame),
                                                   primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0) else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        panel.place(frame: frame)
    }

    // MARK: Jumping

    private func jump() {
        guard !isBusy else { return }
        isBusy = true
        panel.setBusy(true)
        panel.showNotice(nil)
        let finish = { [weak self] (notice: String?) in
            guard let self else { return }
            self.isBusy = false
            self.panel.setBusy(false)
            self.panel.showNotice(notice)
        }
        DispatchQueue.global(qos: .userInitiated).async { [showCurrentCall] in
            let notice = showCurrentCall()
            DispatchQueue.main.async { finish(notice) }
        }
    }
}

import AppKit
import ApplicationServices
import SQLite3
import CodexModelBarCore

// MARK: - Voice chat jump
//
// A small round button that sits beside Codex's own floating Voice pill while a call
// is live. Clicking it reveals and selects the exact live Voice chat in Codex.
// Requested by Ethan 2026-11-11 (Claude session local_f5bfc491). Codex owns the pill,
// so this is a companion window that follows it; Codex itself is never patched.
//
// Lifecycle:
//   hidden ──(poll finds "Stop voice chat" in Codex's overlay)──▶ shown beside the pill
//   shown  ──(pill moves)──▶ follows it on the next 0.5 s poll
//   shown  ──(call ends: overlay window disappears)──▶ hidden
//   click  ──▶ busy: find the marked sidebar row ▶ scroll it into view ▶ resolve its ID
//          ──▶ open codex://threads/<id> in the running Codex ▶ scroll again ▶ idle
//
// Identity comes only from Codex's own "Voice chat active" row marker (see
// VoiceChatLocator.swift for the measured evidence). Like every other bar action this
// sends its best attempt and does not verify the result (Ethan, 2026-10-29).

/// Read-only access to Codex's thread table, used only on a click.
enum CodexThreadIndex {
    /// Codex's newest `~/.codex/state_<N>.sqlite`. Codex bumps the number on schema
    /// migrations (state_5 on 2026-11-11), so pick the highest rather than hard-coding it.
    static func databaseURL(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: codexHome.path)) ?? []
        let numbered = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return nil }
            let digits = name.dropFirst("state_".count).dropLast(".sqlite".count)
            return Int(digits).map { ($0, name) }
        }
        return numbered.max { $0.0 < $1.0 }.map { codexHome.appendingPathComponent($0.1) }
    }

    /// Every non-archived thread, or nil when the database cannot be read.
    ///
    /// Opens read-only with a short busy timeout: Codex writes this WAL database
    /// continuously, and a click must not wait long behind one of its writes. Nothing
    /// here can modify Codex's state.
    static func records(at url: URL) -> [CodexThreadRecord]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        // `attached_thread_parent_id` separates side chats from sidebar rows. If a future
        // schema drops it, read without it rather than failing the whole jump.
        let queries = [
            "SELECT id, name, title, archived, attached_thread_parent_id FROM threads WHERE archived = 0",
            "SELECT id, name, title, archived, NULL FROM threads WHERE archived = 0",
        ]
        for sql in queries {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                sqlite3_finalize(statement)
                continue
            }
            defer { sqlite3_finalize(statement) }
            var records: [CodexThreadRecord] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return records }
                guard step == SQLITE_ROW else { return nil } // Busy or corrupt: report unreadable instead of a partial list that could make a duplicate look unique.
                records.append(CodexThreadRecord(id: text(statement, 0) ?? "", name: text(statement, 1),
                                                 title: text(statement, 2) ?? "",
                                                 archived: sqlite3_column_int(statement, 3) != 0,
                                                 attachedParentID: text(statement, 4)))
            }
        }
        return nil
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
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
        button.toolTip = "Show this Voice chat in Codex's sidebar"
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

    private let panel = VoiceJumpPanel()
    private let codexApp: () -> NSRunningApplication?
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
            classes: { AX.attribute($0, "AXDOMClassList") ?? [] }, // Chromium's DOM class list; identifies `sidebar-item` rows.
            frame: { CodexWindowTracker.axFrame($0) }
        )
    }

    init(codexApp: @escaping () -> NSRunningApplication?) {
        self.codexApp = codexApp
        panel.onClick = { [weak self] in self?.jump() }
        panel.onSizeChange = { [weak self] in self?.placePanel() }
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
        guard !isBusy, let codex = codexApp(), let codexURL = codex.bundleURL else { return }
        isBusy = true
        panel.setBusy(true)
        panel.showNotice(nil)
        let pid = codex.processIdentifier
        AX.enqueueAction { // A user action: the background composer poll yields to it.
            let rows = Self.activeRows(pid: pid)
            Self.scroll(rows) // Scroll first in every window that shows the row, so whichever window Codex navigates already has it in view.
            let resolution: VoiceChatResolution?
            if rows.isEmpty {
                resolution = .noActiveRow // No need to read the database.
            } else if let url = CodexThreadIndex.databaseURL(), let records = CodexThreadIndex.records(at: url) {
                resolution = VoiceChatResolver.resolve(activeRowTitles: rows.map(\.title), threads: records)
            } else {
                resolution = nil
            }
            DispatchQueue.main.async { [weak self] in
                self?.finish(resolution, rowCount: rows.count, pid: pid, codexURL: codexURL)
            }
        }
    }

    private func finish(_ resolution: VoiceChatResolution?, rowCount: Int, pid: pid_t, codexURL: URL) {
        // Diagnostics record the outcome only, never chat names or IDs.
        guard case .thread(let id, _) = resolution, let link = CodexThreadLink.url(forThreadID: id) else {
            let text: String
            switch resolution {
            case nil: text = "Couldn't read Codex's chat list"
            case .noActiveRow?: text = "Codex's sidebar isn't showing the Voice chat"
            case .conflictingRows?: text = "Codex windows disagree on the Voice chat"
            case .noMatchingThread?: text = "Couldn't identify this Voice chat"
            case .ambiguous(_, let count)?: text = "\(count) chats share this Voice chat's name"
            case .thread?: text = "Couldn't build the chat link"
            }
            Log.info("voice-jump refused reason=\(Self.reasonName(resolution)) marked-rows=\(rowCount)")
            return done(notice: text)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Send the link to the running Codex explicitly: another installed app could also
        // claim the `codex` scheme, and LaunchServices might otherwise pick it.
        NSWorkspace.shared.open([link], withApplicationAt: codexURL, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    Log.info("voice-jump open-failed error=\(error.localizedDescription)")
                    return self.done(notice: "Codex didn't open the Voice chat")
                }
                Log.info("voice-jump opened marked-rows=\(rowCount)")
                self.done(notice: nil)
                // Codex re-renders its sidebar after navigating, so scroll the marked row
                // into view once more in whichever window it chose. This completes the
                // reveal; it is not a success check, and nothing waits on it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    AX.enqueueAction { Self.scroll(Self.activeRows(pid: pid)) }
                }
            }
        }
    }

    private func done(notice: String?) {
        isBusy = false
        panel.setBusy(false)
        panel.showNotice(notice)
    }

    /// Every marked row in every Codex task window. Call on `AX.queue`.
    private static func activeRows(pid: pid_t) -> [VoiceChatLocator<AXUIElement>.ActiveRow] {
        let windows: [AXUIElement] = AX.attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
        return windows.filter { AX.string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole as String }
            .flatMap { locator.activeVoiceRows(inWindow: $0) }
    }

    /// Asks Chromium to scroll each row into view (its `scrollIntoView`). Moves no
    /// cursor and changes no focus. Call on `AX.queue`.
    private static func scroll(_ rows: [VoiceChatLocator<AXUIElement>.ActiveRow]) {
        for row in rows { AXUIElementPerformAction(row.row, "AXScrollToVisible" as CFString) }
    }

    private static func reasonName(_ resolution: VoiceChatResolution?) -> String {
        switch resolution {
        case nil: return "database-unreadable"
        case .noActiveRow?: return "no-marked-row"
        case .conflictingRows(let titles)?: return "conflicting-rows-\(titles.count)"
        case .noMatchingThread?: return "no-matching-thread"
        case .ambiguous(_, let count)?: return "ambiguous-\(count)"
        case .thread?: return "invalid-thread-id"
        }
    }
}

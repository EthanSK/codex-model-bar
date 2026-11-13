import CoreGraphics
import Foundation

// MARK: - Voice chat jump: pure logic
//
// Ethan asked for a small control beside Codex's own floating Voice panel that
// reveals and selects the exact live Voice chat in Codex's sidebar (Claude session
// local_f5bfc491, 2026-11-11). Codex owns that panel, so the bar adds a companion
// button next to it instead of patching Codex.
//
// Everything here is pure so it can be tested against synthetic trees. The AppKit
// side (`VoiceChatJump.swift`) supplies real AX elements through the closures.
//
// Measured on Codex 26.1103.60933 (build 25894) during a live call on 2026-11-11:
//  - The Voice panel is the "Quick Chat bar" inside a full-screen transparent
//    `AXDialog` window titled "ChatGPT". While a call is live it contains a button
//    labelled "Stop voice chat" inside an `AXApplicationGroup` (the visible pill).
//    The window disappears when the call ends.
//  - Codex marks the sidebar row of "the thread with an active realtime voice session"
//    (its own source string) with an `AXImage` labelled "Voice chat active". The row
//    is an `AXButton` with the DOM class `sidebar-item`, titled with the chat's name.
//    The live chat was "🏢 Company admin | Realivy and ETG", not a `🗣️ Voice |` title,
//    which is why the control never guesses from titles or from the frontmost chat.
//  - The row exposes no thread ID and no AXPress, so the bar resolves the row's exact
//    title to one thread ID in Codex's state database and opens Codex's supported
//    `codex://threads/<id>` link.
//  - The sidebar sits in an `AXLandmarkComplementary` region. Skipping `AXLandmarkMain`
//    (the open conversation) cut the search from ~4,000 nodes/1.2 s to ~950 nodes/56 ms.

/// Finds Codex's Voice pill and the sidebar row Codex itself marks as the live Voice chat.
public struct VoiceChatLocator<Node> {
    /// Codex's English accessible labels. They come from Codex's own localised strings
    /// (`avatarOverlay.stopRealtimeVoice`, `sidebarTaskRow.realtimeStatus`); another UI
    /// language would need its translations added here.
    public static var stopVoiceLabels: Set<String> { ["Stop voice chat"] }
    public static var activeVoiceRowLabels: Set<String> { ["Voice chat active"] }

    private let children: (Node) -> [Node]
    private let parent: (Node) -> Node?
    private let role: (Node) -> String
    private let subrole: (Node) -> String
    private let label: (Node) -> String
    private let classes: (Node) -> [String]
    private let frame: (Node) -> CGRect?

    public init(children: @escaping (Node) -> [Node], parent: @escaping (Node) -> Node?,
                role: @escaping (Node) -> String, subrole: @escaping (Node) -> String,
                label: @escaping (Node) -> String, classes: @escaping (Node) -> [String] = { _ in [] },
                frame: @escaping (Node) -> CGRect? = { _ in nil }) {
        self.children = children
        self.parent = parent
        self.role = role
        self.subrole = subrole
        self.label = label
        self.classes = classes
        self.frame = frame
    }

    // MARK: Voice pill

    /// The live Voice pill's visible controls, in AX (top-left origin) screen points,
    /// or nil when no call is live in this overlay window.
    ///
    /// Returns the union of the pill's buttons and toggles rather than the pill group's
    /// own frame: the group was 306 points wide while its controls spanned 210, so the
    /// group frame would leave a gap between the pill and the companion button.
    public func voicePillFrame(inOverlay root: Node, limit: Int = 1_500) -> CGRect? {
        guard let stop = first(in: root, limit: limit, where: {
            role($0) == "AXButton" && Self.stopVoiceLabels.contains(label($0))
        }) else { return nil }
        // Climb to the pill container. If Codex ever drops the application-group role,
        // fall back to the stop button's own frame rather than hiding the control.
        var container: Node? = parent(stop)
        var depth = 0
        while let node = container, subrole(node) != "AXApplicationGroup", depth < 8 {
            container = parent(node)
            depth += 1
        }
        guard let pill = container, subrole(pill) == "AXApplicationGroup" else { return usable(frame(stop)) }
        let controls = all(in: pill, limit: 300) { ["AXButton", "AXCheckBox"].contains(role($0)) }
            .compactMap { usable(frame($0)) }
        guard let first = controls.first else { return usable(frame(pill)) }
        return controls.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: Live Voice row

    /// What one window's sidebar says about the live Voice chat.
    public struct ActiveRow {
        /// The row element (an `AXButton`), used to scroll it into view.
        public let row: Node
        /// The chat name exactly as the row shows it.
        public let title: String
    }

    /// Every sidebar row Codex marks as the live Voice chat in this window.
    ///
    /// Skips `AXLandmarkMain` subtrees (the open conversation), whose transcript is
    /// most of the window's nodes and never contains sidebar rows.
    public func activeVoiceRows(inWindow root: Node, limit: Int = 6_000) -> [ActiveRow] {
        var rows: [ActiveRow] = []
        var visited = 0
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            visited += 1
            if visited > limit { break } // Bounded: a pathological tree cannot stall the shared AX queue.
            if subrole(node) == "AXLandmarkMain" { continue }
            if role(node) == "AXImage", Self.activeVoiceRowLabels.contains(label(node)),
               let row = sidebarRow(containing: node) {
                let title = label(row)
                if !title.isEmpty { rows.append(ActiveRow(row: row, title: title)) }
                continue
            }
            stack.append(contentsOf: children(node).reversed())
        }
        return rows
    }

    /// The `sidebar-item` button that owns a marker. Only a row counts: the same label on
    /// some other surface (a tooltip, a future header badge) must not choose a chat.
    private func sidebarRow(containing marker: Node) -> Node? {
        var node = parent(marker)
        var depth = 0
        while let current = node, depth < 6 {
            if role(current) == "AXButton", classes(current).contains("sidebar-item") { return current }
            node = parent(current)
            depth += 1
        }
        return nil
    }

    // MARK: Traversal

    private func first(in root: Node, limit: Int, where match: (Node) -> Bool) -> Node? {
        all(in: root, limit: limit, stopAtFirst: true, where: match).first
    }

    private func all(in root: Node, limit: Int, stopAtFirst: Bool = false, where match: (Node) -> Bool) -> [Node] {
        var found: [Node] = []
        var visited = 0
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            visited += 1
            if visited > limit { break }
            if match(node) {
                found.append(node)
                if stopAtFirst { break }
            }
            stack.append(contentsOf: children(node).reversed())
        }
        return found
    }

    private func usable(_ rect: CGRect?) -> CGRect? {
        guard let rect, rect.width > 0, rect.height > 0, rect.minX.isFinite, rect.minY.isFinite else { return nil }
        return rect
    }
}

// MARK: - Choosing the live chat

/// One thread row from Codex's state database.
public struct CodexThreadRecord: Equatable {
    public let id: String
    public let name: String?
    public let title: String
    public let archived: Bool
    /// Set for side chats attached to another chat. They share their parent's title but
    /// have no sidebar row of their own, so they are never candidates.
    public let attachedParentID: String?

    public init(id: String, name: String?, title: String, archived: Bool, attachedParentID: String?) {
        self.id = id
        self.name = name
        self.title = title
        self.archived = archived
        self.attachedParentID = attachedParentID
    }

    /// The name Codex shows: a user/agent rename wins over the generated title.
    public var displayedTitle: String {
        if let name, !name.isEmpty { return name }
        return title
    }
}

public enum VoiceChatResolution: Equatable {
    /// The sidebar marked no row as the live Voice chat.
    case noActiveRow
    /// Different windows marked differently named rows; refuse rather than pick one.
    case conflictingRows([String])
    /// No live, top-level chat has the marked row's name.
    case noMatchingThread(title: String)
    /// Several chats share that name, so the name alone cannot identify the call.
    case ambiguous(title: String, count: Int)
    case thread(id: String, title: String)
}

public enum VoiceChatResolver {
    /// Picks the thread ID for the row Codex marks as the live Voice call.
    ///
    /// Identity comes only from Codex's own live marker. Any doubt is a refusal: an
    /// exact name shared by two chats, rows that disagree between windows, or no match.
    /// It never falls back to recency, the frontmost chat or an older Voice title.
    /// (Measured 2026-11-11: 88 of 98 sidebar rows had one unique match; 3 were genuine
    /// duplicate names; 7 were non-chat rows such as "New chat".)
    public static func resolve(activeRowTitles: [String], threads: [CodexThreadRecord]) -> VoiceChatResolution {
        let titles = orderedUnique(activeRowTitles.map(normalized).filter { !$0.isEmpty })
        guard let title = titles.first else { return .noActiveRow }
        guard titles.count == 1 else { return .conflictingRows(titles) }
        let matches = threads.filter {
            !$0.archived && $0.attachedParentID == nil && normalized($0.displayedTitle) == title
        }
        switch matches.count {
        case 0: return .noMatchingThread(title: title)
        case 1: return .thread(id: matches[0].id, title: title)
        default: return .ambiguous(title: title, count: matches.count)
        }
    }

    /// Codex collapses a title's whitespace when it draws a row (a raw first message can
    /// contain newlines), so compare with runs of whitespace collapsed and ends trimmed.
    public static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

// MARK: - Deep link

public enum CodexThreadLink {
    /// Codex's supported `codex://threads/<uuid>` route (its own notification links use
    /// it). Returns nil for anything that is not a plain UUID, so a corrupt database
    /// value can never become some other `codex://` command.
    public static func url(forThreadID id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return URL(string: "codex://threads/\(id.lowercased())")
    }
}

// MARK: - Placement

public enum VoiceJumpPlacement {
    /// Gap between Codex's pill and the companion button.
    public static let gap: CGFloat = 8

    /// Whether a non-standard Codex window is big enough to be the Voice overlay, which
    /// was observed covering its whole display. Loose on purpose: at least half of some
    /// display's width and height, so a window sized to the visible frame (no menu bar or
    /// Dock) still counts, while Computer Use panels and menus (a few hundred points) do
    /// not and are never walked.
    public static func isOverlaySized(_ size: CGSize, screenSizes: [CGSize]) -> Bool {
        screenSizes.contains { size.width >= $0.width / 2 && size.height >= $0.height / 2 }
    }

    /// The companion button's Cocoa frame: just right of the pill, vertically centred on
    /// it. It moves to the pill's left when the right side would leave the pill's screen,
    /// and is clamped inside that screen so it is always reachable.
    ///
    /// - Parameters:
    ///   - pill: the pill's controls in AX/CG (top-left origin) global points.
    ///   - screens: every screen's full Cocoa frame (the pill may sit over the Dock area).
    public static func frame(pill: CGRect, size: CGSize, screens: [CGRect], primaryScreenHeight: CGFloat) -> CGRect? {
        let pillCocoa = CoordinateConversion.cocoaRect(fromCGBounds: pill, primaryScreenHeight: primaryScreenHeight)
        // The app target's `CGRect.area` extension is not visible from Core, hence the local helper.
        func overlap(_ screen: CGRect) -> CGFloat {
            let shared = screen.intersection(pillCocoa)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        guard let screen = screens.max(by: { overlap($0) < overlap($1) }), overlap(screen) > 0 else { return nil }
        let y = pillCocoa.midY - size.height / 2
        var x = pillCocoa.maxX + gap
        if x + size.width > screen.maxX { x = pillCocoa.minX - gap - size.width }
        var frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - size.width)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - size.height)
        return frame.integral
    }
}

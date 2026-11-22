import CoreGraphics

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

/// Finds the live Voice pill in Codex's overlay. — GPT-6.2 Sol
public struct VoiceChatLocator<Node> {
    /// Codex's English accessible label for the live overlay's Stop control. — GPT-6.2 Sol
    public static var stopVoiceLabels: Set<String> { ["Stop voice chat"] }

    private let children: (Node) -> [Node]
    private let parent: (Node) -> Node?
    private let role: (Node) -> String
    private let subrole: (Node) -> String
    private let label: (Node) -> String
    private let frame: (Node) -> CGRect?

    public init(children: @escaping (Node) -> [Node], parent: @escaping (Node) -> Node?,
                role: @escaping (Node) -> String, subrole: @escaping (Node) -> String,
                label: @escaping (Node) -> String,
                frame: @escaping (Node) -> CGRect? = { _ in nil }) {
        self.children = children
        self.parent = parent
        self.role = role
        self.subrole = subrole
        self.label = label
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

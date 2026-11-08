import CoreGraphics

/// Where the bar goes relative to the Codex window.
///
/// All rectangles here are in **Cocoa screen coordinates** (origin at the bottom-left
/// of the primary display, y grows upwards), the same space `NSWindow.setFrame` uses.
/// `CoordinateConversion` turns CoreGraphics window bounds into this space first.
public enum BarPlacement {
    /// Put notices on the right; at the screen edge use free space above or below, never over controls.
    public static func status(beside toolbar: CGRect, visibleFrame: CGRect, contentSize: CGSize,
                              obstructingWindows: [CGRect] = []) -> CGRect {
        let width = min(contentSize.width, 320, visibleFrame.width)
        let height = min(contentSize.height, visibleFrame.height)
        let rightSpace = visibleFrame.maxX - toolbar.maxX - 6
        if rightSpace >= min(width, 100) {
            let right = CGRect(x: toolbar.maxX + 6,
                               y: min(max(toolbar.midY - height / 2, visibleFrame.minY), visibleFrame.maxY - height),
                               width: min(width, rightSpace), height: height)
            if !obstructingWindows.contains(where: { $0.intersects(right) }) { return right }
        }
        let x = min(max(toolbar.maxX - width, visibleFrame.minX), visibleFrame.maxX - width)
        let y = toolbar.maxY + 6 + height <= visibleFrame.maxY
            ? toolbar.maxY + 6 : toolbar.minY - 6 - height // A toolbar beside Flow can meet the screen's right edge; keep its notice on screen without shifting or covering the bar.
        let vertical = CGRect(x: x, y: y, width: width, height: height)
        if visibleFrame.contains(vertical), !obstructingWindows.contains(where: { $0.intersects(vertical) }) { return vertical }
        return place(window: toolbar, visibleFrame: visibleFrame, contentSize: CGSize(width: width, height: height),
                     obstructingWindows: obstructingWindows) // A notice beside a wrapped bar can spill back into Codex; use the same clear-space rule as its controls.
    }

    /// Keep the bar near Codex's bottom edge, shifting beside Flow before using distant space above Codex.
    /// `visibleFrame` belongs to the anchor's display and excludes its Dock/menu bar.
    /// Measure wrapped controls for each clear region when the caller supplies a width-aware measurement.
    public static func place(window: CGRect, visibleFrame: CGRect, contentSize: CGSize,
                             agentFlowHUD: CGRect? = nil, obstructingWindows: [CGRect] = [],
                             contentSizeForWidth: ((CGFloat) -> CGSize)? = nil) -> CGRect {
        let normal = normalFrame(window: window, visibleFrame: visibleFrame, contentSize: contentSize)
        let flowWindows = obstructingWindows + (agentFlowHUD.map { [$0] } ?? [])
        let obstacles = [window] + flowWindows.map { $0.insetBy(dx: -4, dy: -4) }
        if normal.maxY <= window.minY, visibleFrame.contains(normal),
           !([window] + flowWindows).contains(where: { $0.intersects(normal) }) { return normal } // A shrinking HUD can clear the bar while its four-point margin still overlaps; return straight beneath Codex rather than detouring left. The margin only spaces an actually obstructed placement (Ethan, task 01a0d315-7d5e-7be0-bc08-80626ca0729b, 2026-11-05).
        var regions = [visibleFrame]
        for obstacle in obstacles { // Bound by both windows: right-of-Flow alone can cover Codex; do not restore that anchor-only rule (Ethan, task 01a0d315-7d5e-7be0-bc08-80626ca0729b, 2026-11-01).
            regions = regions.flatMap { region -> [CGRect] in
                let cut = region.intersection(obstacle)
                guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [region] }
                return [CGRect(x: region.minX, y: region.minY, width: cut.minX - region.minX, height: region.height),
                        CGRect(x: cut.maxX, y: region.minY, width: region.maxX - cut.maxX, height: region.height),
                        CGRect(x: region.minX, y: region.minY, width: region.width, height: cut.minY - region.minY),
                        CGRect(x: region.minX, y: cut.maxY, width: region.width, height: region.maxY - cut.maxY)]
                    .filter { $0.width > 0 && $0.height > 0 }
            }
            regions = regions.enumerated().filter { index, region in
                !regions.enumerated().contains { otherIndex, other in
                    otherIndex != index && other.contains(region) && (other != region || otherIndex < index)
                }
            }.map(\.element)
        }
        let preferred = CGRect(x: agentFlowHUD.map { $0.maxX + 4 } ?? normal.minX,
                               y: window.minY - normal.height, width: normal.width, height: normal.height)
        var best: CGRect?
        var bestBottomDistance = CGFloat.infinity
        var bestDistance = CGFloat.infinity
        for region in regions {
            let measured = contentSizeForWidth?(region.width) ?? normal.size
            guard measured.width <= region.width, measured.height <= region.height else { continue }
            let candidate = CGRect(x: min(max(preferred.minX, region.minX), region.maxX - measured.width),
                                   y: min(max(window.minY - measured.height, region.minY), region.maxY - measured.height), // Align the wrapped bar's top to Codex's bottom, not the unwrapped row's centre.
                                   width: measured.width, height: measured.height)
            let dx = candidate.midX - preferred.midX, dy = candidate.midY - preferred.midY
            let distance = dx * dx + dy * dy
            let bottomDistance = max(window.minY - candidate.maxY, candidate.minY - window.minY, 0)
            let improves = best.map {
                bottomDistance < bestBottomDistance || (bottomDistance == bestBottomDistance &&
                    (candidate.height < $0.height || (candidate.height == $0.height && distance < bestDistance)))
            } ?? true
            if improves { // Keep controls close and below Codex where possible; a nearby wrapped bar beats a distant top row. Prefer fewer rows among equally close slots, then Flow's right side (Ethan, task 01a0d315-7d5e-7be0-bc08-80626ca0729b, 2026-11-02).
                best = candidate
                bestBottomDistance = bottomDistance
                bestDistance = distance
            }
        }
        return best ?? normal // A screen filled by Codex has no outside slot; retain its existing top-edge last resort instead of hiding all controls.
    }

    /// True when windows in front leave less than half of `window` visible, so its bar hides rather than floating over them.
    public static func isMostlyCovered(_ window: CGRect, by windowsInFront: [CGRect]) -> Bool {
        var visible = [window]
        for front in windowsInFront {
            visible = visible.flatMap { piece -> [CGRect] in
                let cut = piece.intersection(front)
                guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [piece] }
                return [CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY),
                        CGRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY),
                        CGRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height),
                        CGRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height)]
                    .filter { $0.width > 0 && $0.height > 0 } // Disjoint pieces, unlike `place`'s overlapping regions, so two front windows that overlap each other are not counted twice.
            }
        }
        return visible.reduce(0) { $0 + $1.width * $1.height } < window.width * window.height / 2
    }

    /// Extraction of the existing Codex strip calculation from `place`, including its no-space top-edge fallback; clear-region selection above is new.
    private static func normalFrame(window: CGRect, visibleFrame: CGRect, contentSize: CGSize) -> CGRect {
        let width = min(contentSize.width, visibleFrame.width)
        let height = min(contentSize.height, visibleFrame.height)
        let x = min(max(window.midX - width / 2, visibleFrame.minX), visibleFrame.maxX - width)
        if window.minY - height >= visibleFrame.minY - 0.5 {
            return CGRect(x: x, y: window.minY - height, width: width, height: height)
        }
        if window.maxY + height <= visibleFrame.maxY + 0.5 {
            return CGRect(x: x, y: window.maxY, width: width, height: height)
        }
        return CGRect(x: x, y: max(visibleFrame.minY, min(window.maxY, visibleFrame.maxY) - height - 6),
                      width: width, height: height)
    }
}

/// Converts between CoreGraphics global window bounds (origin top-left of the
/// primary display, y down — what `CGWindowListCopyWindowInfo` reports) and Cocoa
/// screen coordinates (origin bottom-left of the primary display, y up).
public enum CoordinateConversion {
    /// - Parameter primaryScreenHeight: height of `NSScreen.screens[0]` (the display
    ///   with the menu bar), which anchors both coordinate systems.
    public static func cocoaRect(fromCGBounds bounds: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: bounds.minX,
            y: primaryScreenHeight - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
    }
}

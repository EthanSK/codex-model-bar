import CoreGraphics

/// Where the bar goes relative to the Codex window.
///
/// All rectangles here are in **Cocoa screen coordinates** (origin at the bottom-left
/// of the primary display, y grows upwards), the same space `NSWindow.setFrame` uses.
/// `CoordinateConversion` turns CoreGraphics window bounds into this space first.
public enum BarPlacement {
    /// Which slot was chosen; the view uses it to round the right corners.
    public enum Slot: Equatable, Sendable {
        /// Centred directly under the window, sized to the visible controls.
        case below
        /// Directly above the window (only when there is no room underneath).
        case above
        /// A compact pill inside the top edge (maximised window with no room outside).
        case insideTop
    }

    public struct Result: Equatable, Sendable {
        public var frame: CGRect
        public var slot: Slot
    }

    /// Computes the bar frame.
    ///
    /// - Parameters:
    ///   - window: the Codex window frame (Cocoa coordinates).
    ///   - visibleFrame: the `visibleFrame` of the screen holding the window, which
    ///     already excludes the menu bar and the Dock.
    ///   - height: bar height in points.
    ///   - contentWidth: width needed by the visible controls and padding.
    public static func place(
        window: CGRect,
        visibleFrame: CGRect,
        height: CGFloat,
        contentWidth: CGFloat
    ) -> Result {
        let width = min(contentWidth, window.width, visibleFrame.width)
        let x = min(max(window.midX - width / 2, visibleFrame.minX), visibleFrame.maxX - width)

        // 1) Preferred: centred under the window's bottom edge. A half-point
        //    tolerance absorbs rounding between CG and Cocoa rects.
        let below = CGRect(x: x, y: window.minY - height, width: width, height: height)
        if below.minY >= visibleFrame.minY - 0.5 {
            return Result(frame: below, slot: .below)
        }
        // 2) No room below (window touches the Dock/screen bottom): attach on top.
        let above = CGRect(x: x, y: window.maxY, width: width, height: height)
        if above.maxY <= visibleFrame.maxY + 0.5 {
            return Result(frame: above, slot: .above)
        }
        // 3) Window fills the screen: float a compact pill just inside the top edge,
        //    centred, so it covers as little of Codex as possible. The 6pt inset
        //    keeps it clear of the window's rounded corner/shadow.
        let inside = CGRect(
            x: x,
            y: window.maxY - height - 6,
            width: width,
            height: height
        )
        return Result(frame: inside, slot: .insideTop)
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

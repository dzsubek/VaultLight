import CoreGraphics

/// Where the panel appears (spec 4.2). Pure geometry in AppKit coordinates (origin bottom-left); no AppKit.
public enum PanelPlacement {
    /// The panel's frame on the screen that contains the mouse (the first screen when none does): centered
    /// horizontally, its TOP edge a sixth of the screen height below the top (so the search field sits in the
    /// upper third and does not move when the list grows; the panel grows downward), and clamped to stay inside
    /// the visible frame. Returns an origin rect when there are no screens. `screens` are the screens' visible
    /// frames.
    public static func frame(panelSize: CGSize, screens: [CGRect], mouse: CGPoint) -> CGRect {
        guard let screen = screens.first(where: { $0.contains(mouse) }) ?? screens.first else {
            return CGRect(origin: .zero, size: panelSize)
        }
        let topEdge = screen.maxY - screen.height / 6
        let originX = clamp(screen.midX - panelSize.width / 2, low: screen.minX, high: screen.maxX - panelSize.width)
        let originY = clamp(
            topEdge - panelSize.height, low: screen.minY, high: screen.maxY - panelSize.height)
        return CGRect(x: originX.rounded(), y: originY.rounded(), width: panelSize.width, height: panelSize.height)
    }

    /// Clamps into `low...high`; a panel bigger than the screen sticks to the low edge.
    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        max(low, min(value, high))
    }
}

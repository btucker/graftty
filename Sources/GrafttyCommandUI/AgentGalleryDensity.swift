import CoreGraphics

/// @spec IOS-13.32
/// While the phone gallery is open, the application shall fill the screen with tiles two by two or two stacked, move between those two sizes when the user pinches, go no further in either direction, and remember the size it was left at.
public enum AgentGalleryDensity: Int, Sendable, CaseIterable {
    /// Two tiles stacked, each the full width.
    case two = 2
    /// Two by two.
    case four = 4

    public var columns: Int { self == .four ? 2 : 1 }

    /// Spreading the fingers enlarges the tiles; pinching shrinks them.
    public func after(pinchScale: CGFloat) -> AgentGalleryDensity {
        if pinchScale > 1.25 { return .two }
        if pinchScale < 0.8 { return .four }
        return self
    }

    /// Two rows always fill the height; only the column count changes.
    public func tileSize(in size: CGSize, spacing: CGFloat) -> CGSize {
        let columns = CGFloat(columns)
        return CGSize(width: (size.width - spacing * (columns - 1)) / columns, height: (size.height - spacing) / 2)
    }
}

/// @spec IOS-13.33
/// While the phone gallery shows more agents than it can keep live, the application shall show live terminals only for visible tiles up to its limit, in tile order, and show the rest by caption and status alone.
public enum AgentGalleryPreviewBudget {
    public static func live(sessions: [String], visible: Set<String>, limit: Int = 4) -> [String] {
        Array(sessions.filter(visible.contains).prefix(max(0, limit)))
    }
}

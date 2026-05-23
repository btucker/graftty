#if canImport(UIKit)
import CoreGraphics

/// Pure decision: given the iOS container's width, the server-announced
/// grid width (may be nil before the first `grid` control frame), the
/// configured (iOS-scaled) font size from `GhosttyConfigFetcher`, and
/// whether the iOS client has claimed size-leadership, should the
/// terminal pane render at the configured font or under a font-size
/// override sized so `serverCols × cellWidth ≤ containerWidth`?
///
/// Delegates the cell-width math to `PanePreviewFontSizing` so previews
/// and the fullscreen not-leader path stay in lockstep.
public enum TerminalWidthLayout {
    public enum Decision: Equatable {
        /// Use the base iOS-scaled config font. Caller treats this as
        /// "ensure the override (if any) is removed" while not-leader,
        /// or "leave whatever is applied alone" once leader.
        case useConfigFont
        /// Apply this font size as an override on the terminal
        /// controller so that `serverCols × cellWidth ≤ containerWidth`.
        case fitFont(pointSize: Float)
    }

    public static func decide(
        containerWidth: CGFloat,
        serverCols: UInt16?,
        configFontSize: Float,
        isLeader: Bool
    ) -> Decision {
        if isLeader { return .useConfigFont }
        guard let serverCols, serverCols > 0, containerWidth > 0 else {
            return .useConfigFont
        }
        let fitFontSize = PanePreviewFontSizing.fontSize(
            tileWidth: Double(containerWidth),
            serverCols: serverCols
        )
        // Only override when the fit is *smaller* than the configured
        // font — otherwise the base config already renders without
        // wrapping at this container width.
        guard fitFontSize < configFontSize else { return .useConfigFont }
        return .fitFont(pointSize: fitFontSize)
    }
}
#endif

#if canImport(UIKit)
import CoreGraphics

/// Pure decision: given the iOS container's width, the server-announced
/// grid width (may be nil before the first `grid` control frame), the
/// configured (iOS-scaled) font size from `GhosttyConfigFetcher`, and
/// whether the iOS client has claimed size-leadership, should the
/// terminal pane render at the configured font or under a font-size
/// override sized so `serverCols × cellWidth ≤ containerWidth`?
///
/// Mirrors the math in `PanePreviewFontSizing` so previews and the
/// fullscreen not-leader path use the same fit logic.
public enum TerminalWidthLayout {
    static let monospaceAspect: CGFloat = 0.6
    static let safetyScale: CGFloat = 0.95
    static let minimumFontSize: Float = 2

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
        let targetCellWidth = (containerWidth / CGFloat(serverCols)) * safetyScale
        let targetFontSize = Float(targetCellWidth / monospaceAspect)
        if targetFontSize >= configFontSize {
            return .useConfigFont
        }
        return .fitFont(pointSize: max(minimumFontSize, targetFontSize))
    }
}
#endif

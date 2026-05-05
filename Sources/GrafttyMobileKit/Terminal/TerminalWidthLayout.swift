#if canImport(UIKit)
import CoreGraphics

/// Pure decision: given the iOS container's width, the server-announced
/// grid width (may be nil before the first `grid` control frame), and
/// the current cell width in points, should the terminal pane render at
/// container width, or be wrapped in a horizontal ScrollView sized to
/// the server's full grid?
///
/// The `frameWidth` returned by `.scrollable` MUST equal
/// `serverCols * cellWidth` — that's the invariant libghostty relies on.
/// Its VT parser computes its own internal column count as
/// `frame.width / realCellWidth`, so feeding it a frame sized with the
/// real cell width lets it run at exactly `serverCols` and the server's
/// output flows through without internal line-wrapping.
public enum TerminalWidthLayout {
    /// Fallback cell width for the one-frame gap before libghostty's
    /// first resize callback lands. Chosen to overshoot realistic cell
    /// widths for iOS-scale fonts — a too-wide frame just scrolls a few
    /// empty cells, a too-narrow one makes the VT parser wrap.
    public static let fallbackCellWidth: CGFloat = 7.0

    public enum Decision: Equatable {
        /// No horizontal scroll — pane takes the container width.
        case fits
        /// Wrap in a horizontal ScrollView with the pane pinned to this width.
        case scrollable(frameWidth: CGFloat)
    }

    public static func decide(
        containerWidth: CGFloat,
        serverCols: UInt16?,
        cellWidth: CGFloat
    ) -> Decision {
        guard let serverCols, serverCols > 0, cellWidth > 0 else {
            return .fits
        }
        let visibleCols = containerWidth / cellWidth
        let server = CGFloat(serverCols)
        // +0.5 tolerance: don't flip into scroll mode for sub-pixel mismatches
        // between estimated visibleCols and libghostty's rounding.
        guard server > visibleCols + 0.5 else { return .fits }
        return .scrollable(frameWidth: server * cellWidth)
    }
}
#endif

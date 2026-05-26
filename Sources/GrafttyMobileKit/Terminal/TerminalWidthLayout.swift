#if canImport(UIKit)
import CoreGraphics

/// Pure decision: given the iOS container's width, the server-announced
/// grid width, the configured (iOS-scaled) font size, and (optionally) a
/// real font-aspect measurement from libghostty's resize callback,
/// should the terminal pane render at the configured font or under a
/// font-size override sized so `serverCols × cellWidth ≤ containerWidth`?
///
/// The aspect-ratio assumption matters: if it's wrong, libghostty's VT
/// parser may wrap lines internally. When `measuredCellWidthPoints` and
/// `measuredAtFontSize` are provided (both > 0), the decision uses
/// `aspect = measuredCellWidthPoints / measuredAtFontSize`. Otherwise it
/// falls back to `PanePreviewFontSizing.monospaceAspect` (0.6), which
/// matches the project's default fonts but undersizes for fonts whose
/// actual aspect exceeds ~0.632.
public enum TerminalWidthLayout {
    static let fallbackAspect: CGFloat = CGFloat(PanePreviewFontSizing.monospaceAspect)
    static let safetyScale: CGFloat = CGFloat(PanePreviewFontSizing.safetyScale)
    static let minimumFontSize: Float = PanePreviewFontSizing.minimumFontSize

    public enum Decision: Equatable {
        case useConfigFont
        case fitFont(pointSize: Float)
    }

    public static func decide(
        containerWidth: CGFloat,
        serverCols: UInt16?,
        configFontSize: Float,
        measuredCellWidthPoints: CGFloat?,
        measuredAtFontSize: Float?,
        isLeader: Bool
    ) -> Decision {
        if isLeader { return .useConfigFont }
        guard let serverCols, serverCols > 0, containerWidth > 0 else {
            return .useConfigFont
        }

        let aspect: CGFloat
        if let measuredCellWidthPoints,
           let measuredAtFontSize,
           measuredCellWidthPoints > 0,
           measuredAtFontSize > 0 {
            aspect = measuredCellWidthPoints / CGFloat(measuredAtFontSize)
        } else {
            aspect = Self.fallbackAspect
        }

        let targetCellWidth = (containerWidth / CGFloat(serverCols)) * Self.safetyScale
        let targetFontSize = Float(targetCellWidth / aspect)
        if targetFontSize >= configFontSize {
            return .useConfigFont
        }
        return .fitFont(pointSize: max(Self.minimumFontSize, targetFontSize))
    }
}
#endif

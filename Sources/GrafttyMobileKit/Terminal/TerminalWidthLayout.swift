#if canImport(UIKit)
import CoreGraphics

/// Pure decision: given the iOS container's width, the authoritative
/// grid width, the configured (iOS-scaled) font size, and (optionally) a
/// real font-aspect measurement from libghostty's resize callback,
/// should the terminal pane render at the configured font or under a
/// font-size override sized so `authoritativeCols × cellWidth ≤ containerWidth`?
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

    /// What to do with the currently-applied auto-fit override given a
    /// fresh `Decision`. Splitting this from `decide` keeps the promotion
    /// behavior (IOS-6.10: restore the base config font when an owner
    /// still carries a follower-fit override) a pure, testable rule.
    public enum OverrideAction: Equatable {
        /// Leave the currently-applied font (override or base) untouched.
        case keep
        /// Clear the auto-fit override; reinstall the base config font.
        case restoreConfigFont
        /// Install (or replace with) a fit override at this point size.
        case applyOverride(pointSize: Float)
    }

    /// Epsilon dedupe for recomputed fit sizes: `fitFont` point sizes come
    /// from a Double/Float chain that's sensitive to sub-pixel
    /// containerWidth drift; 0.05pt is well below any visible difference
    /// and prevents a thrash of `updateConfigSource` calls.
    static let overrideEpsilon: Float = 0.05

    public static func overrideAction(
        decision: Decision,
        liveFontOverride: Float?
    ) -> OverrideAction {
        switch decision {
        case .useConfigFont:
            return liveFontOverride == nil ? .keep : .restoreConfigFont
        case let .fitFont(pointSize):
            if let live = liveFontOverride, abs(live - pointSize) < Self.overrideEpsilon {
                return .keep
            }
            return .applyOverride(pointSize: pointSize)
        }
    }

    public static func decide(
        containerWidth: CGFloat,
        authoritativeCols: UInt16?,
        configFontSize: Float,
        measuredCellWidthPoints: CGFloat?,
        measuredAtFontSize: Float?,
        isOwner: Bool
    ) -> Decision {
        if isOwner { return .useConfigFont }
        guard let authoritativeCols, authoritativeCols > 0, containerWidth > 0 else {
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

        let targetCellWidth = (containerWidth / CGFloat(authoritativeCols)) * Self.safetyScale
        let targetFontSize = Float(targetCellWidth / aspect)
        if targetFontSize >= configFontSize {
            return .useConfigFont
        }
        return .fitFont(pointSize: max(Self.minimumFontSize, targetFontSize))
    }
}
#endif

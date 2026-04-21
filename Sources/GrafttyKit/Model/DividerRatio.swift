import CoreGraphics

/// Pure helper for the draggable-divider ratio math used by
/// `SplitContainerView`. Lives in GrafttyKit (not the SwiftUI layer) so
/// tests can cover the clamping and division behavior without spinning up
/// a view hierarchy.
///
/// The `position` passed in MUST be measured in the *container's*
/// coordinate space — i.e., the mouse x (or y) relative to the origin of
/// the split container, not relative to the divider subview. Passing a
/// divider-local value instead produces ratios that snap to `minRatio`
/// because the divider is only a few points wide, which is the bug this
/// helper was introduced to prevent recurring.
public enum DividerRatio {
    public static func ratio(
        position: CGFloat,
        total: CGFloat,
        minRatio: Double,
        maxRatio: Double
    ) -> Double {
        guard total > 0 else { return minRatio }
        let raw = Double(position / total)
        return min(maxRatio, max(minRatio, raw))
    }
}

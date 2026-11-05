/// @spec LAYOUT-2.199
/// Picks a worktree drawing's OKLCH hue. OKLCH hue spacing matches what the
/// eye sees, so evenly spaced hues stay distinguishable at icon size.
public enum WorktreeColorAssignment {
    /// A first worktree avoids the blue most project icons already use.
    static let firstHue: Double = 25

    /// The candidate farthest from every taken hue; ties go to the lowest hue.
    public static func hue(avoiding taken: [Double]) -> Double {
        guard !taken.isEmpty else { return firstHue }
        var best = (hue: 0.0, gap: -1.0)
        for candidate in stride(from: 0.0, to: 360, by: 5) {
            let gap = taken.map { hueDistance(candidate, $0) }.min() ?? 0
            if gap > best.gap { best = (candidate, gap) }
        }
        return best.hue
    }

    public static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }
}

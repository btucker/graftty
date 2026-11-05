import Foundation

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

/// The dominant hue of each project's icon, recorded by whichever host
/// decoded that icon. Drawing colors avoid it so a worktree stands apart
/// from the project icon shown on the row above it.
public final class ProjectHueRegistry: @unchecked Sendable {
    public static let shared = ProjectHueRegistry()
    private let lock = NSLock()
    private var hues: [UUID: Double] = [:]

    public func set(_ hue: Double?, for repositoryID: UUID) {
        lock.lock(); defer { lock.unlock() }
        hues[repositoryID] = hue
    }

    public func hue(for repositoryID: UUID) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return hues[repositoryID]
    }
}

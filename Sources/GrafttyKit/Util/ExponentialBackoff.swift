import Foundation

public enum ExponentialBackoff {
    /// Scales `base` by `2^min(streak, maxShift)`, capped at `cap`. Returns
    /// `base` unchanged when `streak == 0`. `floor` replaces `base` when the
    /// latter is `.zero` — useful when the "unknown state" cadence is zero
    /// (i.e. fetch immediately) but a failing fetch still needs a real
    /// interval to multiply.
    public static func scale(
        base: Duration,
        streak: Int,
        cap: Duration,
        floor: Duration = .zero,
        maxShift: Int = 5
    ) -> Duration {
        if streak == 0 { return base }
        let start = base == .zero ? floor : base
        let multiplier = 1 << min(streak, maxShift)
        let scaled = start * Int(multiplier)
        return scaled > cap ? cap : scaled
    }
}

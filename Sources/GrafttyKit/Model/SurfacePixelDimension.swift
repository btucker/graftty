import CoreGraphics

/// Converts a backing-pixel dimension (CGFloat from `NSView.convertToBacking(_:)`)
/// to the `UInt32` that `ghostty_surface_set_size` expects, safely.
///
/// Why a dedicated helper: the naive form `UInt32(max(1, Int(dim)))`
/// traps on `NaN` and on values outside `Int` range. AppKit almost
/// never produces those — but SwiftUI `GeometryReader` edge cases have
/// been observed to emit `.infinity` transiently, and a single trap
/// kills every open pane (the pane's layout pass runs on the main
/// thread; the crash takes out the whole process including Andy's
/// 4-agent fanout). Cheap defense.
///
/// Rules:
/// - `NaN` → 1 (min valid cell dim).
/// - ±infinity or value > `UInt32.max` → `UInt32.max`.
/// - value < 1 (including 0, negatives) → 1.
/// - otherwise → `UInt32(dim)`.
public enum SurfacePixelDimension {
    public struct Size: Equatable {
        public let width: UInt32
        public let height: UInt32

        public init(width: UInt32, height: UInt32) {
            self.width = width
            self.height = height
        }
    }

    public static func clamp(_ dim: CGFloat) -> UInt32 {
        guard !dim.isNaN else { return 1 }
        if dim <= 1 { return 1 }
        if dim >= CGFloat(UInt32.max) { return UInt32.max }
        return UInt32(dim)
    }

    /// Returns the backing-pixel resize worth forwarding to libghostty.
    ///
    /// SwiftUI/AppKit can transiently collapse an `NSView` to zero or a
    /// sub-pixel size while it is being removed/rebound. Forwarding that
    /// as `1xN`/`Nx1` leaves hidden terminals processing later output at
    /// a one-cell grid, so treat collapsed proposals as layout noise.
    public static func resizeProposal(
        width: CGFloat,
        height: CGFloat
    ) -> Size? {
        let proposed = Size(width: clamp(width), height: clamp(height))
        if proposed.width <= 1 || proposed.height <= 1 {
            return nil
        }
        return proposed
    }
}

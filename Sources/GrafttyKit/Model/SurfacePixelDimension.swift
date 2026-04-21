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
    public static func clamp(_ dim: CGFloat) -> UInt32 {
        guard !dim.isNaN else { return 1 }
        if dim <= 1 { return 1 }
        if dim >= CGFloat(UInt32.max) { return UInt32.max }
        return UInt32(dim)
    }
}

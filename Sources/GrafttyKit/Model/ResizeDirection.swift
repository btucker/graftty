import Foundation

/// Direction for `SplitTree.resizing(target:direction:pixels:ancestorBounds:)`.
/// Mirrors Ghostty's `ghostty_action_resize_split_direction_e`:
/// UP / DOWN target vertical ancestors (the divider is horizontal);
/// LEFT / RIGHT target horizontal ancestors (the divider is vertical).
public enum ResizeDirection: Sendable {
    case up, down, left, right

    /// The split-tree orientation whose ancestor this direction resizes.
    public var orientation: SplitDirection {
        switch self {
        case .up, .down:    return .vertical
        case .left, .right: return .horizontal
        }
    }

    /// Sign carried by this direction: +1 grows the right/bottom child,
    /// -1 grows the left/top child. Caller multiplies the pixel amount
    /// by this when computing the ratio delta.
    public var sign: Double {
        switch self {
        case .right, .down: return +1
        case .left, .up:    return -1
        }
    }
}

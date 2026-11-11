import Foundation

/// The Context timeline follows new events only while the reader is at its bottom;
/// otherwise it offers a Jump to latest control.
public struct TimelineFollow: Equatable, Sendable {
    /// Points from the end that still count as the bottom, so rounding and
    /// rubber-banding do not drop the reader out of follow mode.
    public static let bottomTolerance: Double = 24

    public private(set) var isAtBottom = true
    public private(set) var showsJumpToLatest = false

    public init() {}

    /// Points between the end of the visible area and the end of the content; at most zero when the content fits.
    public static func distanceFromBottom(contentHeight: Double, offsetY: Double, visibleHeight: Double) -> Double {
        contentHeight - (offsetY + visibleHeight)
    }

    public mutating func scrolled(distanceFromBottom distance: Double) {
        isAtBottom = distance <= Self.bottomTolerance
        if isAtBottom { showsJumpToLatest = false }
    }

    /// Returns whether the timeline should scroll to the new event.
    public mutating func receivedEvent() -> Bool {
        if isAtBottom { return true }
        showsJumpToLatest = true
        return false
    }

    public mutating func jumpToLatest() {
        scrolled(distanceFromBottom: 0)
    }
}

import Foundation

/// The Context timeline follows new events only while the reader is at its bottom;
/// otherwise it offers a Jump to latest control.
public struct TimelineFollow: Equatable, Sendable {
    /// What the collapsed mobile brief shows in its one-line bar.
    public struct CollapsedSummary: Equatable, Sendable {
        public let title: String
        public let detail: String?
        public let isQuestion: Bool
    }

    /// Points from the end that still count as the bottom, so rounding and
    /// rubber-banding do not drop the reader out of follow mode.
    public static let bottomTolerance: Double = 24

    public let collapsesBrief: Bool
    public private(set) var isAtBottom = true
    public private(set) var showsJumpToLatest = false
    private var briefCollapsed = false
    private var expandsBriefWhileScrolled = false

    public init(collapsesBrief: Bool = false) {
        self.collapsesBrief = collapsesBrief
    }

    /// While true, the pinned brief renders as a one-line bar.
    public var showsCollapsedBrief: Bool {
        collapsesBrief && briefCollapsed
    }

    /// Points between the end of the visible area and the end of the content; at most zero when the content fits.
    public static func distanceFromBottom(contentHeight: Double, offsetY: Double, visibleHeight: Double) -> Double {
        contentHeight - (offsetY + visibleHeight)
    }

    /// Keep the collapse threshold beyond the brief's largest resize, so that
    /// collapsing cannot move the reader to the bottom and immediately expand it.
    public mutating func scrolled(distanceFromBottom distance: Double, panelHeight: Double, briefHeight: Double = 0) {
        isAtBottom = distance <= Self.bottomTolerance
        if isAtBottom {
            showsJumpToLatest = false
            briefCollapsed = false
            expandsBriefWhileScrolled = false
        } else if distance > max(panelHeight / 2, briefHeight) + Self.bottomTolerance, !expandsBriefWhileScrolled {
            briefCollapsed = true
        }
    }

    /// Returns whether the timeline should scroll to the new event.
    public mutating func receivedEvent() -> Bool {
        if isAtBottom { return true }
        showsJumpToLatest = true
        return false
    }

    public mutating func jumpToLatest() {
        scrolled(distanceFromBottom: 0, panelHeight: 0)
    }

    public mutating func expandBrief() {
        briefCollapsed = false
        expandsBriefWhileScrolled = true
    }

    public static func collapsedSummary(title: String, next: String?, question: String?) -> CollapsedSummary {
        if let question { return .init(title: title, detail: question, isQuestion: true) }
        return .init(title: title, detail: next.map { "Next: \($0)" }, isQuestion: false)
    }
}

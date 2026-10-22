import Foundation

/// A current explanation of the work, independent of unread attention.
public struct WorktreeBrief: Codable, Sendable, Hashable {
    public struct Checkpoint: Codable, Sendable, Hashable, Identifiable {
        public let id: UUID
        public var timestamp: Double
        public var title: String
        public var completed: String
        public var decisions: [String]
        /// Absent in saved legacy snapshots. Explicit entries remain visible and are never rewritten by status updates.
        public var isExplicitEntry: Bool?
    }

    public private(set) var title: String
    public private(set) var context: String?
    public private(set) var completed: String
    public private(set) var next: String
    public private(set) var decisions: [String]
    public private(set) var updatedAt: Double
    public private(set) var history: [Checkpoint]

    public init(recap: AttentionRecap, at date: Date) {
        title = recap.title
        context = recap.context
        completed = recap.completed
        next = recap.next
        decisions = recap.decisions ?? []
        updatedAt = date.timeIntervalSinceReferenceDate
        history = []
        recordHistory(recap, at: updatedAt, purposeChanged: recap.purposeChanged == true, boundary: nil)
    }

    public mutating func update(_ recap: AttentionRecap, at date: Date, preservingCheckpointBefore boundary: Date? = nil) {
        let timestamp = date.timeIntervalSinceReferenceDate
        guard timestamp >= updatedAt else { return }
        let newTitle = recap.purposeChanged == true ? recap.title : title
        let newContext = recap.context ?? (recap.purposeChanged == true ? nil : context)
        let newDecisions = recap.decisions ?? (recap.purposeChanged == true ? [] : decisions)
        let purposeChanged = recap.purposeChanged == true && (newTitle != title || newContext != context)
        title = newTitle
        context = newContext
        completed = recap.completed
        next = recap.next
        decisions = newDecisions
        updatedAt = timestamp
        recordHistory(recap, at: timestamp, purposeChanged: purposeChanged, boundary: boundary)
    }

    private mutating func recordHistory(_ recap: AttentionRecap, at timestamp: Double,
                                        purposeChanged: Bool, boundary: Date?) {
        let heading: String
        let detail: String
        let isExplicit: Bool
        if let entry = recap.historyEntry {
            heading = entry.headline
            detail = entry.detail ?? ""
            isExplicit = true
        } else if let checkpoint = recap.checkpoint {
            heading = checkpoint
            detail = recap.completed
            isExplicit = false
        } else if purposeChanged {
            heading = title
            detail = context ?? ""
            isExplicit = true
        } else {
            return
        }
        let last = history.last
        let canMerge = boundary.map { (last?.timestamp ?? -.infinity) > $0.timeIntervalSinceReferenceDate } ?? true
        if !purposeChanged, canMerge, last?.title == heading,
           (last?.isExplicitEntry == true) == isExplicit {
            // Retrying a report or updating only its brief must not move history.
            if last?.completed == detail { return }
            if !isExplicit {
                history[history.count - 1].timestamp = timestamp
                history[history.count - 1].completed = detail
                return
            }
        }
        history.append(Checkpoint(id: UUID(), timestamp: timestamp, title: heading,
                                  completed: detail, decisions: [], isExplicitEntry: isExplicit ? true : nil))
        if history.count > 32 { history.removeFirst(history.count - 32) }
    }
}

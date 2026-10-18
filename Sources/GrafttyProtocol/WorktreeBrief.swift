import Foundation

/// A current explanation of the work, independent of unread attention.
public struct WorktreeBrief: Codable, Sendable, Hashable {
    public struct Checkpoint: Codable, Sendable, Hashable, Identifiable {
        public let id: UUID
        public var timestamp: Double
        public var title: String
        public var completed: String
        public var decisions: [String]
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
        history = [Checkpoint(id: UUID(), timestamp: updatedAt,
            title: recap.checkpoint ?? recap.title, completed: recap.completed, decisions: decisions)]
    }

    public mutating func update(_ recap: AttentionRecap, at date: Date) {
        let timestamp = date.timeIntervalSinceReferenceDate
        guard timestamp >= updatedAt else { return }
        let newTitle = recap.purposeChanged == true ? recap.title : title
        let newContext = recap.context ?? (recap.purposeChanged == true ? nil : context)
        let newDecisions = recap.decisions ?? (recap.purposeChanged == true ? [] : decisions)
        let changed = newTitle != title || newContext != context || recap.completed != completed
            || recap.next != next || newDecisions != decisions
        let purposeChanged = recap.purposeChanged == true
        title = newTitle
        context = newContext
        completed = recap.completed
        next = recap.next
        decisions = newDecisions
        updatedAt = timestamp
        let checkpointChanged = recap.checkpoint.map { $0 != history.last?.title } ?? false
        guard changed || checkpointChanged, recap.checkpoint != nil || purposeChanged else { return }
        let heading = recap.checkpoint ?? title
        if !purposeChanged, history.last?.title == heading {
            history[history.count - 1].timestamp = timestamp
            history[history.count - 1].completed = completed
            history[history.count - 1].decisions = decisions
        } else {
            history.append(Checkpoint(id: UUID(), timestamp: timestamp, title: heading,
                                      completed: completed, decisions: decisions))
            if history.count > 32 { history.removeFirst(history.count - 32) }
        }
    }
}

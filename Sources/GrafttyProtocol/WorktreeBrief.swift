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
    /// Optional for saved briefs from before sparse updates.
    private var groupUpdatedAt: [String: Double]?
    private var historyReceipts: [UUID]?

    public init(recap: AttentionRecap, at date: Date) {
        title = recap.title
        context = recap.context
        completed = recap.completed
        next = recap.next
        decisions = recap.decisions ?? []
        updatedAt = date.timeIntervalSinceReferenceDate
        history = []
        groupUpdatedAt = ["purpose": updatedAt, "now": updatedAt, "decisions": updatedAt, "history": updatedAt]
        recordHistory(recap, at: updatedAt, purposeChanged: recap.contextUpdate == nil && recap.purposeChanged == true,
                      boundary: nil, receiptID: recap.contextUpdate?.receiptID)
    }

    public mutating func update(_ recap: AttentionRecap, at date: Date, preservingCheckpointBefore boundary: Date? = nil) {
        if let update = recap.contextUpdate {
            apply(update, at: date, boundary: boundary)
            return
        }
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
        groupUpdatedAt = ["purpose": timestamp, "now": timestamp, "decisions": timestamp, "history": timestamp]
        recordHistory(recap, at: timestamp, purposeChanged: purposeChanged, boundary: boundary)
    }

    private mutating func apply(_ update: WorktreeContextUpdate, at date: Date, boundary: Date?) {
        guard update.isValid, update.unchanged != true else { return }
        let timestamp = date.timeIntervalSinceReferenceDate
        var times = groupUpdatedAt ?? ["purpose": updatedAt, "now": updatedAt, "decisions": updatedAt, "history": updatedAt]
        var changed = false
        if let purpose = update.purpose, timestamp > (times["purpose"] ?? -.infinity) {
            title = purpose.title; context = purpose.context
            times["purpose"] = timestamp; changed = true
        }
        if let now = update.now, timestamp > (times["now"] ?? -.infinity) {
            completed = now.summary; next = now.next ?? ""
            times["now"] = timestamp; changed = true
        }
        if let values = update.decisions, timestamp > (times["decisions"] ?? -.infinity) {
            decisions = values
            times["decisions"] = timestamp; changed = true
        }
        if let entry = update.historyEntry {
            var event = AttentionRecap(title: title, completed: completed, next: next)
            event.historyEntry = entry
            let previous = history
            recordHistory(event, at: timestamp, purposeChanged: false, boundary: boundary, receiptID: update.receiptID)
            changed = changed || history != previous
        }
        if changed { groupUpdatedAt = times; updatedAt = max(updatedAt, timestamp) }
    }

    /// Complete retained context plus this turn's attention, for every client.
    public func snapshot(attentionFrom recap: AttentionRecap) -> AttentionRecap {
        var result = recap
        result.title = title; result.context = context; result.completed = completed; result.next = next
        result.decisions = decisions.isEmpty && recap.decisions == nil ? nil : decisions
        result.contextUpdate = nil
        return result
    }

    private mutating func recordHistory(_ recap: AttentionRecap, at timestamp: Double,
                                        purposeChanged: Bool, boundary: Date?, receiptID: UUID? = nil) {
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
        if let receiptID {
            guard !(historyReceipts ?? []).contains(receiptID) else { return }
            historyReceipts = Array(((historyReceipts ?? []) + [receiptID]).suffix(128))
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
        history.append(Checkpoint(id: receiptID ?? UUID(), timestamp: timestamp, title: heading,
                                  completed: detail, decisions: [], isExplicitEntry: isExplicit ? true : nil))
        history.sort { $0.timestamp < $1.timestamp }
        if history.count > 32 { history.removeFirst(history.count - 32) }
    }
}

import Foundation

/// Agent-authored changes. Omitted retained groups survive; attention is turn-local.
public struct WorktreeContextUpdate: Codable, Sendable, Hashable {
    public struct Purpose: Codable, Sendable, Hashable {
        public var title: String
        public var context: String
        public init(title: String, context: String) { self.title = title; self.context = context }
    }

    public struct Now: Codable, Sendable, Hashable {
        public var summary: String
        public var next: String?
        public init(summary: String, next: String? = nil) { self.summary = summary; self.next = next }
    }

    public struct Request: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable { case ask, notice }
        public var kind: Kind
        public var question: String?
        public var message: String?
        public var background: String?
        public var options: [AttentionRecap.Option]?

        public init(kind: Kind, question: String? = nil, message: String? = nil,
                    background: String? = nil, options: [AttentionRecap.Option]? = nil) {
            self.kind = kind; self.question = question; self.message = message
            self.background = background; self.options = options
        }
    }

    public var purpose: Purpose?
    public var now: Now?
    public var decisions: [String]?
    public var historyEntry: AttentionRecap.HistoryEntry?
    public var attention: Request?
    public var unchanged: Bool?
    public var emoji: String?
    public var emojiAlternatives: [String]?
    public var icon: String?
    public var iconDescription: String?
    /// Assigned by the CLI, preserved by transport retries, never authored in command input.
    public var receiptID: UUID?

    public init(purpose: Purpose? = nil, now: Now? = nil, decisions: [String]? = nil,
                historyEntry: AttentionRecap.HistoryEntry? = nil, attention: Request? = nil,
                unchanged: Bool? = nil) {
        self.purpose = purpose; self.now = now; self.decisions = decisions
        self.historyEntry = historyEntry; self.attention = attention; self.unchanged = unchanged
        self.receiptID = UUID()
    }

    public var hasChanges: Bool {
        purpose != nil || now != nil || decisions != nil || historyEntry != nil
            || attention != nil || emoji != nil || emojiAlternatives != nil || icon != nil || iconDescription != nil
    }

    public var isValid: Bool {
        if unchanged == true { return !hasChanges }
        guard hasChanges else { return false }
        if let next = now?.next, next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if let request = attention {
            switch request.kind {
            case .ask:
                guard request.question != nil, request.message == nil else { return false }
            case .notice:
                guard let message = request.message, request.question == nil,
                      request.options == nil, request.background == nil,
                      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      message.count <= 300,
                      !message.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
            }
        }
        if iconDescription != nil && icon == nil { return false }
        // Reuse the established text, option, emoji, and drawing size limits.
        var validation = AttentionRecap(title: purpose?.title ?? "Context", context: purpose?.context,
            completed: now?.summary ?? "Context updated.", next: now?.next ?? "None.",
            need: attention?.question, emoji: emoji, emojiAlternatives: emojiAlternatives,
            decisions: decisions, historyEntry: historyEntry)
        validation.catchUp = attention?.background
        validation.options = attention?.options
        validation.icon = icon
        validation.iconDescription = iconDescription
        return validation.isValid
    }
}

public extension AttentionRecap {
    /// The existing handoff transports updates as well as legacy full recaps.
    /// These fallback strings never replace retained groups on the host.
    init(update: WorktreeContextUpdate) {
        self.init(title: update.purpose?.title ?? "Context", context: update.purpose?.context,
                  completed: update.now?.summary ?? "Context updated.", next: update.now?.next ?? "",
                  need: update.attention?.question, emoji: update.emoji, emojiAlternatives: update.emojiAlternatives,
                  purposeChanged: update.purpose == nil ? nil : true, decisions: update.decisions,
                  historyEntry: update.historyEntry)
        contextUpdate = update
        notice = update.attention?.kind == .notice ? update.attention?.message : nil
        catchUp = update.attention?.background
        options = update.attention?.options
        icon = update.icon
        iconDescription = update.iconDescription
    }
}

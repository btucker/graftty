import Foundation

/// A small wire model shared by the iPhone relay and the watch. It deliberately
/// has no dependency on Ghostty, WebRTC, SSH, or host pairing credentials.
public struct WatchAttentionCard: Codable, Sendable, Equatable, Identifiable {
    public struct Option: Codable, Sendable, Equatable {
        public var label: String
        public var cost: String?
        public var suggested: Bool
        public init(label: String, cost: String? = nil, suggested: Bool = false) {
            self.label = label; self.cost = cost; self.suggested = suggested
        }
    }

    public struct Target: Codable, Sendable, Equatable {
        public var paneID: String
        /// The host's exact occurrence, encoded by the phone, never rebuilt by the watch.
        public var occurrence: Data
        public init(paneID: String, occurrence: Data) {
            self.paneID = paneID; self.occurrence = occurrence
        }
    }

    public var hostID: UUID
    public var worktreeID: String
    public var project: String
    public var worktree: String
    public var host: String
    public var title: String
    public var question: String
    public var context: String?
    public var options: [Option]
    public var target: Target?
    public var timestamp: Date?
    public var resourceID: String?
    public var terminal: WatchTerminalTarget?
    public var isNotice: Bool?
    public var id: String { resourceID ?? hostID.uuidString + ":" + worktreeID }
    public var questionID: String { id + ":" + (target?.occurrence.base64EncodedString() ?? "") + ":" + question }

    public init(hostID: UUID, worktreeID: String, project: String, worktree: String, host: String,
                title: String, question: String, context: String?, options: [Option], target: Target?, timestamp: Date?, resourceID: String? = nil) {
        self.hostID = hostID; self.worktreeID = worktreeID; self.project = project
        self.worktree = worktree; self.host = host; self.title = title; self.question = question
        self.context = context; self.options = options; self.target = target; self.timestamp = timestamp
        self.resourceID = resourceID
    }
}

public struct WatchAttentionSnapshot: Codable, Sendable, Equatable {
    public var cards: [WatchAttentionCard]
    public var updatedAt: Date
    public var isEnabled: Bool
    public var unavailableHosts: [String]
    public var omittedCount: Int
    /// Optional for snapshots saved by an earlier phone companion.
    public var terminals: [WatchTerminalTarget]?
    public var omittedTerminalCount: Int?

    public init(cards: [WatchAttentionCard] = [], updatedAt: Date = .distantPast, isEnabled: Bool = true,
                unavailableHosts: [String] = [], omittedCount: Int = 0, terminals: [WatchTerminalTarget] = [], omittedTerminalCount: Int = 0) {
        self.cards = cards; self.updatedAt = updatedAt; self.isEnabled = isEnabled
        self.unavailableHosts = unavailableHosts; self.omittedCount = omittedCount
        self.terminals = terminals; self.omittedTerminalCount = omittedTerminalCount
    }

    /// Leave headroom beneath WatchConnectivity's message/context limit.
    /// Keep the newest cards and explicitly report anything left on the phone.
    public func encodedForTransfer(maximumBytes: Int = 48_000) throws -> Data {
        let encoder = JSONEncoder()
        let full = try encoder.encode(self)
        if full.count <= maximumBytes { return full }

        var copy = self
        copy.cards = []
        copy.omittedCount += cards.count
        if let terminals {
            copy.terminals = []
            copy.omittedTerminalCount = (omittedTerminalCount ?? 0) + terminals.count
        }
        // Start with all omissions counted so their final decimal widths fit.
        // Encoding each item once avoids repeatedly serializing a large inbox.
        let overhead = try encoder.encode(copy).count
        guard overhead <= maximumBytes else { throw CocoaError(.coderInvalidValue) }
        var remaining = maximumBytes - overhead
        func fitting<T: Encodable>(_ items: [T]) throws -> [T] {
            var kept: [T] = []
            for item in items {
                let size = try encoder.encode(item).count + (kept.isEmpty ? 0 : 1)
                if size <= remaining {
                    kept.append(item)
                    remaining -= size
                }
            }
            return kept
        }
        copy.cards = try fitting(cards)
        copy.omittedCount -= copy.cards.count
        if let terminals {
            let kept = try fitting(terminals)
            copy.terminals = kept
            copy.omittedTerminalCount = (omittedTerminalCount ?? 0) + terminals.count - kept.count
        }
        return try encoder.encode(copy)
    }
}

public enum WatchRequest: Codable, Sendable, Equatable {
    public enum TransferError: LocalizedError {
        case tooLarge
        public var errorDescription: String? { "This reply is too long for Apple Watch. Shorten it and try again." }
    }
    public static let maximumBytes = 60_000
    public func encodedForTransfer() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw TransferError.tooLarge }
        return data
    }
    case refresh
    case terminal(WatchTerminalTarget)
    case answer(id: UUID, card: WatchAttentionCard, text: String)
}

public enum WatchResponse: Codable, Sendable, Equatable {
    case snapshot(WatchAttentionSnapshot)
    case terminal(WatchTerminalFrame)
    case answered
    case failure(String)
}

public enum WatchCompanionSettings {
    public static let enabledKey = "watchCompanionEnabled"
    public static let snapshotKey = "watchAttentionSnapshot"
}

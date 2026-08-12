import Foundation

public actor ClaudePeerDeliveryService {
    private struct DeliveryKey: Hashable, Sendable {
        let team: String
        let worktree: String
    }

    private let inbox: TeamInbox
    private let presenceRecords: @Sendable () -> [TeamPresenceRecord]
    private let agentReachability: @Sendable (TeamPresenceRecord) -> Bool
    private let client: any ClaudePeerClienting
    private let eventLog: TeamEventLog?
    private var inFlight: Set<DeliveryKey> = []
    private var dirty: Set<DeliveryKey> = []

    public init(
        inbox: TeamInbox,
        presenceRecords: @escaping @Sendable () -> [TeamPresenceRecord],
        agentReachability: @escaping @Sendable (TeamPresenceRecord) -> Bool,
        client: ClaudePeerClienting = ClaudePeerClient(),
        eventLog: TeamEventLog? = TeamEventLog.defaultLog()
    ) {
        self.inbox = inbox
        self.presenceRecords = presenceRecords
        self.agentReachability = agentReachability
        self.client = client
        self.eventLog = eventLog
    }

    public func onMessageArrival(team: String, worktree: String) async {
        let key = DeliveryKey(team: team, worktree: worktree)
        guard inFlight.insert(key).inserted else {
            dirty.insert(key)
            return
        }
        defer { inFlight.remove(key) }
        repeat {
            dirty.remove(key)
            let advanced = await deliverOnce(team: team, worktree: worktree)
            if !advanced, dirty.remove(key) == nil { break }
        } while true
    }

    @discardableResult
    private func deliverOnce(team: String, worktree: String) async -> Bool {
        let records = presenceRecords().filter {
            $0.teamID == team && $0.worktree == worktree
        }
        // Codex-only worktrees are fanned at this service too; skip the
        // inbox parse and directory build when no Claude peer can exist.
        guard records.contains(where: { record in
            record.runtime == .claude
                && record.transport != nil
                && record.isSubagent != true
        }) else {
            return false
        }
        let directory = TeamAgentDirectory(
            records: records,
            isReachable: agentReachability
        )
        let watermark: String?
        let allUnread: [TeamInboxMessage]
        do {
            watermark = try inbox.worktreeWatermark(
                teamID: team,
                worktree: worktree
            )?.lastDeliveredToAnySessionID
            allUnread = try inbox.unreadMessages(
                teamID: team,
                recipientWorktree: worktree,
                after: watermark
            )
        } catch {
            log(team: team, worktree: worktree, outcome: "error_inbox_read")
            return false
        }
        guard let first = allUnread.first else { return false }

        let selected: TeamAgentDescriptor?
        do {
            let targetRuntime = first.to.runtime.flatMap(TeamHookRuntime.init(rawValue:))
            selected = try directory.resolve(
                worktreePath: worktree,
                runtime: targetRuntime,
                explicitAgentID: first.to.agentID
            )
        } catch {
            log(team: team, worktree: worktree, outcome: "skipped_unreachable")
            return false
        }
        guard let selected, selected.runtime == .claude else { return false }
        guard case .claude(let socketPath, let protocolVersion) = selected.transport,
              protocolVersion == ClaudePeerProtocol.version else {
            log(team: team, worktree: worktree, outcome: "skipped_missing_transport")
            return false
        }
        let pending = TeamInbox.runtimeDeliverablePrefix(
            allUnread,
            runtime: TeamHookRuntime.claude.rawValue,
            agentID: selected.id.rawValue
        )
        guard !pending.isEmpty else { return false }

        // One frame carries one native sender identity, so a frame may only
        // contain the leading run of rows that share a derived name; the
        // arrival loop redelivers, sending later runs in follow-up frames.
        let senderName = ClaudePeerSenderName.name(for: pending[0])
        let run = Array(pending.prefix(while: {
            ClaudePeerSenderName.name(for: $0) == senderName
        }))

        do {
            // A batch that overflows the peer protocol's frame cap would
            // otherwise be retried identically forever, wedging the queue.
            // Halve the batch until it fits; the next pass delivers the rest.
            var batch = run
            while true {
                do {
                    _ = try await client.send(
                        body: batch.map { TeamHookRenderer.content(message: $0) }
                            .joined(separator: "\n\n"),
                        socketPath: socketPath,
                        replySocketPath: nil,
                        senderName: senderName
                    )
                    break
                } catch ClaudePeerMessagingError.messageTooLarge where batch.count > 1 {
                    batch = Array(batch.prefix((batch.count + 1) / 2))
                }
            }
            try inbox.compareAndAdvanceWorktreeWatermark(
                teamID: team,
                worktree: worktree,
                to: batch[batch.count - 1].id
            )
            log(
                team: team,
                worktree: worktree,
                outcome: "sent",
                agentID: selected.id.rawValue,
                messageIDs: batch.map(\.id)
            )
            return true
        } catch {
            log(
                team: team,
                worktree: worktree,
                outcome: "error_delivery",
                agentID: selected.id.rawValue,
                messageIDs: run.map(\.id),
                error: String(describing: error)
            )
            return false
        }
    }

    private func log(
        team: String,
        worktree: String,
        outcome: String,
        agentID: String? = nil,
        messageIDs: [String] = [],
        error: String? = nil
    ) {
        guard let eventLog else { return }
        var detail = [
            "worktree": worktree,
            "runtime": TeamHookRuntime.claude.rawValue,
            "outcome": outcome,
        ]
        if let agentID { detail["agentID"] = agentID }
        if !messageIDs.isEmpty { detail["messageIDs"] = messageIDs.joined(separator: ",") }
        if let error { detail["error"] = error }
        try? eventLog.append(.init(
            teamID: team,
            kind: .nativePeerDeliveryAttempt,
            detail: detail
        ))
    }
}

/// Derives the native cross-session sender label for one inbox row.
/// Agent rows: `<team>/<worktree-member>#<agent-id>`; the suffix minus the
/// team prefix is a routable `graftty team send` address. System rows: the
/// originating SCM's display name when a source was persisted, else the
/// generic team label.
public enum ClaudePeerSenderName {
    public static func name(for message: TeamInboxMessage) -> String {
        guard message.from.member != "system" else {
            guard let source = message.source, !source.isEmpty else {
                return "Graftty team"
            }
            switch source {
            case "github": return "GitHub"
            case "gitlab": return "GitLab"
            default: return source.prefix(1).uppercased() + source.dropFirst()
            }
        }
        let base = "\(message.team)/\(message.from.member)"
        guard let agentID = message.from.agentID else { return base }
        return "\(base)#\(agentID)"
    }
}

public enum TeamPeerMessageFormatter {
    public static func context(messages: [TeamInboxMessage]) -> String {
        messages.map { message in
            let address = escapeAttribute(message.from.canonicalAddress)
            let body = TeamHookRenderer.content(message: message)
                .replacingOccurrences(
                    of: "</graftty-peer-message",
                    with: #"<\/graftty-peer-message"#,
                    options: [.caseInsensitive]
                )
            return """
            <graftty-peer-message agent="\(address)">
            \(body)
            </graftty-peer-message>
            """
        }.joined(separator: "\n\n")
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

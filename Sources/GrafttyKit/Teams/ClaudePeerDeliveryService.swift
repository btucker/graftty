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
        let allUnread: [TeamInboxMessage]
        do {
            allUnread = try inbox.worktreePendingMessages(
                teamID: team,
                recipientWorktree: worktree,
            )
        } catch {
            log(team: team, worktree: worktree, outcome: "error_inbox_read")
            return false
        }
        guard !allUnread.isEmpty else { return false }

        let selected: TeamAgentDescriptor?
        selected = allUnread.lazy.compactMap { message -> TeamAgentDescriptor? in
            do {
                let targetRuntime = message.to.runtime.flatMap(TeamHookRuntime.init(rawValue:))
                let candidate = try directory.resolve(
                    worktreePath: worktree,
                    runtime: targetRuntime,
                    explicitAgentID: message.to.agentID
                )
                return candidate?.runtime == .claude ? candidate : nil
            } catch {
                return nil
            }
        }.first
        guard let selected else {
            log(team: team, worktree: worktree, outcome: "skipped_unreachable")
            return false
        }
        guard case .claude(let socketPath, let protocolVersion) = selected.transport,
              protocolVersion == ClaudePeerProtocol.version else {
            log(team: team, worktree: worktree, outcome: "skipped_missing_transport")
            return false
        }
        let defaultAgent = try? directory.resolve(
            worktreePath: worktree,
            explicitAgentID: nil
        )
        let acceptsUntargeted = defaultAgent?.id == selected.id
        let pending = TeamInbox.runtimeDeliverableMessages(
            allUnread,
            runtime: TeamHookRuntime.claude.rawValue,
            agentID: selected.id.rawValue,
            acceptsUntargeted: acceptsUntargeted
        )
        guard !pending.isEmpty else { return false }

        // One frame carries one native sender identity, so a frame may only
        // contain the leading run of rows that share a derived name; the
        // arrival loop redelivers, sending later runs in follow-up frames.
        let senderName = ClaudePeerSenderName.name(for: pending[0])
        let run = Array(pending.prefix(while: {
            ClaudePeerSenderName.name(for: $0) == senderName
        }))

        // A batch that overflows the peer protocol's frame cap would
        // otherwise be retried identically forever, wedging the queue.
        // Halve the batch until it fits; the next pass delivers the rest.
        var batch = run
        var skippedOversized = false
        do {
            while true {
                do {
                    _ = try await client.send(
                        body: TeamPeerMessageFormatter.context(messages: batch),
                        socketPath: socketPath,
                        replySocketPath: nil,
                        senderName: senderName
                    )
                    break
                } catch ClaudePeerMessagingError.messageTooLarge where batch.count > 1 {
                    batch = Array(batch.prefix((batch.count + 1) / 2))
                }
            }
        } catch ClaudePeerMessagingError.messageTooLarge {
            // A lone row that exceeds the frame cap can never be delivered;
            // skip the watermark past it so the poison row cannot wedge the
            // queue. The row stays in inbox history for manual reading.
            skippedOversized = true
        } catch {
            log(
                team: team,
                worktree: worktree,
                outcome: "error_delivery",
                agentID: selected.id.rawValue,
                messageIDs: batch.map(\.id),
                error: String(describing: error)
            )
            return false
        }

        do {
            try inbox.acknowledgeMessages(
                teamID: team,
                worktree: worktree,
                messageIDs: batch.map(\.id)
            )
        } catch {
            log(
                team: team,
                worktree: worktree,
                outcome: "error_watermark_write",
                agentID: selected.id.rawValue,
                messageIDs: batch.map(\.id),
                error: String(describing: error)
            )
            return false
        }
        log(
            team: team,
            worktree: worktree,
            outcome: skippedOversized ? "skipped_oversized" : "sent",
            agentID: selected.id.rawValue,
            messageIDs: batch.map(\.id)
        )
        return true
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

/// Derives the native cross-session display label for one inbox row.
/// Agent rows resemble `<team>/<worktree-member>#<agent-id>`, but the native
/// protocol may truncate the label, so routing identity lives in the message
/// envelope instead. System rows use the originating SCM's display name when
/// a source was persisted, else the generic team label.
public enum ClaudePeerSenderName {
    public static func name(for message: TeamInboxMessage) -> String {
        guard !message.from.isSystem else {
            guard let source = message.source, !source.isEmpty else {
                return "Graftty team"
            }
            let known = HostingProvider(rawValue: source)
                .flatMap(HostCLIAvailability.metadata(for:))?
                .displayName
            return known ?? source.prefix(1).uppercased() + source.dropFirst()
        }
        let base = "\(message.team)/\(message.from.member)"
        guard let agentID = message.from.agentID else { return base }
        return "\(base)#\(agentID)"
    }
}

public enum TeamPeerMessageFormatter {
    public static func context(messages: [TeamInboxMessage]) -> String {
        messages.map { message in
            let envelope = envelope(for: message)
            let body = neutralizedBody(message: message)
            let urgencySuffix = message.priority == .urgent
                ? #" priority="urgent""#
                : ""
            return """
            <\(envelope.name)\(envelope.attributes)\(urgencySuffix)>
            \(body)
            </\(envelope.name)>
            """
        }.joined(separator: "\n\n")
    }

    private static func envelope(
        for message: TeamInboxMessage
    ) -> (name: String, attributes: String) {
        guard message.from.isSystem else {
            let address = escapeAttribute(message.from.canonicalAddress)
            let fallbackSuffix = message.from.runtime.map { runtime in
                let fallback = escapeAttribute("\(message.from.worktree)#\(runtime)")
                return #" fallback-agent="\#(fallback)""#
            } ?? ""
            return (
                "graftty-peer-message",
                #" agent="\#(address)"\#(fallbackSuffix)"#
            )
        }
        guard let source = message.source, !source.isEmpty else {
            return ("graftty-system-message", "")
        }
        return (
            "graftty-forge-message",
            #" provider="\#(escapeAttribute(source))""#
        )
    }

    private static func neutralizedBody(message: TeamInboxMessage) -> String {
        // Only tags synthesized by this formatter may carry provenance.
        // Treat tag-shaped body text as inert even when a PR title or an
        // agent-authored message tries to open or close a sibling envelope.
        var body = TeamHookRenderer.content(message: message)
        for name in [
            "graftty-peer-message",
            "graftty-forge-message",
            "graftty-system-message",
        ] {
            body = body
                .replacingOccurrences(
                    of: "</\(name)",
                    with: "<\\/\(name)",
                    options: [.caseInsensitive]
                )
                .replacingOccurrences(
                    of: "<\(name)",
                    with: "<\\\(name)",
                    options: [.caseInsensitive]
                )
        }
        return body
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

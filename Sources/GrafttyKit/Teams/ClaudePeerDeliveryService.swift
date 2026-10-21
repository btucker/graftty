import Foundation

public final class ClaudePeerDeliveryService: Sendable {
    private let pipeline: TeamDeliveryPipeline<ClaudePeerTransport>

    public init(
        inbox: TeamInbox,
        presenceRecords: @escaping @Sendable () -> [TeamPresenceRecord],
        agentReachability: @escaping @Sendable (TeamPresenceRecord) -> Bool,
        client: ClaudePeerClienting = ClaudePeerClient(),
        eventLog: TeamEventLog? = TeamEventLog.defaultLog(),
        replyBridge: ClaudePeerReplyBridge? = nil,
        wakeBeforeDelivery: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        let logger = TeamDeliveryEventLogger(
            eventLog: eventLog,
            kind: .nativePeerDeliveryAttempt,
            runtime: .claude
        )
        pipeline = TeamDeliveryPipeline(
            inbox: inbox,
            presenceRecords: presenceRecords,
            isReachable: agentReachability,
            wakeBeforeDelivery: wakeBeforeDelivery,
            logger: logger,
            transport: ClaudePeerTransport(client: client, replyBridge: replyBridge, logger: logger)
        )
    }

    public func onMessageArrival(team: String, worktree: String) async {
        await pipeline.onMessageArrival(team: team, worktree: worktree)
    }
}

/// Delivers through a protocol-v1 Claude peer socket, one sender run per
/// frame; the arrival loop sends later runs in follow-up passes.
struct ClaudePeerTransport: TeamDeliveryTransport {
    let runtime = TeamHookRuntime.claude
    let client: any ClaudePeerClienting
    let replyBridge: ClaudePeerReplyBridge?
    let logger: TeamDeliveryEventLogger

    /// Codex-only worktrees are fanned at this transport too; skip the
    /// wake and directory build when no Claude peer can exist.
    func mayServe(_ records: [TeamPresenceRecord]) -> Bool {
        records.contains { record in
            record.runtime == .claude
                && record.transport != nil
                && record.isSubagent != true
        }
    }

    func deliver(
        _ pending: [TeamInboxMessage],
        to agent: TeamAgentDescriptor,
        team: String,
        worktree: String
    ) async -> TeamDeliveryOutcome {
        guard case .claude(let socketPath, let protocolVersion) = agent.transport,
              protocolVersion == ClaudePeerProtocol.version else {
            return .pending(.init(outcome: "skipped_missing_transport"))
        }
        guard !pending.isEmpty else { return .pending(nil) }
        let agentID = agent.id.rawValue

        // One frame carries one native sender identity, so a frame may only
        // contain the leading run of rows that share a derived name.
        let senderName = ClaudePeerSenderName.name(for: pending[0])
        let run = Array(pending.prefix(while: {
            ClaudePeerSenderName.name(for: $0) == senderName && $0.from == pending[0].from
        }))

        let replySocket: String?
        do {
            replySocket = try await replyBridge?.replySocketPath(message: pending[0], recipient: agent)
        } catch {
            // Delivery still includes the inbox ID for CLI replies if the
            // optional native listener cannot be created or reaches capacity.
            replySocket = nil
            logger.log(team: team, worktree: worktree, .init(
                outcome: "error_reply_socket",
                detail: ["agentID": agentID, "error": String(describing: error)]
            ))
        }

        // A batch that overflows the peer protocol's frame cap would
        // otherwise be retried identically forever, wedging the queue.
        // Halve the batch until it fits; the next pass delivers the rest.
        var batch = run
        do {
            while true {
                do {
                    _ = try await client.send(
                        body: TeamPeerMessageFormatter.context(messages: batch),
                        socketPath: socketPath,
                        replySocketPath: replySocket,
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
            return .acknowledged(
                batch.map(\.id),
                .init(outcome: "skipped_oversized", detail: ["agentID": agentID])
            )
        } catch {
            return .pending(.init(outcome: "error_delivery", detail: [
                "agentID": agentID,
                "messageIDs": batch.map(\.id).joined(separator: ","),
                "error": String(describing: error),
            ]))
        }
        return .acknowledged(batch.map(\.id), .init(outcome: "sent", detail: ["agentID": agentID]))
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
                #" agent="\#(address)"\#(fallbackSuffix) id="\#(escapeAttribute(message.id))""#
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

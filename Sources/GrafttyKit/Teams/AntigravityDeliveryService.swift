import Foundation

public final class AntigravityDeliveryService: Sendable {
    private let pipeline: TeamDeliveryPipeline<AntigravityTransport>

    public init(
        inbox: TeamInbox,
        presenceRecords: @escaping @Sendable () -> [TeamPresenceRecord],
        agentReachability: @escaping @Sendable (TeamPresenceRecord) -> Bool,
        client: AntigravityAgentClienting = AntigravityAgentClient(),
        readToken: @escaping @Sendable (String) -> String? = { AntigravityServerBinder.readToken(atPath: $0) },
        eventLog: TeamEventLog? = TeamEventLog.defaultLog(),
        wakeBeforeDelivery: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        pipeline = TeamDeliveryPipeline(
            inbox: inbox,
            presenceRecords: presenceRecords,
            isReachable: agentReachability,
            wakeBeforeDelivery: wakeBeforeDelivery,
            logger: TeamDeliveryEventLogger(
                eventLog: eventLog,
                kind: .nativePeerDeliveryAttempt,
                runtime: .antigravity
            ),
            transport: AntigravityTransport(client: client, readToken: readToken)
        )
    }

    public func onMessageArrival(team: String, worktree: String) async {
        await pipeline.onMessageArrival(team: team, worktree: worktree)
    }
}

/// Delivers through the `agy` process's local agent server, sending every
/// pending row as one message. A failed send leaves the rows pending for the
/// next retry; hooks render queued rows only when a session starts.
struct AntigravityTransport: TeamDeliveryTransport {
    static let messageTitle = "Graftty team message"

    let runtime = TeamHookRuntime.antigravity
    let client: any AntigravityAgentClienting
    let readToken: @Sendable (String) -> String?

    /// Every arrival is fanned at this transport; skip the wake and
    /// directory build when no bound Antigravity server can exist.
    func mayServe(_ records: [TeamPresenceRecord]) -> Bool {
        records.contains { record in
            guard record.runtime == .antigravity, record.isSubagent != true,
                  case .antigravity = record.transport else { return false }
            return true
        }
    }

    /// @spec AGENT-6.174
    func deliver(
        _ pending: [TeamInboxMessage],
        to agent: TeamAgentDescriptor,
        team: String,
        worktree: String
    ) async -> TeamDeliveryOutcome {
        guard case .antigravity(let port, let conversationID, let tokenPath) = agent.transport else {
            return .pending(nil)
        }
        guard !pending.isEmpty else { return .pending(nil) }
        let detail = ["agentID": agent.id.rawValue]
        guard let token = readToken(tokenPath) else {
            return .pending(.init(outcome: "skipped_missing_credential", detail: detail))
        }
        do {
            try await client.send(
                content: TeamPeerMessageFormatter.context(messages: pending),
                title: Self.messageTitle,
                conversationID: conversationID,
                port: port,
                token: token
            )
        } catch {
            return .pending(.init(outcome: "error_delivery", detail: detail.merging([
                "messageIDs": pending.map(\.id).joined(separator: ","),
                "error": String(describing: error),
            ]) { current, _ in current }))
        }
        return .acknowledged(pending.map(\.id), .init(outcome: "sent", detail: detail))
    }
}

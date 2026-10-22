import Foundation

public final class CodexAppServerDeliveryService: Sendable {
    private let pipeline: TeamDeliveryPipeline<CodexAppServerTransport>

    public init(
        inbox: TeamInbox,
        presenceRecords: @escaping @Sendable () -> [TeamPresenceRecord],
        sessionStorage: CodexAppServerSessionStorage,
        liveness: TeamDeliveryLivenessChecking,
        client: CodexAppServerClienting,
        eventLog: TeamEventLog? = TeamEventLog.defaultLog(),
        now: @escaping @Sendable () -> Date = { Date() },
        wakeBeforeDelivery: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        let logger = TeamDeliveryEventLogger(
            eventLog: eventLog,
            kind: .codexAppServerDeliveryAttempt,
            runtime: .codex,
            now: now
        )
        pipeline = TeamDeliveryPipeline(
            inbox: inbox,
            presenceRecords: presenceRecords,
            isReachable: { record in
                TeamAgentReachability.isReachableForNativeDelivery(record, liveness: liveness)
            },
            wakeBeforeDelivery: wakeBeforeDelivery,
            logger: logger,
            transport: CodexAppServerTransport(
                sessionStorage: sessionStorage,
                liveness: liveness,
                client: client
            )
        )
    }

    public func onMessageArrival(team: String, worktree: String) async {
        await pipeline.onMessageArrival(team: team, worktree: worktree)
    }
}

/// Delivers through the owner pane's Codex app-server, sending every
/// pending row in one turn.
struct CodexAppServerTransport: TeamDeliveryTransport {
    let runtime = TeamHookRuntime.codex
    let sessionStorage: CodexAppServerSessionStorage
    let liveness: any TeamDeliveryLivenessChecking
    let client: any CodexAppServerClienting

    func unresolvedOutcome(in directory: TeamAgentDirectory) -> String {
        directory.agents.contains { $0.runtime == .codex && $0.isReachable }
            ? "skipped_unreachable"
            : "skipped_no_owner"
    }

    func deliver(
        _ pending: [TeamInboxMessage],
        to agent: TeamAgentDescriptor,
        team: String,
        worktree: String
    ) async -> TeamDeliveryOutcome {
        guard let ownerPane = agent.paneSessionName else {
            return .pending(.init(outcome: "skipped_no_owner"))
        }
        var detail = ["paneSessionName": ownerPane]
        func skip(_ outcome: String) -> TeamDeliveryOutcome {
            .pending(.init(outcome: outcome, detail: detail))
        }

        let record: CodexAppServerSessionRecord
        do {
            guard let stored = try sessionStorage.read(
                teamID: team,
                worktree: worktree,
                paneSessionName: ownerPane
            ) else {
                return skip("skipped_missing_app_server")
            }
            record = stored
        } catch {
            return skip("error_app_server_read")
        }
        guard isLiveAppServer(record) else { return skip("skipped_stale_app_server") }
        guard !pending.isEmpty else { return skip("skipped_no_pending") }

        do {
            let result = try await client.deliver(
                binaryPath: record.realBinaryPath,
                socketPath: record.socketPath,
                expectedCWD: worktree,
                message: TeamPeerMessageFormatter.context(messages: pending),
                target: record.threadID.map {
                    CodexAppServerTarget(threadID: $0, activeTurnID: record.activeTurnID)
                }
            )
            detail["threadID"] = result.threadID
            return .acknowledged(pending.map(\.id), .init(outcome: "sent", detail: detail))
        } catch {
            detail["messageIDs"] = pending.map(\.id).joined(separator: ",")
            let description = String(describing: error)
            if !description.isEmpty { detail["error"] = description }
            return skip("error_delivery")
        }
    }

    private func isLiveAppServer(_ record: CodexAppServerSessionRecord) -> Bool {
        guard let storedStart = record.appServerProcessStartTimeMicroseconds,
              let currentStart = liveness.processStartTimeMicroseconds(ofPID: record.appServerPID) else {
            return false
        }
        return currentStart == storedStart
    }
}

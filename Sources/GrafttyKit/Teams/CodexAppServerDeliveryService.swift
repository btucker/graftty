import Foundation

public actor CodexAppServerDeliveryService {
    private struct DeliveryKey: Hashable, Sendable {
        let team: String
        let worktree: String
    }

    private let inbox: TeamInbox
    private let presenceRecords: @Sendable () -> [TeamPresenceRecord]
    private let sessionStorage: CodexAppServerSessionStorage
    private let liveness: any TeamDeliveryLivenessChecking
    private let client: any CodexAppServerClienting
    private let eventLog: TeamEventLog?
    private let now: @Sendable () -> Date
    private var inFlightDeliveries: Set<DeliveryKey> = []
    private var dirtyDeliveries: Set<DeliveryKey> = []

    public init(
        inbox: TeamInbox,
        presenceRecords: @escaping @Sendable () -> [TeamPresenceRecord],
        sessionStorage: CodexAppServerSessionStorage,
        liveness: TeamDeliveryLivenessChecking,
        client: CodexAppServerClienting,
        eventLog: TeamEventLog? = TeamEventLog.defaultLog(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inbox = inbox
        self.presenceRecords = presenceRecords
        self.sessionStorage = sessionStorage
        self.liveness = liveness
        self.client = client
        self.eventLog = eventLog
        self.now = now
    }

    public func onMessageArrival(team: String, worktree: String) async {
        let deliveryKey = DeliveryKey(team: team, worktree: worktree)
        guard beginDelivery(deliveryKey) else {
            dirtyDeliveries.insert(deliveryKey)
            return
        }
        defer { finishDelivery(deliveryKey) }

        repeat {
            dirtyDeliveries.remove(deliveryKey)
            let advanced = await deliverOnce(team: team, worktree: worktree)
            if !advanced, dirtyDeliveries.remove(deliveryKey) == nil { break }
        } while true
    }

    private func beginDelivery(_ key: DeliveryKey) -> Bool {
        guard !inFlightDeliveries.contains(key) else {
            return false
        }
        inFlightDeliveries.insert(key)
        return true
    }

    private func finishDelivery(_ key: DeliveryKey) {
        inFlightDeliveries.remove(key)
    }

    @discardableResult
    private func deliverOnce(team: String, worktree: String) async -> Bool {
        let runtime = TeamHookRuntime.codex.rawValue
        let watermark: String?
        do {
            watermark = try inbox.worktreeWatermark(teamID: team, worktree: worktree)?
                .lastDeliveredToAnySessionID
        } catch {
            log(
                team: team,
                worktree: worktree,
                runtime: runtime,
                outcome: "error_watermark_read"
            )
            return false
        }

        let allUnread: [TeamInboxMessage]
        do {
            allUnread = try inbox.unreadMessages(
                teamID: team,
                recipientWorktree: worktree,
                after: watermark
            )
        } catch {
            log(
                team: team,
                worktree: worktree,
                runtime: runtime,
                outcome: "error_inbox_read"
            )
            return false
        }
        guard let first = allUnread.first else { return false }

        let worktreeRecords = presenceRecords().filter {
            $0.teamID == team && $0.worktree == worktree
        }
        let directory = TeamAgentDirectory(
            records: worktreeRecords,
            isReachable: { record in
                // The predicate shared with ClaudePeerDeliveryService and the
                // hook-side default-agent computation: if the reachability
                // views diverge, an untargeted head row is double-sent or
                // claimed by neither and the worktree queue wedges.
                TeamAgentReachability.isReachableForNativeDelivery(
                    record,
                    liveness: self.liveness
                )
            }
        )
        let selected: TeamAgentDescriptor?
        do {
            let targetRuntime = first.to.runtime.flatMap(TeamHookRuntime.init(rawValue:))
            selected = try directory.resolve(
                worktreePath: worktree,
                runtime: targetRuntime,
                explicitAgentID: first.to.agentID
            )
        } catch {
            log(team: team, worktree: worktree, runtime: runtime, outcome: "skipped_unreachable")
            return false
        }
        guard let selected, selected.runtime == .codex,
              let ownerPane = selected.paneSessionName else {
            log(team: team, worktree: worktree, runtime: runtime, outcome: "skipped_no_owner")
            return false
        }

        let record: CodexAppServerSessionRecord
        do {
            guard let stored = try sessionStorage.read(
                teamID: team,
                worktree: worktree,
                paneSessionName: ownerPane
            ) else {
                log(
                    team: team,
                    worktree: worktree,
                    runtime: runtime,
                    outcome: "skipped_missing_app_server",
                    paneSessionName: ownerPane
                )
                return false
            }
            record = stored
        } catch {
            log(
                team: team,
                worktree: worktree,
                runtime: runtime,
                outcome: "error_app_server_read",
                paneSessionName: ownerPane
            )
            return false
        }

        guard isLiveAppServer(record) else {
            log(
                team: team,
                worktree: worktree,
                runtime: runtime,
                outcome: "skipped_stale_app_server",
                paneSessionName: ownerPane
            )
            return false
        }

        let pending = TeamInbox.runtimeDeliverablePrefix(
            allUnread,
            runtime: runtime,
            agentID: selected.id.rawValue
        )

        guard let lastMessage = pending.last else {
            log(
                team: team,
                worktree: worktree,
                runtime: runtime,
                outcome: "skipped_no_pending",
                paneSessionName: ownerPane
            )
            return false
        }

        let result: CodexAppServerDeliveryResult
        do {
            result = try await client.deliver(
                binaryPath: record.realBinaryPath,
                socketPath: record.socketPath,
                expectedCWD: worktree,
                message: TeamPeerMessageFormatter.context(messages: pending),
                target: record.threadID.map {
                    CodexAppServerTarget(
                        threadID: $0,
                        activeTurnID: record.activeTurnID
                    )
                }
            )
        } catch {
            log(
                team: team,
                worktree: worktree,
                runtime: runtime,
                outcome: "error_delivery",
                paneSessionName: ownerPane,
                messageIDs: pending.map(\.id),
                error: String(describing: error)
            )
            return false
        }

        do {
            try inbox.compareAndAdvanceWorktreeWatermark(
                teamID: team,
                worktree: worktree,
                to: lastMessage.id
            )
        } catch {
            log(
                team: team,
                worktree: worktree,
                runtime: runtime,
                outcome: "error_watermark_write",
                paneSessionName: ownerPane,
                messageIDs: pending.map(\.id),
                threadID: result.threadID
            )
            return false
        }

        log(
            team: team,
            worktree: worktree,
            runtime: runtime,
            outcome: "sent",
            paneSessionName: ownerPane,
            messageIDs: pending.map(\.id),
            threadID: result.threadID
        )
        return true
    }

    private func isLiveAppServer(_ record: CodexAppServerSessionRecord) -> Bool {
        guard let storedStart = record.appServerProcessStartTimeMicroseconds,
              let currentStart = liveness.processStartTimeMicroseconds(ofPID: record.appServerPID) else {
            return false
        }
        return currentStart == storedStart
    }

    private func log(
        team: String,
        worktree: String,
        runtime: String,
        outcome: String,
        paneSessionName: String? = nil,
        messageIDs: [String] = [],
        threadID: String? = nil,
        error: String? = nil
    ) {
        guard let eventLog else { return }
        var detail: [String: String] = [
            "worktree": worktree,
            "runtime": runtime,
            "outcome": outcome,
        ]
        if let paneSessionName {
            detail["paneSessionName"] = paneSessionName
        }
        if !messageIDs.isEmpty {
            detail["messageIDs"] = messageIDs.joined(separator: ",")
        }
        if let threadID {
            detail["threadID"] = threadID
        }
        if let error, !error.isEmpty {
            detail["error"] = error
        }
        try? eventLog.append(TeamEvent(
            teamID: team,
            kind: .codexAppServerDeliveryAttempt,
            detail: detail,
            timestamp: now()
        ))
    }
}

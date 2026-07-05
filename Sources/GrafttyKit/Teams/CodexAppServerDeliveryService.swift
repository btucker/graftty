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
            await deliverOnce(team: team, worktree: worktree)
        } while dirtyDeliveries.remove(deliveryKey) != nil
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

    private func deliverOnce(team: String, worktree: String) async {
        let runtime = TeamHookRuntime.codex.rawValue
        let key = TeamDeliveryOwnerKey(teamID: team, worktree: worktree, runtime: .codex)
        let resolver = TeamDeliveryOwnershipResolver(records: presenceRecords, liveness: liveness)
        guard let owner = resolver.owner(for: key) else {
            log(team: team, worktree: worktree, runtime: runtime, outcome: "skipped_no_owner")
            return
        }

        let record: CodexAppServerSessionRecord
        do {
            guard let stored = try sessionStorage.read(
                teamID: team,
                worktree: worktree,
                paneSessionName: owner.paneSessionName
            ) else {
                log(
                    team: team,
                    worktree: worktree,
                    runtime: runtime,
                    outcome: "skipped_missing_app_server",
                    paneSessionName: owner.paneSessionName
                )
                return
            }
            record = stored
        } catch {
            log(
                team: team,
                worktree: worktree,
                runtime: runtime,
                outcome: "error_app_server_read",
                paneSessionName: owner.paneSessionName
            )
            return
        }

        guard isLiveAppServer(record) else {
            log(
                team: team,
                worktree: worktree,
                runtime: runtime,
                outcome: "skipped_stale_app_server",
                paneSessionName: owner.paneSessionName
            )
            return
        }

        let watermark: String?
        do {
            watermark = try inbox.worktreeWatermark(teamID: team, worktree: worktree)?
                .lastDeliveredToAnySessionID
        } catch {
            log(
                team: team,
                worktree: worktree,
                runtime: runtime,
                outcome: "error_watermark_read",
                paneSessionName: owner.paneSessionName
            )
            return
        }

        let pending: [TeamInboxMessage]
        do {
            pending = try inbox.unreadMessages(
                teamID: team,
                recipientWorktree: worktree,
                after: watermark
            )
        } catch {
            log(
                team: team,
                worktree: worktree,
                runtime: runtime,
                outcome: "error_inbox_read",
                paneSessionName: owner.paneSessionName
            )
            return
        }

        guard let lastMessage = pending.last else {
            log(
                team: team,
                worktree: worktree,
                runtime: runtime,
                outcome: "skipped_no_pending",
                paneSessionName: owner.paneSessionName
            )
            return
        }

        let result: CodexAppServerDeliveryResult
        do {
            result = try await client.deliver(
                binaryPath: record.realBinaryPath,
                socketPath: record.socketPath,
                expectedCWD: worktree,
                message: TeamHookRenderer.format(messages: pending)
            )
        } catch {
            log(
                team: team,
                worktree: worktree,
                runtime: runtime,
                outcome: "error_delivery",
                paneSessionName: owner.paneSessionName,
                messageIDs: pending.map(\.id)
            )
            return
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
                paneSessionName: owner.paneSessionName,
                messageIDs: pending.map(\.id),
                threadID: result.threadID
            )
            return
        }

        log(
            team: team,
            worktree: worktree,
            runtime: runtime,
            outcome: "sent",
            paneSessionName: owner.paneSessionName,
            messageIDs: pending.map(\.id),
            threadID: result.threadID
        )
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
        threadID: String? = nil
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
        try? eventLog.append(TeamEvent(
            teamID: team,
            kind: .codexAppServerDeliveryAttempt,
            detail: detail,
            timestamp: now()
        ))
    }
}

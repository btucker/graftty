import Foundation

/// One delivery-attempt event, minus the `worktree`/`runtime`/`outcome`
/// keys the logger stamps on every entry.
struct TeamDeliveryLogEntry: Sendable {
    var outcome: String
    var detail: [String: String] = [:]
}

/// What a transport did with the rows it was offered.
enum TeamDeliveryOutcome: Sendable {
    /// The provider accepted (or deliberately dropped) exactly these rows;
    /// the pipeline advances shared delivery state for them and logs `entry`
    /// with their IDs. IDs may be a prefix of the offer: the arrival loop
    /// runs another pass for the remainder.
    case acknowledged([String], TeamDeliveryLogEntry)
    /// Nothing was consumed; every offered row stays pending. A non-nil
    /// entry is logged.
    case pending(TeamDeliveryLogEntry?)
}

/// The provider-specific half of native team delivery. The pipeline owns
/// row selection and acknowledgement; a transport only reaches the agent.
protocol TeamDeliveryTransport: Sendable {
    var runtime: TeamHookRuntime { get }

    /// Presence-only gate checked before the worktree is woken or an
    /// unreadable inbox is logged, so a transport fanned for every arrival
    /// skips worktrees it can never serve.
    func mayServe(_ records: [TeamPresenceRecord]) -> Bool

    /// The outcome logged when no pending row resolves to a reachable agent
    /// of this runtime.
    func unresolvedOutcome(in directory: TeamAgentDirectory) -> String

    /// Delivers to `agent`. `pending` holds every row deliverable to it in
    /// inbox order and may be empty when the selecting row was addressed
    /// with a runtime the inbox filter rejects; the transport decides what
    /// to log for that case.
    func deliver(
        _ pending: [TeamInboxMessage],
        to agent: TeamAgentDescriptor,
        team: String,
        worktree: String
    ) async -> TeamDeliveryOutcome
}

extension TeamDeliveryTransport {
    func mayServe(_ records: [TeamPresenceRecord]) -> Bool { true }

    func unresolvedOutcome(in directory: TeamAgentDirectory) -> String {
        "skipped_unreachable"
    }
}

struct TeamDeliveryEventLogger: Sendable {
    let eventLog: TeamEventLog?
    let kind: TeamEvent.Kind
    let runtime: TeamHookRuntime
    var now: @Sendable () -> Date = { Date() }

    func log(team: String, worktree: String, _ entry: TeamDeliveryLogEntry) {
        guard let eventLog else { return }
        var detail = entry.detail
        detail["worktree"] = worktree
        detail["runtime"] = runtime.rawValue
        detail["outcome"] = entry.outcome
        try? eventLog.append(TeamEvent(
            teamID: team,
            kind: kind,
            detail: detail,
            timestamp: now()
        ))
    }
}

/// Shared spine of the native team-delivery services: coalesces arrivals
/// per worktree, selects the agent of the transport's runtime that owns the
/// earliest resolvable pending row, offers it every row it may consume, and
/// acknowledges only what the transport reports consumed.
actor TeamDeliveryPipeline<Transport: TeamDeliveryTransport> {
    private struct DeliveryKey: Hashable, Sendable {
        let team: String
        let worktree: String
    }

    private let inbox: TeamInbox
    private let presenceRecords: @Sendable () -> [TeamPresenceRecord]
    private let isReachable: @Sendable (TeamPresenceRecord) -> Bool
    private let wakeBeforeDelivery: @Sendable (String) -> Bool
    private let logger: TeamDeliveryEventLogger
    private let transport: Transport
    private var inFlight: Set<DeliveryKey> = []
    private var dirty: Set<DeliveryKey> = []

    init(
        inbox: TeamInbox,
        presenceRecords: @escaping @Sendable () -> [TeamPresenceRecord],
        isReachable: @escaping @Sendable (TeamPresenceRecord) -> Bool,
        wakeBeforeDelivery: @escaping @Sendable (String) -> Bool,
        logger: TeamDeliveryEventLogger,
        transport: Transport
    ) {
        self.inbox = inbox
        self.presenceRecords = presenceRecords
        self.isReachable = isReachable
        self.wakeBeforeDelivery = wakeBeforeDelivery
        self.logger = logger
        self.transport = transport
    }

    /// @spec TEAM-11.12
    func onMessageArrival(team: String, worktree: String) async {
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

    private func deliverOnce(team: String, worktree: String) async -> Bool {
        let allUnread: [TeamInboxMessage]
        do {
            allUnread = try inbox.worktreePendingMessages(
                teamID: team,
                recipientWorktree: worktree
            )
        } catch {
            // Every transport is fanned for every arrival; only one that may
            // serve this worktree reports its unreadable inbox.
            if transport.mayServe(worktreeRecords(team: team, worktree: worktree)) {
                logger.log(team: team, worktree: worktree, .init(outcome: "error_inbox_read"))
            }
            return false
        }
        guard !allUnread.isEmpty else { return false }

        let records = worktreeRecords(team: team, worktree: worktree)
        guard transport.mayServe(records) else { return false }
        guard wakeBeforeDelivery(worktree) else { return false }

        // Every native transport and the hook-side default-agent computation
        // must share one reachability view: if they diverge, an untargeted
        // head row is double-sent or claimed by none and the queue wedges.
        let directory = TeamAgentDirectory(records: records, isReachable: isReachable)
        let runtime = transport.runtime
        let selected = allUnread.lazy.compactMap { message -> TeamAgentDescriptor? in
            let targetRuntime = message.to.runtime.flatMap(TeamHookRuntime.init(rawValue:))
            let candidate = try? directory.resolve(
                worktreePath: worktree,
                runtime: targetRuntime,
                explicitAgentID: message.to.agentID
            )
            return candidate?.runtime == runtime ? candidate : nil
        }.first
        guard let selected else {
            logger.log(
                team: team,
                worktree: worktree,
                .init(outcome: transport.unresolvedOutcome(in: directory))
            )
            return false
        }

        let defaultAgent = try? directory.resolve(worktreePath: worktree, explicitAgentID: nil)
        let pending = TeamInbox.runtimeDeliverableMessages(
            allUnread,
            runtime: runtime.rawValue,
            agentID: selected.id.rawValue,
            acceptsUntargeted: defaultAgent?.id == selected.id
        )

        switch await transport.deliver(pending, to: selected, team: team, worktree: worktree) {
        case .pending(let entry):
            if let entry { logger.log(team: team, worktree: worktree, entry) }
            return false
        case .acknowledged(let ids, var entry):
            // An empty acknowledgement is no progress; reporting it as an
            // advance would spin the arrival loop forever.
            guard !ids.isEmpty else {
                logger.log(team: team, worktree: worktree, entry)
                return false
            }
            entry.detail["messageIDs"] = ids.joined(separator: ",")
            do {
                try inbox.acknowledgeMessages(teamID: team, worktree: worktree, messageIDs: ids)
            } catch {
                entry.outcome = "error_watermark_write"
                entry.detail["error"] = String(describing: error)
                logger.log(team: team, worktree: worktree, entry)
                return false
            }
            logger.log(team: team, worktree: worktree, entry)
            return true
        }
    }

    private func worktreeRecords(team: String, worktree: String) -> [TeamPresenceRecord] {
        presenceRecords().filter { $0.teamID == team && $0.worktree == worktree }
    }
}

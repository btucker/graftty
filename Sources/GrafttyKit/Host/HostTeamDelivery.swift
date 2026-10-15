import Foundation

private final class HostDeliveryLiveness: TeamDeliveryLivenessChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var liveSessions: Set<String> = []
    func replace(_ names: Set<String>) { lock.withLock { liveSessions = names } }
    func isLivePaneSession(_ name: String) -> Bool { lock.withLock { liveSessions.contains(name) } }
    func processStartTimeMicroseconds(ofPID pid: Int32) -> Int64? { ProcessIdentityReader.startTimeMicroseconds(ofPID: pid) }
}

public extension HeadlessHostRuntime {
    /// Retries pending native messages after provider registration and host
    /// restart. The existing services own ordering, watermarks, and retries.
    func startTeamDelivery() {
        guard deliveryTask == nil else { return }
        let storage = presence
        let liveness = HostDeliveryLiveness()
        let codex = CodexAppServerDeliveryService(inbox: inbox,
            presenceRecords: { (try? storage.listAll()) ?? [] },
            sessionStorage: CodexAppServerSessionStorage(rootDirectory: storage.rootDirectory),
            liveness: liveness, client: CodexAppServerClient(), eventLog: nil)
        let bridge = ClaudePeerReplyBridge(directoryParent: configuration.runtimeDirectory) { [weak self] message, agent, reply in
            guard let self else { return .error("host stopped") }
            return await self.handle(.teamReply(callerWorktree: agent.worktreePath, callerAgentID: agent.id.rawValue,
                messageID: message.id, text: reply.body, priority: reply.priority == .now ? .urgent : .normal))
        }
        let claude = ClaudePeerDeliveryService(inbox: inbox,
            presenceRecords: { (try? storage.listAll()) ?? [] },
            agentReachability: { TeamAgentReachability.isReachableForNativeDelivery($0, liveness: liveness) },
            eventLog: nil, replyBridge: bridge)
        deliveryTask = Task { [weak self] in
            defer { Task { await bridge.close() } }
            while !Task.isCancelled {
                guard let self else { return }
                if let names = try? await self.terminals.sessions() { liveness.replace(names) }
                let records = await Task.detached { (try? storage.listAll()) ?? [] }.value
                let targets = Dictionary(grouping: records.filter { $0.isSubagent != true }, by: \.worktree)
                for (path, records) in targets {
                    guard let team = records.first?.teamID else { continue }
                    await codex.onMessageArrival(team: team, worktree: path)
                    await claude.onMessageArrival(team: team, worktree: path)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

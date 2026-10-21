import SwiftUI
import GrafttyKit

/// Native team-message delivery for Codex app-server and Claude peer
/// agents: the presence index and sweep ticker, per-team inbox observers,
/// the pane-closed presence fallback, and the post-restore retry.
///
/// `GrafttyApp.startup()` builds one instance, calls `install()` once, and
/// calls `refreshAndRetryRestoredDelivery()` after restoring running
/// worktrees and again after launch reconciliation.
@MainActor
final class NativeTeamDelivery {
    private let services: AppServices
    private let tm: TerminalManager
    private let binding: Binding<AppState>
    private let presenceStorage: TeamPresenceStorage
    private let presenceIndex: TeamPresenceIndex
    private let livePaneSessionNames: LivePaneSessionNames
    private let codexAppServerDeliveryService: CodexAppServerDeliveryService
    private let claudePeerDeliveryService: ClaudePeerDeliveryService

    init(services: AppServices, terminalManager tm: TerminalManager, appState binding: Binding<AppState>) {
        let sleepCoordinator = tm.autoSleep.coordinator
        let teamInbox = services.teamInbox
        let teamEventDispatcher = services.teamEventDispatcher
        let remoteTeamRouter = services.remoteTeamRouter
        let presenceStorage = TeamPresenceStorage(
            rootDirectory: TeamPresenceStorage.defaultRoot()
        )
        let presenceIndex = TeamPresenceIndex(
            records: (try? presenceStorage.listAll()) ?? []
        )

        let livePaneSessionNames = LivePaneSessionNames()

        let deliveryLiveness = AppTeamDeliveryLiveness(
            livePaneSession: { livePaneSessionNames.contains($0) },
            processStartTimeMicroseconds: { ProcessIdentityReader.startTimeMicroseconds(ofPID: $0) }
        )
        let codexAppServerDeliveryService = CodexAppServerDeliveryService(
            inbox: services.teamInbox,
            presenceRecords: { (try? presenceStorage.listAll()) ?? [] },
            sessionStorage: CodexAppServerSessionStorage(rootDirectory: TeamPresenceStorage.defaultRoot()),
            liveness: deliveryLiveness,
            client: CodexAppServerClient(),
            wakeBeforeDelivery: { sleepCoordinator.wake(path: $0) }
        )
        let claudeReplyBridge = ClaudePeerReplyBridge { original, recipient, reply in
            // The bridge binds a socket to the recipient that received the
            // original row. Refuse a reply after that exact session disappears.
            let reachable = await OffMainIO.run {
                let records = (try? presenceStorage.listAll()) ?? []
                return records.contains {
                    TeamAgentDirectory.identity(for: $0) == recipient.id && $0.worktree == recipient.worktreePath
                        && $0.transport == recipient.transport
                        && TeamAgentReachability.isReachable($0)
                }
            }
            guard reachable else { return .error("The replying Claude agent is no longer reachable") }
            return await GrafttyApp.handleTeamReply(
                .teamReply(callerWorktree: recipient.worktreePath, callerAgentID: recipient.id.rawValue,
                           messageID: original.id, text: reply.body,
                           priority: reply.priority == .now ? .urgent : .normal),
                appState: binding, router: remoteTeamRouter, inbox: teamInbox,
                dispatcher: teamEventDispatcher
            )
        }
        let claudePeerDeliveryService = ClaudePeerDeliveryService(
            inbox: services.teamInbox,
            presenceRecords: { (try? presenceStorage.listAll()) ?? [] },
            agentReachability: { record in
                // The shared native-delivery predicate, closed over the same
                // liveness view the Codex service uses, so both services and
                // the hook-side default-agent computation agree on which
                // agent owns an untargeted head row.
                TeamAgentReachability.isReachableForNativeDelivery(
                    record,
                    liveness: deliveryLiveness
                )
            },
            replyBridge: claudeReplyBridge,
            wakeBeforeDelivery: { sleepCoordinator.wake(path: $0) }
        )

        self.services = services
        self.tm = tm
        self.binding = binding
        self.presenceStorage = presenceStorage
        self.presenceIndex = presenceIndex
        self.livePaneSessionNames = livePaneSessionNames
        self.codexAppServerDeliveryService = codexAppServerDeliveryService
        self.claudePeerDeliveryService = claudePeerDeliveryService
    }

    func install() {
        let services = self.services
        let tm = self.tm
        let binding = self.binding
        let presenceStorage = self.presenceStorage
        let presenceIndex = self.presenceIndex
        let codexAppServerDeliveryService = self.codexAppServerDeliveryService
        let claudePeerDeliveryService = self.claudePeerDeliveryService

        // Sweep dangling presence files left behind by SIGKILL'd agents
        // whose wrapper trap never fired. The wrapper trap is the primary
        // cleanup path (TEAM-PRESENCE-1.3); this fallback runs on a slow
        // cadence and only deletes records whose recorded PID is no
        // longer alive per `kill(pid, 0)` semantics. Continues while
        // backgrounded for the same reason the stats poller does:
        // agent processes can die at any time and Graftty might not be
        // frontmost when it happens.
        let presenceTicker = PollingTicker(
            interval: .seconds(30),
            pauseWhenInactive: { false }
        )
        services.presenceCleanupTicker = presenceTicker
        presenceTicker.start { [self] in
            let records = await presenceIndex.refresh {
                await TeamPresenceMonitor.sweep(storage: presenceStorage)
            }
            refreshDeliveryLiveness(records: records)
            let teamsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
            await GrafttyApp.retryNativeDeliveryForPresenceWorktrees(
                inbox: services.teamInbox,
                records: records,
                deliveries: GrafttyApp.nativeDeliveries(
                    codex: codexAppServerDeliveryService,
                    claude: claudePeerDeliveryService,
                    enabled: teamsEnabled
                )
            )
        }

        // Subscribe Codex app-server and Claude peer delivery to inbox
        // file-system events.
        // TeamInboxObserver fires with the full message list on every
        // append. We track the previous count and fire onMessageArrival
        // only when new messages arrive, to avoid redundant delivers.
        // We watch each team's inbox for all repos that exist at startup time;
        // the watcher self-heals for the file-not-yet-created case via the
        // directory watch inside TeamInboxObserver.
        let inboxRoot = AppState.defaultDirectory
            .appendingPathComponent("team-inbox", isDirectory: true)
        for repo in binding.wrappedValue.repos {
            let teamID = repo.path
            let observer = TeamInboxObserver(rootDirectory: inboxRoot, teamID: teamID)
            // Per-observer state claims message ranges before awaiting
            // app-server delivery. `TeamInboxObserver` callbacks can overlap
            // once they hop through Task/MainActor, so the actor owns the
            // count update.
            // (A previous version used a shared `[String: Int]` map across
            // all observer closures and crashed under concurrent mutation
            // by multiple observer queues — Swift Dictionary is not
            // thread-safe.)
            let deliveryState = GrafttyApp.CodexAppServerInboxObserverDeliveryState(skipInitialSnapshot: true)
            let cancellable = observer.start {
                [self, weak codexAppServerDeliveryService, weak claudePeerDeliveryService] messages in
                Task { @MainActor in
                    refreshDeliveryLiveness()
                    guard UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled) else {
                        await deliveryState.markSeen(messages)
                        return
                    }
                    guard codexAppServerDeliveryService != nil || claudePeerDeliveryService != nil else {
                        await deliveryState.markSeen(messages)
                        return
                    }
                    let recipientWorktrees = await deliveryState.claimRecipientWorktrees(in: messages)
                    let awakeRecipients = recipientWorktrees.filter { tm.wakeWorktree($0) }
                    var deliveries: [any CodexAppServerDeliveryTrigger] = []
                    if let codexAppServerDeliveryService {
                        deliveries.append(codexAppServerDeliveryService)
                    }
                    if let claudePeerDeliveryService {
                        deliveries.append(claudePeerDeliveryService)
                    }
                    await GrafttyApp.drainNativeDeliveryMessages(
                        teamID: teamID,
                        recipientWorktrees: awakeRecipients,
                        inbox: services.teamInbox,
                        deliveries: deliveries
                    )
                }
            }
            services.inboxObserverCancellables.append(cancellable)
            services.inboxObservers.append(observer)
        }

        // Persist the delivery service on AppServices so it outlives startup().
        services.codexAppServerDeliveryService = codexAppServerDeliveryService
        services.claudePeerDeliveryService = claudePeerDeliveryService

        // When a pane is destroyed, sweep any TeamPresenceRecord whose
        // paneSessionName matches the closing pane. The agent's own
        // `team unregister` cleanup hook is the primary path; this fallback
        // covers the SIGKILL / hard-quit case where the pane went away
        // without the registered process getting a chance to clean up.
        tm.paneClosed = { [self, presenceStorage] _, sessionName in
            guard let sessionName else { return }
            services.claudeSessionRegistry.removePane(sessionName)
            _ = refreshPresenceIndex()
            for record in presenceIndex.records(forPaneSessionName: sessionName) {
                try? presenceStorage.delete(
                    teamID: record.teamID,
                    worktree: record.worktree,
                    runtime: record.runtime,
                    paneSessionName: record.paneSessionName,
                    agentID: record.agentID
                )
                presenceIndex.remove(
                    teamID: record.teamID,
                    worktree: record.worktree,
                    runtime: record.runtime,
                    paneSessionName: record.paneSessionName
                )
            }
            let records = presenceIndex.allRecords()
            refreshDeliveryLiveness(records: records)
            Task {
                await GrafttyApp.retryNativeDeliveryForPresenceWorktrees(
                    inbox: services.teamInbox,
                    records: records,
                    deliveries: GrafttyApp.nativeDeliveries(
                        codex: codexAppServerDeliveryService,
                        claude: claudePeerDeliveryService,
                        enabled: UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
                    )
                )
            }
        }
    }

    private func refreshPresenceIndex() -> [TeamPresenceRecord] {
        let records = (try? presenceStorage.listAll()) ?? []
        presenceIndex.replace(with: records)
        return records
    }

    private func refreshDeliveryLiveness(records: [TeamPresenceRecord]? = nil) {
        let records = records ?? refreshPresenceIndex()
        let names = GrafttyApp.livePaneSessionNamesForAutomaticDelivery(
            records: records,
            terminalManager: tm
        )
        livePaneSessionNames.replace(with: names)
    }

    func refreshAndRetryRestoredDelivery() {
        let restoredPresenceRecords = refreshPresenceIndex()
        refreshDeliveryLiveness(records: restoredPresenceRecords)
        Task {
            await GrafttyApp.retryNativeDeliveryForPresenceWorktrees(
                inbox: services.teamInbox,
                records: restoredPresenceRecords,
                deliveries: GrafttyApp.nativeDeliveries(
                    codex: codexAppServerDeliveryService,
                    claude: claudePeerDeliveryService,
                    enabled: UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
                )
            )
        }
    }
}

private final class LivePaneSessionNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []

    func replace(with names: Set<String>) {
        lock.lock()
        self.names = names
        lock.unlock()
    }

    func contains(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return names.contains(name)
    }
}

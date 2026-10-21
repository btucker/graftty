import SwiftUI
import AppKit
import GrafttyCommandUI
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

extension GrafttyApp {
    actor CodexAppServerInboxObserverDeliveryState {
        private var lastSeenCount: Int
        private var skipInitialSnapshot: Bool

        init(lastSeenCount: Int = 0, skipInitialSnapshot: Bool = false) {
            self.lastSeenCount = lastSeenCount
            self.skipInitialSnapshot = skipInitialSnapshot
        }

        func markSeen(_ messages: [TeamInboxMessage]) {
            lastSeenCount = messages.count
            skipInitialSnapshot = false
        }

        func claimRecipientWorktrees(in messages: [TeamInboxMessage]) -> [String] {
            if skipInitialSnapshot {
                skipInitialSnapshot = false
                lastSeenCount = messages.count
                return []
            }

            let previousCount = lastSeenCount
            let currentCount = messages.count
            lastSeenCount = currentCount
            guard currentCount > previousCount else { return [] }

            var seenWorktrees: Set<String> = []
            var recipientWorktrees: [String] = []
            for message in messages[previousCount..<currentCount] where seenWorktrees.insert(message.to.worktree).inserted {
                recipientWorktrees.append(message.to.worktree)
            }
            return recipientWorktrees
        }
    }

    @MainActor
    static func livePaneSessionNamesForAutomaticDelivery(
        records: [TeamPresenceRecord],
        terminalManager: TerminalManager
    ) -> Set<String> {
        Set(records.compactMap { record -> String? in
            // A background or LRU-evicted pane intentionally has no mounted
            // SurfaceHandle, but its durable pane-to-zmx mapping remains
            // authoritative until the pane is destroyed. Delivery liveness
            // must follow that mapping rather than UI visibility; the owner
            // resolver separately verifies the registered process identity.
            guard let sessionName = record.paneSessionName,
                  terminalManager.paneID(forSessionName: sessionName) != nil else {
                return nil
            }
            return sessionName
        })
    }

    nonisolated static func deliverCodexAppServerMessages(
        teamID: String,
        recipientWorktrees: [String],
        delivery: CodexAppServerDeliveryTrigger
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for recipientWorktree in recipientWorktrees {
                group.addTask {
                    await delivery.onMessageArrival(team: teamID, worktree: recipientWorktree)
                }
            }
        }
    }

    nonisolated static func drainNativeDeliveryMessages(
        teamID: String,
        recipientWorktrees: [String],
        inbox: TeamInbox,
        deliveries: [any CodexAppServerDeliveryTrigger],
        maximumPasses: Int = 64
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for recipientWorktree in recipientWorktrees {
                group.addTask {
                    for _ in 0..<maximumPasses {
                        let before = try? inbox.worktreeWatermark(
                            teamID: teamID,
                            worktree: recipientWorktree
                        )
                        // Sequential on purpose: both services may see the
                        // same untargeted row, and only its selected default
                        // owner may acknowledge it.
                        for delivery in deliveries {
                            await delivery.onMessageArrival(
                                team: teamID,
                                worktree: recipientWorktree
                            )
                        }
                        let after = try? inbox.worktreeWatermark(
                            teamID: teamID,
                            worktree: recipientWorktree
                        )
                        if before == after { break }
                    }
                }
            }
        }
    }

    nonisolated static func nativeDeliveries(
        codex: CodexAppServerDeliveryService,
        claude: ClaudePeerDeliveryService,
        enabled: Bool = true
    ) -> [any CodexAppServerDeliveryTrigger] {
        guard enabled else { return [] }
        return [codex, claude]
    }

    nonisolated static func retryNativeDeliveryForPresenceWorktrees(
        inbox: TeamInbox,
        records: [TeamPresenceRecord],
        deliveries: [any CodexAppServerDeliveryTrigger]
    ) async {
        var seen: Set<TeamDeliveryPresenceWorktreeKey> = []
        var keys: [TeamDeliveryPresenceWorktreeKey] = []
        for record in records {
            guard record.runtime == .codex
                    || (record.runtime == .claude && record.transport != nil) else {
                continue
            }
            let key = TeamDeliveryPresenceWorktreeKey(
                teamID: record.teamID,
                worktree: record.worktree
            )
            // Do not gate on the oldest row's runtime: each delivery service
            // scans the pending set for rows it can consume.
            guard seen.insert(key).inserted,
                  !Self.pendingUnreadMessages(inbox: inbox, key: key).isEmpty else {
                continue
            }
            keys.append(key)
        }
        await withTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask {
                    await Self.drainNativeDeliveryMessages(
                        teamID: key.teamID,
                        recipientWorktrees: [key.worktree],
                        inbox: inbox,
                        deliveries: deliveries
                    )
                }
            }
        }
    }

    nonisolated static func retryCodexAppServerDeliveryForPresenceWorktrees(
        inbox: TeamInbox,
        records: [TeamPresenceRecord],
        delivery: CodexAppServerDeliveryTrigger
    ) async {
        var seen: Set<TeamDeliveryPresenceWorktreeKey> = []
        var keys: [TeamDeliveryPresenceWorktreeKey] = []
        for record in records where record.runtime == .codex {
            let key = TeamDeliveryPresenceWorktreeKey(teamID: record.teamID, worktree: record.worktree)
            guard seen.insert(key).inserted else { continue }
            if Self.hasPendingUnreadMessage(inbox: inbox, key: key) {
                keys.append(key)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask {
                    await delivery.onMessageArrival(team: key.teamID, worktree: key.worktree)
                }
            }
        }
    }

    /// Gate for the Codex-only retry helper. Rows for another provider do not
    /// suppress a later Codex or untargeted row because delivery positions can
    /// acknowledge matching rows out of order.
    private nonisolated static func hasPendingUnreadMessage(
        inbox: TeamInbox,
        key: TeamDeliveryPresenceWorktreeKey
    ) -> Bool {
        pendingUnreadMessages(inbox: inbox, key: key).contains {
            $0.to.runtime == nil || $0.to.runtime == TeamHookRuntime.codex.rawValue
        }
    }

    private nonisolated static func pendingUnreadMessages(
        inbox: TeamInbox,
        key: TeamDeliveryPresenceWorktreeKey
    ) -> [TeamInboxMessage] {
        do {
            return try inbox.worktreePendingMessages(
                teamID: key.teamID,
                recipientWorktree: key.worktree
            )
        } catch {
            return []
        }
    }

    private struct TeamDeliveryPresenceWorktreeKey: Hashable, Sendable {
        let teamID: String
        let worktree: String
    }
}

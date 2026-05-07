import Foundation

/// Pluggable target for `IdleDeliveryService` nudges. Production wires
/// this to a zmx PTY writer; tests record invocations.
public protocol NudgeSender: Sendable {
    func send(paneID: UUID, message: String, messageIDs: [String]) async
}

/// @spec TEAM-IDLE-2.1
/// @spec TEAM-IDLE-2.3
/// @spec TEAM-IDLE-2.4
/// @spec TEAM-IDLE-2.5
/// @spec TEAM-IDLE-2.6
/// Event-driven Codex idle-delivery dispatcher. Receives Stop and
/// new-message-arrival signals, queries the agent-state registry,
/// and on `idle` sends pending messages via NudgeSender then
/// advances the per-(team,worktree,runtime) zmxWatermark.
public actor IdleDeliveryService {
    private let inbox: TeamInbox
    private let state: WorktreeAgentStateRegistry
    private let nudgeSender: NudgeSender
    private let eventLog: TeamEventLog?
    private let now: @Sendable () -> Date

    public init(
        inbox: TeamInbox,
        state: WorktreeAgentStateRegistry,
        nudgeSender: NudgeSender,
        eventLog: TeamEventLog? = TeamEventLog.defaultLog(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inbox = inbox
        self.state = state
        self.nudgeSender = nudgeSender
        self.eventLog = eventLog
        self.now = now
    }

    public func onStop(team: String, worktree: String, runtime: String, paneID: UUID?) async {
        await maybeDeliver(team: team, worktree: worktree, runtime: runtime, paneID: paneID, trigger: "stop")
    }

    public func onMessageArrival(team: String, worktree: String, runtime: String, paneID: UUID?) async {
        await maybeDeliver(team: team, worktree: worktree, runtime: runtime, paneID: paneID, trigger: "messageArrival")
    }

    private func maybeDeliver(team: String, worktree: String, runtime: String, paneID: UUID?, trigger: String) async {
        // Unconditional entry log so we can see in events.jsonl
        // whether maybeDeliver is being called at all for a given
        // worktree. Reading these in tail order distinguishes
        // "observer never dispatched" (no entry) from "dispatched but
        // gated" (entry + skipped_*).
        log(team: team, worktree: worktree, runtime: runtime,
            outcome: "called_pane_\(paneID?.uuidString ?? "nil")", trigger: trigger)
        // zmx-send is the Codex equivalent of Claude's asyncRewake
        // watcher. Claude already receives unread messages via the
        // watcher's stderr-on-exit path, so dispatching zmx-send here
        // would deliver every event twice. Gate at the runtime
        // boundary.
        guard runtime == "codex" else {
            log(team: team, worktree: worktree, runtime: runtime, outcome: "skipped_runtime_\(runtime)")
            return
        }
        let s = state.state(worktree: worktree, runtime: runtime)
        guard s == .idle else {
            log(team: team, worktree: worktree, runtime: runtime, outcome: "skipped_state_\(s.rawValue)")
            return
        }
        guard let paneID else {
            log(team: team, worktree: worktree, runtime: runtime, outcome: "skipped_no_pane")
            return
        }
        let watermark: String?
        do { watermark = try inbox.zmxWatermark(teamID: team, worktree: worktree, runtime: runtime) }
        catch { log(team: team, worktree: worktree, runtime: runtime, outcome: "error_watermark_read"); return }

        let pending: [TeamInboxMessage]
        do { pending = try inbox.unreadMessages(teamID: team, recipientWorktree: worktree, after: watermark) }
        catch { log(team: team, worktree: worktree, runtime: runtime, outcome: "error_inbox_read"); return }

        guard let lastMessage = pending.last else {
            log(team: team, worktree: worktree, runtime: runtime, outcome: "skipped_no_pending"); return
        }

        let text = TeamHookRenderer.format(messages: pending)
        await nudgeSender.send(paneID: paneID, message: text, messageIDs: pending.map(\.id))
        do {
            try inbox.advanceZmxWatermark(teamID: team, worktree: worktree, runtime: runtime, to: lastMessage.id)
        } catch {
            log(team: team, worktree: worktree, runtime: runtime, outcome: "error_watermark_write"); return
        }
        log(team: team, worktree: worktree, runtime: runtime,
            outcome: "sent", messageIDs: pending.map(\.id), trigger: trigger)
    }

    private func log(
        team: String, worktree: String, runtime: String,
        outcome: String, messageIDs: [String] = [], trigger: String = ""
    ) {
        guard let eventLog else { return }
        var detail: [String: String] = ["worktree": worktree, "runtime": runtime, "outcome": outcome]
        if !messageIDs.isEmpty { detail["messageIDs"] = messageIDs.joined(separator: ",") }
        if !trigger.isEmpty { detail["trigger"] = trigger }
        try? eventLog.append(TeamEvent(teamID: team, kind: .zmxNudgeAttempt, detail: detail, timestamp: now()))
    }
}

/// @spec TEAM-IDLE-2.6
/// Production NudgeSender that writes pending-message text into the
/// recipient pane's zmx PTY via a `ZmxWriter` adapter. Tests inject
/// a stub writer; production uses `AppZmxWriter` (Sources/Graftty)
/// which calls `typeText` on the pane's `SurfaceHandle`.
public final class ZmxNudgeSender: NudgeSender, @unchecked Sendable {
    private let writer: ZmxWriter
    public init(writer: ZmxWriter) {
        self.writer = writer
    }
    public func send(paneID: UUID, message: String, messageIDs: [String]) async {
        let session = ZmxLauncher.sessionName(for: paneID)
        do { try await writer.write(sessionName: session, text: message, submit: true) }
        catch { NSLog("[Graftty] zmx send failed for %@: %@", session, "\(error)") }
    }
}

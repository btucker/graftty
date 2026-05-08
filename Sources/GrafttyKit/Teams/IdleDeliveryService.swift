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
/// @spec TEAM-IDLE-2.11
/// @spec TEAM-IDLE-2.12
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

    public func onStop(team: String, worktree: String, paneIDs: [UUID]) async {
        await maybeDeliver(team: team, worktree: worktree, paneIDs: paneIDs, trigger: "stop")
    }

    public func onMessageArrival(team: String, worktree: String, paneIDs: [UUID]) async {
        await maybeDeliver(team: team, worktree: worktree, paneIDs: paneIDs, trigger: "messageArrival")
    }

    private func maybeDeliver(
        team: String,
        worktree: String,
        paneIDs: [UUID],
        trigger: String
    ) async {
        // The service is implicitly codex-only by construction:
        // - inbox-observer dispatch passes only codex paneIDs (filtered upstream);
        // - the Stop-hook callback only invokes us for runtime == .codex.
        guard !paneIDs.isEmpty else {
            log(team: team, worktree: worktree, runtime: "codex",
                outcome: "skipped_no_codex_panes")
            return
        }
        // .idle: agent fired Stop with no recent typing — clear deliver.
        // .unknown: no SessionStart observed since graftty started, but
        //   if the worktree has a pane the agent is presumably running
        //   (e.g. an existing session that predates graftty's restart).
        //   Better to deliver and let the message land in the input
        //   buffer than to silently hold it forever waiting for a
        //   SessionStart that may never come.
        // .active / .user_engaged: skip — pretty clear the agent is
        //   busy or the user is typing.
        let s = state.state(worktree: worktree, runtime: "codex")
        guard s == .idle || s == .unknown else {
            log(team: team, worktree: worktree, runtime: "codex",
                outcome: "skipped_state_\(s.rawValue)")
            return
        }
        let watermark: String?
        do { watermark = try inbox.zmxWatermark(teamID: team, worktree: worktree, runtime: "codex") }
        catch {
            log(team: team, worktree: worktree, runtime: "codex", outcome: "error_watermark_read")
            return
        }
        let pending: [TeamInboxMessage]
        do { pending = try inbox.unreadMessages(teamID: team, recipientWorktree: worktree, after: watermark) }
        catch {
            log(team: team, worktree: worktree, runtime: "codex", outcome: "error_inbox_read")
            return
        }
        guard let lastMessage = pending.last else {
            log(team: team, worktree: worktree, runtime: "codex", outcome: "skipped_no_pending")
            return
        }
        let text = TeamHookRenderer.format(messages: pending)
        for paneID in paneIDs {
            await nudgeSender.send(paneID: paneID, message: text, messageIDs: pending.map(\.id))
        }
        do {
            try inbox.advanceZmxWatermark(teamID: team, worktree: worktree,
                                          runtime: "codex", to: lastMessage.id)
        } catch {
            log(team: team, worktree: worktree, runtime: "codex", outcome: "error_watermark_write")
            return
        }
        log(team: team, worktree: worktree, runtime: "codex",
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

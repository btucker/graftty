import Foundation
import Observation
import GrafttyProtocol

/// One viewer's Chat for one agent tab. The owner keeps it while the tab shows
/// Terminal, so the draft is still here when the viewer switches back.
@MainActor @Observable
public final class AgentChatModel {
    public private(set) var snapshot: AgentChatSnapshot?
    public private(set) var unavailable: String?
    /// Why the last send or answer did not go through.
    public private(set) var notice: String?
    public private(set) var isSending = false
    public var draft = "" {
        didSet { if draft != oldValue { notice = nil } }
    }

    /// The connection the current feed came from. Sends and answers go to
    /// it, so they reach the channel this viewer attached through.
    private var connection: AgentChatConnection?

    public init() {}

    public var slashMatches: [AgentChatCommand] {
        AgentChatSlashQuery(draft: draft, commands: snapshot?.commands ?? [])?.matches ?? []
    }

    public var canSend: Bool {
        guard let snapshot, snapshot.endedReason == nil, snapshot.turnState == .idle, !isSending else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Attaches and follows the conversation until the view goes away or the
    /// conversation ends.
    public func run(_ connection: AgentChatConnection) async {
        self.connection = connection
        switch await connection.open() {
        case .unavailable(let reason):
            snapshot = nil
            unavailable = reason
        case .attached(let initial, let updates):
            unavailable = nil
            var transcript = AgentChatTranscript(snapshot: initial)
            snapshot = initial
            for await update in updates {
                if Task.isCancelled { return }
                if transcript.apply(update) { snapshot = transcript.snapshot }
            }
            // The feed stopped while the conversation is still going: the
            // link to the host dropped. A stale transcript would look live.
            if !Task.isCancelled, transcript.snapshot.endedReason == nil {
                snapshot = nil
                unavailable = "Chat lost its connection to the agent. Reopen Chat to continue."
            }
        }
    }

    /// Puts the command in the draft. Nothing is sent until the user sends it.
    public func choose(_ command: AgentChatCommand) {
        draft = AgentChatSlashQuery.draft(choosing: command)
    }

    public func send() async {
        guard canSend, let connection, let binding = snapshot?.binding else { return }
        let text = draft
        isSending = true
        defer { isSending = false }
        let submission = AgentChatSubmission(binding: binding, submissionID: UUID().uuidString, text: text)
        switch await connection.submit(submission) {
        case .accepted:
            // Only the text that was sent is cleared; later typing stays.
            if draft == text { draft = "" }
            notice = nil
        case .uncertain:
            notice = "The agent may have received this message. Check the conversation before sending it again."
        case .rejected(let reason):
            notice = Self.message(for: reason)
        }
    }

    public func answer(_ request: AgentChatPendingRequest, _ decision: AgentChatDecision) async {
        guard let connection, let binding = snapshot?.binding else { return }
        if await connection.answer(binding, request.id, decision) {
            notice = nil
        } else {
            notice = "That request was already answered, or this device is not in control."
        }
    }

    private static func message(for reason: AgentChatRejection) -> String {
        switch reason {
        case .busy: "The agent is working. Send this when the turn finishes."
        case .ended: "This conversation has ended."
        case .staleBinding: "The agent moved to another conversation. Reopen Chat to continue."
        case .notController: "Another device controls this agent. Take control to send."
        case .unavailable: "The agent could not be reached. Your message was not sent."
        }
    }
}

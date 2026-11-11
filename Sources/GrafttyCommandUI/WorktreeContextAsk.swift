import GrafttyProtocol
import Observation
import SwiftUI

/// An answer picked or typed in Context, for the agent that asked.
public struct AttentionAnswer: Sendable {
    public let worktree: WorktreePanes
    /// The asking agent's pane session.
    public let paneID: String
    /// The question being answered, so the host can refuse a stale answer.
    public let occurrence: SidebarAttentionOccurrence
    public let text: String

    /// The management request that delivers this answer on the asking agent's host.
    public var request: WorktreeManagementRequest {
        .answerRequest(worktreeID: worktree.path, paneID: paneID, occurrence: occurrence, text: text)
    }

    /// nil when the host accepted the answer; otherwise what to tell the user.
    public static func failureMessage(for response: WorktreeManagementResponse) -> String? {
        switch response {
        case .ok: return nil
        case .error(let code, let message, _, _):
            // A host from before answer_request can't decode it.
            return code == "malformed-request" ? "Update Graftty on this Mac to answer from here." : message
        default: return "The host couldn't deliver this answer."
        }
    }
}

/// The question waiting for the user, at the end of the Context scroll (CONTEXT-61).
struct WorktreeContextAsk: View {
    /// The pane and question an answer goes to.
    struct Target: Equatable {
        let worktree: WorktreePanes
        let paneID: String
        var occurrence: SidebarAttentionOccurrence

        // Snapshots refresh constantly; only a different question resets the ask.
        static func == (lhs: Target, rhs: Target) -> Bool {
            lhs.worktree.path == rhs.worktree.path && lhs.paneID == rhs.paneID && lhs.occurrence == rhs.occurrence
        }
    }

    /// What the ask block offers for this kind of question.
    struct Affordances {
        let question: String?
        let options: [AttentionRecap.Option]
        let catchUp: String?
        /// Set only when this client can type an answer into a stopped agent.
        let target: Target?
        var showsReply: Bool { target != nil }
        var answerInTerminal: Bool { target == nil }

        init(_ context: SidebarWorktreeContext, canSend: Bool) {
            question = context.question
            options = context.questionOptions
            catchUp = context.questionCatchUp
            if canSend, context.questionIsStoppedTurn, let paneID = context.questionPaneID,
               let occurrence = context.questionOccurrence {
                target = Target(worktree: context.worktree, paneID: paneID, occurrence: occurrence)
            } else {
                target = nil
            }
        }
    }

    let context: SidebarWorktreeContext
    let secondary: Color
    @Environment(\.worktreeContextActions) private var actions
    @State private var model = WorktreeContextAskModel()
    @State private var reply = ""
    @State private var showsCatchUp = false

    var body: some View {
        let ask = Affordances(context, canSend: actions?.answerQuestion != nil)
        if let question = ask.question {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Waiting for you").font(.caption).fontWeight(.semibold).foregroundStyle(.orange)
                    Text(question).font(.title3).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                }
                if !ask.options.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(ask.options, id: \.label) { option in optionRow(option, enabled: ask.target != nil) }
                    }
                }
                if let catchUp = ask.catchUp {
                    Button {
                        showsCatchUp.toggle()
                    } label: {
                        HStack {
                            Text("Why this is being asked")
                            Spacer(minLength: 8)
                            Image(systemName: showsCatchUp ? "chevron.up" : "chevron.down").font(.caption2)
                        }
                        .font(.callout).foregroundStyle(secondary)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("worktree.context.ask.why")
                    if showsCatchUp {
                        Text(catchUp).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if ask.showsReply {
                    HStack(spacing: 8) {
                        TextField(ask.options.isEmpty ? "Reply" : "Or reply", text: $reply)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { send(reply, clearsReply: true) }
                            .accessibilityIdentifier("worktree.context.ask.reply")
                        Button("Send") { send(reply, clearsReply: true) }
                            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .disabled(!model.acceptsAnswer)
                }
                status(ask)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("worktree.context.ask")
            // Keyed by the whole target, so a re-resolved pane for the same question is used.
            .task(id: ask.target) { model.sync(ask.target) }
        }
    }

    private func optionRow(_ option: AttentionRecap.Option, enabled: Bool) -> some View {
        Button {
            send(option.label, clearsReply: false)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.callout).fontWeight(.semibold)
                    if let cost = option.cost {
                        Text(cost).font(.caption).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if option.suggested == true { Text("Suggested").font(.caption).foregroundStyle(secondary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(secondary.opacity(option.suggested == true ? 0.6 : 0.3), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || !model.acceptsAnswer)
        .accessibilityHint(enabled ? "Sends this answer to the agent" : "")
        .accessibilityIdentifier("worktree.context.ask.option.\(option.label)")
    }

    @ViewBuilder private func status(_ ask: Affordances) -> some View {
        Group {
            if ask.answerInTerminal {
                Text("Answer in the agent's terminal.")
            } else {
                switch model.state {
                case .idle: EmptyView()
                case .sending: Text("Sending…")
                case .sent: Text("Sent")
                case .failed(let message): Text(message)
                }
            }
        }
        .font(.caption).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func send(_ text: String, clearsReply: Bool) {
        guard let answer = actions?.answerQuestion else { return }
        Task {
            await model.send(text, using: answer)
            if clearsReply, model.state == .sent { reply = "" }
        }
    }
}

/// Sending state for one question: idle, sending, sent until the question changes,
/// or failed with the host's message and ready to try again (CONTEXT-62).
@MainActor @Observable
final class WorktreeContextAskModel {
    enum State: Equatable { case idle, sending, sent, failed(String) }

    private(set) var state: State = .idle
    private var target: WorktreeContextAsk.Target?

    var acceptsAnswer: Bool { state != .sending && state != .sent }

    func sync(_ target: WorktreeContextAsk.Target?) {
        guard target != self.target else { return }
        self.target = target
        state = .idle
    }

    func send(_ text: String, using send: @MainActor (AttentionAnswer) async -> String?) async {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target, acceptsAnswer, !line.isEmpty else { return }
        state = .sending
        let failure = await send(AttentionAnswer(worktree: target.worktree, paneID: target.paneID,
                                                 occurrence: target.occurrence, text: line))
        // A newer question arrived while this answer was in flight.
        guard self.target == target else { return }
        state = failure.map(State.failed) ?? .sent
    }

}

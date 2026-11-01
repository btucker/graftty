import GrafttyCommandUI
import GrafttyProtocol

/// @spec IOS-4.55
/// The phone worktree screen lists agents as cards ordered by who needs the
/// user, then working, idle, failed, and finished agents. Shells follow as a
/// plain list. A one-line purpose comes from the worktree brief.
struct MobileWorktreeOverview: Equatable {
    enum State: Int, Comparable {
        case needsInput, working, idle, failed, finished
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Agent: Equatable, Identifiable {
        var id: String { session }
        let session: String
        let title: String
        let provider: String
        let state: State
        let status: AgentAssignmentStatus
        /// The question or last-turn recap, or the result or failure once it
        /// finishes. The title already carries live terminal activity.
        let message: String?
        let info: AgentSessionInfo
    }

    struct Terminal: Equatable, Identifiable {
        var id: String { session }
        let session: String
        let title: String
    }

    let purpose: String?
    let agents: [Agent]
    let terminals: [Terminal]

    @MainActor init(worktree: WorktreePanes, context: SidebarWorktreeContext? = nil) {
        let leaves = worktree.layout?.leaves ?? []
        let cards: [Agent] = (worktree.agents ?? []).compactMap { info in
            guard let session = info.presentationSessionName else { return nil }
            let leaf = leaves.first { $0.sessionName == session }
            let needsInput = context?.needsInput(session: session) ?? (leaf?.attentionSource == .agentStop)
            let status = AgentAssignmentStatus(agent: info, needsInput: needsInput)
            let state: State
            let message: String?
            switch status {
            case _ where info.isCompleted:
                state = info.failure == nil ? .finished : .failed
                message = info.failure ?? info.result
            case .failed, .interrupted, .exited, .disconnected:
                state = .failed
                message = info.failure ?? status.label
            case .waiting:
                state = .needsInput
                message = leaf?.attentionText ?? context?.question
            case .running, .starting:
                state = leaf?.isBusy == false ? .idle : .working
                message = leaf?.attentionText
            default:
                state = .idle
                message = leaf?.attentionText
            }
            return Agent(session: session, title: worktree.workspaceSessionTitle(session), provider: info.provider,
                         state: state, status: status, message: message?.trimmedNonEmpty, info: info)
        }
        // Stable within a state: keep the host's agent order.
        agents = cards.enumerated().sorted { ($0.element.state, $0.offset) < ($1.element.state, $1.offset) }.map(\.element)
        terminals = CompactTerminalPresentation.terminals(in: worktree).map {
            Terminal(session: $0.sessionName, title: $0.displayTitle)
        }
        purpose = Self.purpose(worktree.sidebar?.brief ?? context?.brief)
    }

    private static func purpose(_ brief: WorktreeBrief?) -> String? {
        guard let brief else { return nil }
        let parts = [brief.title, brief.context].compactMap { $0?.trimmedNonEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

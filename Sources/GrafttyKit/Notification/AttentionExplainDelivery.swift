import Foundation
import GrafttyProtocol

/// Explain more on a client becomes an ordinary send-pane request on the host,
/// so both the Mac and headless hosts type into the pane the way `graftty pane send` does.
/// @spec AGENT-3.40: When a client asks a host to explain a stopped agent's question, the host shall type the catch-up prompt into that agent's pane and submit it, and shall refuse a pane it cannot find or one waiting at its harness's own prompt.
public enum AttentionExplainDelivery {
    /// Reads the platform's live state, so the pane index and the send it
    /// addresses come from the same main-actor turn.
    @MainActor
    public static func deliver(worktreeID: String, paneID: String,
                               platform: any ControlPlatform) async -> WorktreeManagementResponse {
        await AttentionPaneInput.submit(AttentionExplainPrompt.text, worktreeID: worktreeID, paneID: paneID, platform: platform)
    }
}

/// An answer picked or typed in Context becomes one submitted line in the
/// asking agent's pane, only while its question is still the one pending.
/// @spec AGENT-3.50
public enum AttentionAnswerDelivery {
    public static let maxLength = 2000

    /// A line break would submit early and other control keys (Tab, Escape,
    /// Ctrl-C) would act on the agent's input, so each becomes a word break.
    /// Format characters such as an emoji's zero-width joiner are kept.
    private static let breaks: CharacterSet = {
        var set = CharacterSet.newlines
        set.insert(charactersIn: Unicode.Scalar(UInt8(0x00))...Unicode.Scalar(UInt8(0x1F)))
        set.insert(charactersIn: Unicode.Scalar(UInt8(0x7F))...Unicode.Scalar(UInt8(0x9F)))
        return set
    }()

    @MainActor
    public static func deliver(worktreeID: String, paneID: String, occurrence: SidebarAttentionOccurrence, text: String,
                               platform: any ControlPlatform) async -> WorktreeManagementResponse {
        let worktree = platform.state.worktree(forPath: worktreeID)
        guard let stop = worktree?.unseenAgentStop, stop.question != nil, stop.occurrence == occurrence else {
            return .error(code: "occurrence-changed", message: "This request has changed or already cleared.", forceAllowed: false, shortStatus: nil)
        }
        // Only the agent that asked reads the answer; another pane may be a shell that would run it.
        // An agent that stopped outside any Graftty pane has no pane to verify, so it is refused too.
        guard let asker = stop.paneSlotID else {
            return .error(code: "not-found", message: "This agent isn't in a Graftty pane. Answer in its terminal.", forceAllowed: false, shortStatus: nil)
        }
        guard worktree?.paneSlot(forSessionName: paneID)?.id.uuidString == asker else {
            return .error(code: "not-found", message: "This agent's pane is no longer open.", forceAllowed: false, shortStatus: nil)
        }
        let line = text.components(separatedBy: breaks).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !line.isEmpty else {
            return .error(code: "empty-answer", message: "Type an answer first.", forceAllowed: false, shortStatus: nil)
        }
        return await AttentionPaneInput.submit(String(line.prefix(maxLength)), worktreeID: worktreeID, paneID: paneID, platform: platform)
    }
}

/// Typing into a stopped agent goes through the same send-pane request as `graftty pane send`.
enum AttentionPaneInput {
    @MainActor
    static func submit(_ text: String, worktreeID: String, paneID: String,
                       platform: any ControlPlatform) async -> WorktreeManagementResponse {
        guard let worktree = platform.state.worktree(forPath: worktreeID),
              let slot = worktree.paneSlot(forSessionName: paneID),
              let index = worktree.splitTree.allLeaves.firstIndex(of: slot) else {
            return .error(code: "not-found", message: "This agent's pane is no longer open.", forceAllowed: false, shortStatus: nil)
        }
        // A permission or question prompt owns the input: Enter would answer it.
        guard worktree.paneAttention[slot]?.source != .agentStop else {
            return .error(code: "agent-prompting", message: "This agent is waiting at a prompt. Open it to answer.", forceAllowed: false, shortStatus: nil)
        }
        let message = NotificationMessage.sendPane(path: worktreeID, index: index + 1, text: text, pressEnter: true)
        switch await platform.handlePlatformRequest(message) {
        case .ok?: return .ok
        case .error(let message)?:
            return .error(code: "explain-failed", message: message, forceAllowed: false, shortStatus: nil)
        default:
            return .error(code: "explain-failed", message: "The host couldn't type into this pane.", forceAllowed: false, shortStatus: nil)
        }
    }
}

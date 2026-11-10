import Foundation
import GrafttyProtocol

/// @spec LAYOUT-2.216
/// What dismissing a row's request is called, and when a row's menu offers it,
/// on every client.
public enum SidebarAttentionDismissal {
    public static let title = "Dismiss Request"

    public static func isAvailable(_ context: SidebarWorktreeContext) -> Bool {
        !context.pending.isEmpty || unseenStop(in: context) != nil
    }

    /// A finished turn nobody has opened waits in Needs you too, so Dismiss
    /// clears it like a request.
    static func unseenStop(in context: SidebarWorktreeContext) -> SidebarAgentStop? {
        context.hasUnseenStop ? context.worktree.sidebar?.unseenAgentStop : nil
    }

    /// LAYOUT-2.218: what retires each request on its owning host, so every
    /// client stops showing it. A host without exact acknowledgement gets none,
    /// because the legacy form can clear a request the user hasn't seen.
    public static func requests(for context: SidebarWorktreeContext,
                                supportsExactAcknowledgement: Bool) -> [WorktreeManagementRequest] {
        var requests = context.pending.compactMap {
            SidebarInteractionPolicy.acknowledgement(for: $0, supportsExactAcknowledgement: supportsExactAcknowledgement)
        }
        if supportsExactAcknowledgement, let stop = unseenStop(in: context) {
            let request = WorktreeManagementRequest.acknowledgeOccurrence(worktreeID: context.worktree.path, paneID: nil,
                                                                          occurrence: stop.occurrence)
            if !requests.contains(request) { requests.append(request) }
        }
        return requests
    }

    /// Sends each request in turn and stops at the first failure. A request that
    /// already changed or cleared isn't one: nothing is left to dismiss. Returns
    /// the host's message for a failure, or nil when every request landed.
    @MainActor
    public static func retire(_ requests: [WorktreeManagementRequest],
                              send: (WorktreeManagementRequest) async throws -> WorktreeManagementResponse) async throws -> String? {
        for request in requests {
            if case .error(let code, let message, _, _) = try await send(request), code != "occurrence-changed" { return message }
        }
        return nil
    }
}

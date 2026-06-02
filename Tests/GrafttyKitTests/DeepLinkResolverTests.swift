import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("@spec URL-1.3: Given the tracked repos, the application shall resolve a deep-link target to a worktree path (and, for a session target, the owning pane slot), or report which part was unknown.")
struct DeepLinkResolverTests {
    private let slot = PaneSlotID()
    private let session = PaneSessionID()

    private func repos() -> [RepoEntry] {
        // worktree "/wt/url-handler" branch "url-handler" with session recorded for slot;
        // worktree "/wt/main" branch "main" no sessions; wrap in RepoEntry displayName "graftty".
        var urlHandlerWt = WorktreeEntry(path: "/wt/url-handler", branch: "url-handler", state: .running)
        urlHandlerWt.recordPaneSession(session, for: slot)

        let mainWt = WorktreeEntry(path: "/wt/main", branch: "main", state: .running)

        let repo = RepoEntry(
            path: "/wt/main",
            displayName: "graftty",
            worktrees: [urlHandlerWt, mainWt]
        )
        return [repo]
    }

    @Test("session resolves to worktree + owning pane slot")
    func sessionResolves() {
        let name = ZmxLauncher.sessionName(for: session)
        #expect(DeepLinkResolver.resolve(.session(name), inRepos: repos())
            == .resolved(worktreePath: "/wt/url-handler", paneSlot: slot))
    }

    @Test("worktree form resolves to path with nil pane slot")
    func worktreeResolves() {
        #expect(DeepLinkResolver.resolve(.worktree(repo: "graftty", worktree: "url-handler"), inRepos: repos())
            == .resolved(worktreePath: "/wt/url-handler", paneSlot: nil))
    }

    @Test("unknown session reported")
    func unknownSession() {
        #expect(DeepLinkResolver.resolve(.session("graftty-zzzz9999"), inRepos: repos()) == .notFound(.unknownSession))
    }

    @Test("unknown repo reported")
    func unknownRepo() {
        #expect(DeepLinkResolver.resolve(.worktree(repo: "nope", worktree: "url-handler"), inRepos: repos()) == .notFound(.unknownRepo))
    }

    @Test("known repo, unknown worktree reported")
    func unknownWorktree() {
        #expect(DeepLinkResolver.resolve(.worktree(repo: "graftty", worktree: "nope"), inRepos: repos()) == .notFound(.unknownWorktree))
    }
}

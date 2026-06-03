import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("@spec URL-1.1: The application shall parse a graftty://open URL into a worktree-or-session deep-link target, accepting a session name, a repo+worktree pair, and preferring the session when both are present.")
struct GrafttyDeepLinkParseTests {

    @Test("session form")
    func parsesSessionForm() {
        let url = URL(string: "graftty://open?session=graftty-ab12cd34")!
        #expect(GrafttyDeepLink.parse(url) == .session("graftty-ab12cd34"))
    }

    @Test("worktree form")
    func parsesWorktreeForm() {
        let url = URL(string: "graftty://open?repo=graftty&worktree=url-handler")!
        #expect(GrafttyDeepLink.parse(url) == .worktree(repo: "graftty", worktree: "url-handler"))
    }

    @Test("session wins when both present")
    func sessionWinsWhenBothPresent() {
        let url = URL(string: "graftty://open?session=graftty-ab12cd34&repo=graftty&worktree=url-handler")!
        #expect(GrafttyDeepLink.parse(url) == .session("graftty-ab12cd34"))
    }

    @Test("worktree name is sanitized to the canonical address form")
    func worktreeNameIsSanitized() {
        // "feature foo!" sanitizes to "feature-foo-" (WorktreeNameSanitizer).
        let url = URL(string: "graftty://open?repo=graftty&worktree=feature%20foo!")!
        #expect(GrafttyDeepLink.parse(url) == .worktree(repo: "graftty", worktree: "feature-foo-"))
    }

    @Test("rejects non-open host")
    func rejectsNonOpenHost() {
        #expect(GrafttyDeepLink.parse(URL(string: "graftty://close?session=graftty-ab12cd34")!) == nil)
    }

    @Test("rejects wrong scheme")
    func rejectsWrongScheme() {
        #expect(GrafttyDeepLink.parse(URL(string: "https://open?session=graftty-ab12cd34")!) == nil)
    }

    @Test("nil when no usable params")
    func nilWhenNoUsableParams() {
        #expect(GrafttyDeepLink.parse(URL(string: "graftty://open")!) == nil)
    }

    @Test("nil when worktree present without repo")
    func nilWhenWorktreeWithoutRepo() {
        #expect(GrafttyDeepLink.parse(URL(string: "graftty://open?worktree=url-handler")!) == nil)
    }

    @Test("nil when repo present without worktree")
    func nilWhenRepoWithoutWorktree() {
        #expect(GrafttyDeepLink.parse(URL(string: "graftty://open?repo=graftty")!) == nil)
    }

    @Test("empty session value is not a target")
    func emptySessionIsNil() {
        #expect(GrafttyDeepLink.parse(URL(string: "graftty://open?session=")!) == nil)
    }
}

@Suite("@spec URL-1.2: Given a worktree-panes snapshot, the application shall resolve a deep-link target to a worktree path (and, for a session target, the matching pane session name), or report which part was unknown.")
struct GrafttyDeepLinkSnapshotResolveTests {

    /// Build a two-worktree snapshot for repo "graftty":
    ///   - "/wt/url-handler" branch "url-handler" with panes graftty-aaaa1111 + graftty-bbbb2222
    ///   - "/wt/main" branch "main" with pane graftty-cccc3333
    private func snapshot() -> [WorktreePanes] {
        let urlHandlerLayout = PaneLayoutNode.split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(sessionName: "graftty-aaaa1111", title: "zsh", attentionText: nil, isBusy: false, attentionSource: nil),
            right: .leaf(sessionName: "graftty-bbbb2222", title: "zsh", attentionText: nil, isBusy: false, attentionSource: nil)
        )
        let mainLayout = PaneLayoutNode.leaf(
            sessionName: "graftty-cccc3333",
            title: "zsh",
            attentionText: nil,
            isBusy: false,
            attentionSource: nil
        )
        return [
            WorktreePanes(
                path: "/wt/url-handler",
                displayName: "url-handler",
                repoDisplayName: "graftty",
                displayBranch: "url-handler",
                state: .running,
                isMainCheckout: false,
                prBadge: nil,
                stats: nil,
                attentionText: nil,
                layout: urlHandlerLayout
            ),
            WorktreePanes(
                path: "/wt/main",
                displayName: "main",
                repoDisplayName: "graftty",
                displayBranch: "main",
                state: .running,
                isMainCheckout: true,
                prBadge: nil,
                stats: nil,
                attentionText: nil,
                layout: mainLayout
            ),
        ]
    }

    @Test("session resolves to its worktree + session name")
    func sessionResolves() {
        #expect(GrafttyDeepLink.resolve(.session("graftty-bbbb2222"), inSnapshot: snapshot())
            == .resolved(worktreePath: "/wt/url-handler", sessionName: "graftty-bbbb2222"))
    }

    @Test("worktree form resolves to path with nil session")
    func worktreeResolves() {
        #expect(GrafttyDeepLink.resolve(.worktree(repo: "graftty", worktree: "url-handler"), inSnapshot: snapshot())
            == .resolved(worktreePath: "/wt/url-handler", sessionName: nil))
    }

    @Test("unknown session reported")
    func unknownSession() {
        #expect(GrafttyDeepLink.resolve(.session("graftty-zzzz9999"), inSnapshot: snapshot()) == .notFound(.unknownSession))
    }

    @Test("unknown repo reported")
    func unknownRepo() {
        #expect(GrafttyDeepLink.resolve(.worktree(repo: "nope", worktree: "url-handler"), inSnapshot: snapshot()) == .notFound(.unknownRepo))
    }

    @Test("known repo, unknown worktree reported")
    func unknownWorktree() {
        #expect(GrafttyDeepLink.resolve(.worktree(repo: "graftty", worktree: "nope"), inSnapshot: snapshot()) == .notFound(.unknownWorktree))
    }
}

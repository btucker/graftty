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

    @Test("empty session value is not a target")
    func emptySessionIsNil() {
        #expect(GrafttyDeepLink.parse(URL(string: "graftty://open?session=")!) == nil)
    }
}

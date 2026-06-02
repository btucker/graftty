import Testing
@testable import GrafttyKit
@testable import GrafttyCLI

@Suite("NotifyTarget — graftty notify target grammar maps flags/env to pane- or worktree-scoped messages.")
struct NotifyTargetTests {
    @Test("""
    @spec AGENT-4.1: When `graftty notify` is given `--session <zmx-session>`, the application shall target that pane's attention overlay.
    """)
    func sessionFlagTargetsPane() throws {
        let msg = try NotifyTarget.message(
            text: "done", session: "graftty-aaaa1111", worktree: nil,
            env: [:], resolveWorktreePath: { "/wt" })
        #expect(msg == .notify(path: "/wt", text: "done", clearAfter: nil,
                               paneSessionName: "graftty-aaaa1111"))
    }

    @Test("""
    @spec AGENT-4.2: When `graftty notify` is given no target and `$ZMX_SESSION` is set, the application shall target the caller's pane.
    """)
    func envTargetsCallerPane() throws {
        let msg = try NotifyTarget.message(
            text: "done", session: nil, worktree: nil,
            env: ["ZMX_SESSION": "graftty-bbbb2222"], resolveWorktreePath: { "/wt" })
        #expect(msg == .notify(path: "/wt", text: "done", clearAfter: nil,
                               paneSessionName: "graftty-bbbb2222"))
    }

    @Test("""
    @spec AGENT-4.3: When `graftty notify` is given no target and `$ZMX_SESSION` is unset, the application shall target the current worktree (unchanged behavior).
    """)
    func noTargetStaysWorktree() throws {
        let msg = try NotifyTarget.message(
            text: "done", session: nil, worktree: nil,
            env: [:], resolveWorktreePath: { "/wt" })
        #expect(msg == .notify(path: "/wt", text: "done", clearAfter: nil, paneSessionName: nil))
    }

    @Test("""
    @spec AGENT-4.4: If `graftty notify` is given both `--session` and `--worktree`, then the application shall reject the invocation with a validation error.
    """)
    func sessionAndWorktreeConflict() {
        #expect(throws: NotifyTargetError.conflictingTargets) {
            _ = try NotifyTarget.message(
                text: "done", session: "graftty-aaaa1111", worktree: "other",
                env: [:], resolveWorktreePath: { "/wt" })
        }
    }
}

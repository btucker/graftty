// Tests/GrafttyTests/Specs/PushTodo.swift
import Testing

@Suite("PUSH — pending specs")
struct PushTodo {
    @Test("""
@spec PUSH-4.1: When the user taps an iOS alert banner, the application shall decode the `userInfo` as `AgentStopNotificationPayload` and reconstruct the navigation stack to `[HostPicker → WorktreePicker(host) → WorktreeDetail(worktreePath) → TerminalPane(sessionID)]`.
""", .disabled("not yet implemented"))
    func push_4_1() async throws { }

    @Test("""
@spec PUSH-4.2: When the iOS app is locked (IOS-3.1), the deep-link target shall be queued and applied only after Face ID/Touch ID resolves successfully.
""", .disabled("not yet implemented"))
    func push_4_2() async throws { }

}

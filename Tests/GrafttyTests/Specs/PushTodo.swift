// Tests/GrafttyTests/Specs/PushTodo.swift
import Testing

@Suite("PUSH — pending specs")
struct PushTodo {
    @Test("""
@spec PUSH-1.1: When the iOS user adds a host or the application foregrounds with hosts already saved, the application shall POST `{deviceToken, deviceName, platform:"ios"}` to `<host>/push/register` for every saved host whose `lastUsedAt` is within 90 days.
""", .disabled("not yet implemented"))
    func push_1_1() async throws { }

    @Test("""
@spec PUSH-1.2: If the iOS user denies notification authorization, the application shall not call `registerForRemoteNotifications()` and shall not POST `/push/register`.
""", .disabled("not yet implemented"))
    func push_1_2() async throws { }

    @Test("""
@spec PUSH-4.1: When the user taps an iOS alert banner, the application shall decode the `userInfo` as `AgentStopNotificationPayload` and reconstruct the navigation stack to `[HostPicker → WorktreePicker(host) → WorktreeDetail(worktreePath) → TerminalPane(sessionID)]`.
""", .disabled("not yet implemented"))
    func push_4_1() async throws { }

    @Test("""
@spec PUSH-4.2: When the iOS app is locked (IOS-3.1), the deep-link target shall be queued and applied only after Face ID/Touch ID resolves successfully.
""", .disabled("not yet implemented"))
    func push_4_2() async throws { }

    @Test("""
@spec PUSH-5.2: When iOS receives a remote notification with `userInfo.kind == "agent_stop_clear"`, the application shall call `UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [userInfo.collapse_id])`.
""", .disabled("not yet implemented"))
    func push_5_2() async throws { }

}

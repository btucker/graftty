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
@spec PUSH-1.3: The Mac shall persist device registrations at `~/Library/Application Support/Graftty/push-devices.json` as `[{token, deviceName, platform, lastRegisteredAt}]`, written atomically on each mutation; records with `lastRegisteredAt > 90 days` shall be filtered out on read.
""", .disabled("not yet implemented"))
    func push_1_3() async throws { }

    @Test("""
@spec PUSH-2.1: When `recordAgentStop` fires and `DesktopActivityMonitor.isUserActiveOnDesktop == false`, the application shall send an APNs alert push to every live registered device.
""", .disabled("not yet implemented"))
    func push_2_1() async throws { }

    @Test("""
@spec PUSH-2.2: When `recordAgentStop` fires and `isUserActiveOnDesktop == true`, the application shall not send an APNs push.
""", .disabled("not yet implemented"))
    func push_2_2() async throws { }

    @Test("""
@spec PUSH-2.3: The application shall set `isUserActiveOnDesktop == true` iff the system is not sleeping, the screen is not locked, and `CGEventSourceSecondsSinceLastEventType(.combinedSessionState, .anyInputEventType) < 60`.
""", .disabled("not yet implemented"))
    func push_2_3() async throws { }

    @Test("""
@spec PUSH-2.4: When the same `(worktreePath, attentionTimestamp)` is observed more than once within a process lifetime, the application shall send at most one alert push.
""", .disabled("not yet implemented"))
    func push_2_4() async throws { }

    @Test("""
@spec PUSH-3.1: The APNs alert envelope shall use `apns-topic: com.quotably.graftty`, `apns-push-type: alert`, `apns-collapse-id: "<worktreePath>:<attentionTimestampISO>"`, and a `userInfo` payload matching `AgentStopNotification.content(...).userInfo`.
""", .disabled("not yet implemented"))
    func push_3_1() async throws { }

    @Test("""
@spec PUSH-3.2: The application shall sign APNs JWTs with ES256 using a `.p8` bundled in Graftty.app at `Resources/apns/AuthKey_<KEYID>.p8`; the same JWT shall be cached for up to 50 minutes before being re-signed.
""", .disabled("not yet implemented"))
    func push_3_2() async throws { }

    @Test("""
@spec PUSH-4.1: When the user taps an iOS alert banner, the application shall decode the `userInfo` as `AgentStopNotificationPayload` and reconstruct the navigation stack to `[HostPicker → WorktreePicker(host) → WorktreeDetail(worktreePath) → TerminalPane(sessionID)]`.
""", .disabled("not yet implemented"))
    func push_4_1() async throws { }

    @Test("""
@spec PUSH-4.2: When the iOS app is locked (IOS-3.1), the deep-link target shall be queued and applied only after Face ID/Touch ID resolves successfully.
""", .disabled("not yet implemented"))
    func push_4_2() async throws { }

    @Test("""
@spec PUSH-5.1: When `clearAttentionIfTimestamp(_:_:)` fires on the Mac for a worktree+timestamp that was previously pushed, the application shall send a silent APNs push (`apns-push-type: background`, `aps.content-available: 1`, no `aps.alert`) with the same `apns-collapse-id` as the original alert push.
""", .disabled("not yet implemented"))
    func push_5_1() async throws { }

    @Test("""
@spec PUSH-5.2: When iOS receives a remote notification with `userInfo.kind == "agent_stop_clear"`, the application shall call `UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [userInfo.collapse_id])`.
""", .disabled("not yet implemented"))
    func push_5_2() async throws { }

    @Test("""
@spec PUSH-6.1: When APNs returns `400 BadDeviceToken` or `410 Unregistered` for a device, the application shall remove the matching record from `PushDeviceStore`.
""", .disabled("not yet implemented"))
    func push_6_1() async throws { }

    @Test("""
@spec PUSH-6.2: When APNs returns `BadDeviceToken` for every device in the fanout of a single attention event sent to `api.push.apple.com`, the application shall retry the same fanout against `api.sandbox.push.apple.com` and cache the working endpoint in memory for the rest of the process lifetime.
""", .disabled("not yet implemented"))
    func push_6_2() async throws { }
}

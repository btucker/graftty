# Push Notifications to GrafttyMobile — Design

Date: 2026-05-13
Branch: `push-notifications`
Status: Design, awaiting user review

## Problem

Today, when an agent runtime (Claude or Codex) needs the user's input, Graftty on the Mac fires a local `UNUserNotificationCenter` banner via `AgentNotificationRouter.post` (`Sources/Graftty/GrafttyApp.swift:72`). If the user is away from the Mac — phone in pocket, in a meeting, walking the dog — the banner is invisible. GrafttyMobile already mirrors per-worktree attention state into its UI (`WorktreePickerView` shows the `AttentionCapsule` next to the row) but it only does so while the app is foregrounded and connected. There is no way for the iOS device to ring/buzz when an agent stops needing input.

We want push notifications delivered to GrafttyMobile on iOS, but only when the user is *not* actively at the desktop. If the user is in front of the Mac, the macOS banner is sufficient — phone push would be redundant noise.

## Goals

- Deliver an iOS banner to every registered GrafttyMobile device within a few seconds of an agent stop that needs attention.
- Suppress the iOS push when the user is demonstrably present at the Mac (awake + unlocked + recent input).
- Tap-to-route: opening the banner drills directly into the pane that's waiting.
- Auto-clear: if the user handles the attention on the Mac, the iOS banner disappears.
- Zero per-user setup beyond installing GrafttyMobile and granting iOS notification permission.

## Non-goals

- Push for other event classes (PR status, build completions, OSC desktop notifications, generic CLI `notify`). `IOS-8.5` continues to forbid those in v1.
- A Graftty cloud / backend service. Each user's Mac talks directly to APNs; tokens are stored locally per Mac.
- Customizable push filters or per-worktree mute toggles. v1 is "always push when not active, otherwise silent."
- Cross-Mac coordination. If the user has two Macs running Graftty, each independently pushes for its own attention events. Two Macs blocked on the same iPhone is acceptable; banner body shows the worktree name so the user can tell them apart.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Mac (Graftty.app)                                                       │
│                                                                          │
│   recordAgentStop(...)  ──►  AttentionPushDecider                        │
│   (existing)                  │                                          │
│                               │ "should we push?" (active-on-desktop?)   │
│                               ▼                                          │
│                          ApnsClient ──HTTPS/2──►  api.push.apple.com     │
│                               ▲                                          │
│                               │ reads .p8 from bundle resources          │
│                               │ reads device tokens from PushDeviceStore │
│                                                                          │
│   /push/register endpoint  ◄── HTTPS over Tailscale ── iOS GrafttyMobile │
│                                                                          │
│   DesktopActivityMonitor   (CGEvent idle + IOPM sleep + screen-lock)     │
└──────────────────────────────────────────────────────────────────────────┘
                                                  │
                                                  ▼
                                          ┌───────────────────┐
                                          │ iOS GrafttyMobile │
                                          │                   │
                                          │  PushRegistrar    │
                                          │  PushReceiver     │
                                          │  DeepLinkRouter   │
                                          └───────────────────┘
```

The Mac plays the role of the APNs application server. The bundled `.p8` auth key lets it mint ES256-signed JWTs and POST alert payloads to Apple's gateway over HTTP/2. The iOS app's device token reaches the Mac via a new `/push/register` HTTPS endpoint, gated by Tailnet membership like every other Graftty endpoint.

The desktop-suppression logic is intentionally Mac-side: only the Mac can authoritatively report whether the human is sitting in front of it. iOS has no input into the suppression decision.

## Spec IDs

This work introduces a new `PUSH-` section in `SPECS.md` and updates one existing spec.

### Updated

- `IOS-8.5`: Narrow to "The v1 iOS app shall not use push notifications for PR status, build completions, or session events other than the agent-attention notifications defined in PUSH-1..6."

### New

**PUSH-1 — Registration**

- `PUSH-1.1`: When the iOS user adds a host or the application foregrounds with hosts already saved, the application shall POST `{deviceToken, deviceName, platform:"ios"}` to `<host>/push/register` for every saved host whose `lastUsedAt` is within 90 days.
- `PUSH-1.2`: If the iOS user denies notification authorization, the application shall not call `registerForRemoteNotifications()` and shall not POST `/push/register`.
- `PUSH-1.3`: The Mac shall persist device registrations at `~/Library/Application Support/Graftty/push-devices.json` as `[{token, deviceName, platform, lastRegisteredAt}]`, written atomically on each mutation; records with `lastRegisteredAt > 90 days` shall be filtered out on read.

**PUSH-2 — Trigger & suppression**

- `PUSH-2.1`: When `recordAgentStop` fires and `DesktopActivityMonitor.isUserActiveOnDesktop == false`, the application shall send an APNs alert push to every live registered device.
- `PUSH-2.2`: When `recordAgentStop` fires and `isUserActiveOnDesktop == true`, the application shall not send an APNs push.
- `PUSH-2.3`: The application shall set `isUserActiveOnDesktop == true` iff the system is not sleeping, the screen is not locked, and `CGEventSourceSecondsSinceLastEventType(.combinedSessionState, .anyInputEventType) < 60`.
- `PUSH-2.4`: When the same `(worktreePath, attentionTimestamp)` is observed more than once within a process lifetime, the application shall send at most one alert push.

**PUSH-3 — Envelope shape**

- `PUSH-3.1`: The APNs alert envelope shall use `apns-topic: com.quotably.graftty`, `apns-push-type: alert`, `apns-collapse-id: "<worktreePath>:<attentionTimestampISO>"`, and a `userInfo` payload matching `AgentStopNotification.content(...).userInfo` (`kind=agent_stop`, `runtime`, `worktree_path`, `session_id`, `attention_timestamp`).
- `PUSH-3.2`: The application shall sign APNs JWTs with ES256 using a `.p8` bundled in Graftty.app at `Resources/apns/AuthKey_<KEYID>.p8`; the same JWT shall be cached for up to 50 minutes before being re-signed.

**PUSH-4 — Tap routing**

- `PUSH-4.1`: When the user taps an iOS alert banner, the application shall decode the `userInfo` as `AgentStopNotificationPayload` and reconstruct the navigation stack to `[HostPicker → WorktreePicker(host) → WorktreeDetail(worktreePath) → TerminalPane(sessionID)]`.
- `PUSH-4.2`: When the iOS app is locked (`IOS-3.1`), the deep-link target shall be queued and applied only after Face ID/Touch ID resolves successfully.

**PUSH-5 — Clearing**

- `PUSH-5.1`: When `clearAttentionIfTimestamp(_:_:)` fires on the Mac for a worktree+timestamp that was previously pushed, the application shall send a silent APNs push (`apns-push-type: background`, `aps.content-available: 1`, no `aps.alert`) with the same `apns-collapse-id` as the original alert push.
- `PUSH-5.2`: When iOS receives a remote notification with `userInfo.kind == "agent_stop_clear"`, the application shall call `UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [userInfo.collapse_id])`.

**PUSH-6 — Stale-token cleanup & environment**

- `PUSH-6.1`: When APNs returns `400 BadDeviceToken` or `410 Unregistered` for a device, the application shall remove the matching record from `PushDeviceStore`.
- `PUSH-6.2`: When APNs returns `BadDeviceToken` for every device in the fanout of a single attention event sent to `api.push.apple.com`, the application shall retry the same fanout against `api.sandbox.push.apple.com` and cache the working endpoint in memory for the rest of the process lifetime.

## Components

### Mac side (new code lives in `Sources/GrafttyKit/Push/` and `Sources/Graftty/Push/`)

**`DesktopActivityMonitor`** (`Sources/GrafttyKit/Push/DesktopActivityMonitor.swift`)
- Public surface: `var isUserActiveOnDesktop: Bool { get }` — synchronous, cheap; reads cached state populated by event subscriptions.
- Subscribes once at app launch to:
  - `DistributedNotificationCenter.default()` for `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`.
  - `NSWorkspace.shared.notificationCenter` for `.willSleepNotification` / `.didWakeNotification`.
  - A 5s `Timer` that calls `CGEventSourceSecondsSinceLastEventType(.combinedSessionState, .anyInputEventType)` and caches `lastInputAgeSeconds`.
- Injectable `DesktopActivitySource` protocol so unit tests drive states directly without touching CoreGraphics.

**`PushDeviceStore`** (`Sources/GrafttyKit/Push/PushDeviceStore.swift`)
- `PushDevice { token: String, deviceName: String, platform: "ios", lastRegisteredAt: Date }` (Codable).
- `register(_:)`, `remove(token:)`, `liveDevices() -> [PushDevice]` (filters `lastRegisteredAt > now - 90d`).
- Atomic temp-file-rename write, mirroring the `hosts.json` pattern from `IOS-2.3`.

**`ApnsClient`** (`Sources/GrafttyKit/Push/ApnsClient.swift`)
- Loads `.p8` from `Bundle.main.url(forResource: "AuthKey_<KEYID>", withExtension: "p8")`. `KEYID`, `TEAMID`, `TOPIC` from Info.plist.
- Caches one ES256 JWT per ~50 minutes via `CryptoKit.P256.Signing.PrivateKey`.
- `send(envelope: ApnsEnvelope, to: PushDevice) async throws -> ApnsResult`. Long-lived `URLSession` configured for HTTP/2 (`HTTPMaximumConnectionsPerHost = 1`).
- Recognizes responses: `200 OK` → success; `400 BadDeviceToken` → caller removes; `403` (`InvalidProviderToken`/`BadCollapseId`) → fatal config error, log once; `410 Unregistered` → caller removes; `429`/`5xx` → one retry with 2s backoff.

**`AttentionPushDecider`** (`Sources/GrafttyKit/Push/AttentionPushDecider.swift`)
- Stateless pure function. `func shouldPush(payload, activity, dedupe) -> Bool` returns true iff `!activity.isUserActiveOnDesktop` AND `dedupe.lastPushed(forWorktree: payload.worktreePath) != payload.attentionTimestamp`.
- Caller (in `recordAgentStop`) is responsible for updating the dedupe store after a successful push.

**`PushDedupeStore`** (`Sources/GrafttyKit/Push/PushDedupeStore.swift`)
- In-memory `[worktreePath: Date]`. Survives only for the lifetime of the process; restart resets. This means: if the Mac restarts between the alert push and the clear push, the clear path is skipped and the iOS banner relies on natural expiry / user dismissal. Acceptable for v1 — the failure mode is a stale banner, not a wrong-target deep-link.

**`PushClearService`** (`Sources/GrafttyKit/Push/PushClearService.swift`)
- Invoked from the same site that runs `clearAttentionIfTimestamp`. When attention clears for a `(worktreePath, attentionTimestamp)` pair previously pushed (looked up via `PushDedupeStore`), sends a silent push with matching `apns-collapse-id`.

**`PushRegisterEndpoint`** (in `Sources/GrafttyKit/Hosting/`)
- `POST /push/register` accepts `{deviceToken, deviceName, platform}`. Tailnet-gated like every other endpoint. Reply: `{registeredAt}`. Calls `PushDeviceStore.register(...)`.

**Trigger integration** — minimal edit to `Sources/Graftty/GrafttyApp.swift`:
- `recordAgentStop` (line 1911) gains a single new call after the existing local-banner post:

  ```swift
  PushOrchestrator.shared.handleAgentStop(
    payload: AgentStopNotificationPayload(runtime: runtime,
                                          worktreePath: worktreePath,
                                          sessionID: sessionID,
                                          attentionTimestamp: timestamp))
  ```

- The site that resolves attention (the `clearAttentionIfTimestamp` callers in `GrafttyApp` and `AgentStopNotification.acknowledgeSelection`) gains a parallel `PushOrchestrator.shared.handleAttentionCleared(...)` call.

**`PushOrchestrator`** (`Sources/Graftty/Push/PushOrchestrator.swift`)
- Thin glue holding singletons of `ApnsClient`, `PushDeviceStore`, `PushDedupeStore`, `DesktopActivityMonitor`, `PushClearService`, `AttentionPushDecider`. Lives in the macOS-app target because it touches `NSWorkspace`. Logic-heavy components stay in `GrafttyKit` so they're testable on plain `swift test`.

### iOS side (new code lives in `Sources/GrafttyMobileKit/Push/`)

**`PushRegistrar`** (`Sources/GrafttyMobileKit/Push/PushRegistrar.swift`)
- `func register() async` — requests `UNUserNotificationCenter` authorization for `[.alert, .sound, .badge]`. On grant, calls `UIApplication.shared.registerForRemoteNotifications()`. Token arrives in `AppDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`, which stashes it on `PushRegistrar.shared.deviceToken`.
- For every host in `HostStore.hosts` filtered by `lastUsedAt > now - 90d`, POSTs `/push/register` with the token. Retries transient failures next foreground; silently logs persistent failures (no UI).
- Triggers: scene becomes active, `HostStore.add(_:)` succeeds.

**`PushReceiver`** (`Sources/GrafttyMobileKit/Push/PushReceiver.swift`) + `AppDelegate` extensions
- Foreground presentation: `userNotificationCenter(_:willPresent:withCompletionHandler:)` returns `[.banner, .sound]`.
- Tap handler: decodes `AgentStopNotificationPayload` from `response.notification.request.content.userInfo`, publishes a `DeepLinkTarget` to `DeepLinkRouter.shared`.
- Silent-push handler: `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` — if `userInfo.kind == "agent_stop_clear"`, calls `UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [userInfo.collapse_id])` and completes with `.newData`.

**`DeepLinkRouter`** (`Sources/GrafttyMobileKit/Push/DeepLinkRouter.swift`)
- `@Observable` class with `pendingTarget: DeepLinkTarget?`. `RootView` reacts via `.onChange(of:)` and reconstructs the navigation path. If `Auth.isLocked` is true, target is queued; `Auth.unlock(success:)` consumes it on next foreground.

## Data flow

### Flow A — iOS registration

1. iOS app foregrounds (or user adds a host).
2. `PushRegistrar.register()`:
   - `requestAuthorization([.alert, .sound, .badge])` — if denied, log + skip (`PUSH-1.2`).
   - `registerForRemoteNotifications()` — system → APNs → token.
   - `AppDelegate.didRegisterForRemoteNotifications…(token)` captures it.
   - For each saved host with `lastUsedAt > 90d ago`: `POST <host>/push/register` (`PUSH-1.1`).
3. Mac `/push/register` handler calls `PushDeviceStore.register(...)` (`PUSH-1.3`).

### Flow B — Attention fires → push

1. Agent hook fires → existing `TeamEventDispatcher.handle(...)` → `recordAgentStop(...)` (`Sources/Graftty/GrafttyApp.swift:1911`).
2. `PushOrchestrator.handleAgentStop(payload)`:
   - `AttentionPushDecider.shouldPush(...)` checks `isUserActiveOnDesktop` (`PUSH-2.1`/`PUSH-2.2`) and dedupe (`PUSH-2.4`).
   - If true: build `ApnsEnvelope.alert(...)` with `collapse-id = "<worktreePath>:<attentionTimestampISO>"` (`PUSH-3.1`), userInfo equal to `AgentStopNotification.content(...).userInfo`.
   - For each device in `PushDeviceStore.liveDevices()`, fan out via `Task.detached { try await ApnsClient.send(...) }`.
   - `dedupe.markPushed(worktreePath, attentionTimestamp)`.
3. APNs → iOS → banner posted with `request.identifier == collapse-id`.

### Flow C — Attention clears on Mac → remove iOS banner

1. `clearAttentionIfTimestamp(_:_:)` fires (user clicks macOS banner, switches worktree, types in pane).
2. `PushOrchestrator.handleAttentionCleared(path, ts)`:
   - If `(path, ts)` is in `PushDedupeStore`, build `ApnsEnvelope.silent(collapseId: ...)` (`PUSH-5.1`).
   - Fan out same as Flow B step 2.
3. iOS `application(_:didReceiveRemoteNotification:...)` sees `kind == "agent_stop_clear"`, removes the banner (`PUSH-5.2`).

### Flow D — iOS tap → deep-link

1. User taps banner.
2. `AppDelegate.userNotificationCenter(_:didReceive:...)` decodes payload (`PUSH-4.1`).
3. `DeepLinkRouter.shared.pendingTarget = .pane(...)`.
4. `RootView` observes; reconstructs `NavigationPath` to `[HostPicker → WorktreePicker(host) → WorktreeDetail(path) → TerminalPane(sessionID)]`.
5. If `Auth.isLocked` (`IOS-3.1`), target queued, applied on unlock (`PUSH-4.2`).

### Flow E — Stale-token GC & environment fallback

- `ApnsClient.send` → `400 BadDeviceToken` / `410 Unregistered` → `PushDeviceStore.remove(token:)` (`PUSH-6.1`).
- If every device in a batch returns `BadDeviceToken` on `api.push.apple.com`, retry same batch on `api.sandbox.push.apple.com`; cache the working endpoint in memory (`PUSH-6.2`).

## Error handling & edge cases

- **APNs key missing/unreadable** — `ApnsClient.init` throws; logged once at app launch; all subsequent `send` calls early-return `.skipped`. macOS Settings shows "Push: disabled (missing key)" so the user can diagnose.
- **APNs network failure** — one retry with 2s backoff, then drop. Stale pushes are worse than no pushes.
- **Device token rotation (iCloud restore, OS upgrade)** — APNs returns `BadDeviceToken`/`Unregistered`; store removes; iOS re-registers on next foreground with the new token.
- **iOS app uninstalled** — APNs returns `Unregistered`; store removes silently; eventually no pushes fire to that device.
- **Race: attention clears before alert push lands** — alert and clear share a `collapse-id`; iOS sees alert post, then clear remove — flicker resolves cleanly.
- **Multiple Macs hosting Graftty** — each Mac maintains its own `PushDeviceStore`; iOS device registers with each; both can push. Banner body shows worktree name; user can tell them apart.
- **Mac asleep when attention would fire** — agent process keeps the Mac running; if user is asleep/away, screen is locked or input is stale, push is sent normally.
- **iOS app foregrounded actively** — push still fires (`willPresent` returns `.banner`). Intentional: matches Apple's UNUserNotificationCenter convention.
- **Multi-worktree case (user active on Mac, different worktree fires)** — push is suppressed. The macOS banner and sidebar attention dot are deemed sufficient. v1 scope. Revisitable later as a per-worktree push toggle.
- **APNs environment** — same `.p8` works for both. We try production first, fall back to sandbox if every token in a batch errors, and cache the working endpoint for the process lifetime.

## Testing strategy

Logic-heavy components (`AttentionPushDecider`, `PushDeviceStore`, `ApnsClient`, `DesktopActivityMonitor` via mock source) live in `GrafttyKit` and are covered by plain Swift Testing tests that run under `swift test`. UIKit-bound components (`PushRegistrar`, `PushReceiver`, `DeepLinkRouter`) live in `GrafttyMobileKit` and are tested via the `GrafttyMobileKitTests` Xcode scheme (iOS simulator) — see the `MEMORY.md` reminder that `swift test` doesn't exercise UIKit-guarded code.

- `Tests/GrafttyKitTests/Push/DesktopActivityMonitorTests.swift` — `PUSH-2.3` truth table via a `DesktopActivitySource` mock.
- `Tests/GrafttyKitTests/Push/AttentionPushDeciderTests.swift` — `PUSH-2.1`, `PUSH-2.2`, `PUSH-2.4`.
- `Tests/GrafttyKitTests/Push/PushDeviceStoreTests.swift` — `PUSH-1.3` round-trips, 90-day filter, atomic-write semantics.
- `Tests/GrafttyKitTests/Push/ApnsClientTests.swift` — `PUSH-3.1`, `PUSH-3.2`, `PUSH-6.1`, `PUSH-6.2` via `URLProtocol` stub + fixed clock + injected `.p8` for deterministic JWT signing.
- `Tests/GrafttyKitTests/Push/PushClearServiceTests.swift` — `PUSH-5.1`.
- `Tests/GrafttyKitTests/Hosting/PushRegisterEndpointTests.swift` — `PUSH-1.3` mutation via HTTP.
- `Tests/GrafttyMobileKitTests/Push/PushRegistrarTests.swift` — `PUSH-1.1`, `PUSH-1.2`.
- `Tests/GrafttyMobileKitTests/Push/PushReceiverTests.swift` — `PUSH-5.2`, tap-handler decoding.
- `Tests/GrafttyMobileKitTests/Push/DeepLinkRouterTests.swift` — `PUSH-4.1`, `PUSH-4.2`.

Manual end-to-end checklist in `docs/push/README.md` (build to device, fire a Stop hook, confirm banner — APNs isn't unit-testable with real network).

## Out of scope (deferred)

- Per-worktree push mute/unmute UI.
- Push for `notify`, OSC 9, command-finished, PR status, build completions.
- A push-history view on iOS.
- Multi-user / org Graftty deployments where a single APNs key serves many devices.
- Replacement of `.p8` via UI (key rotation requires a Graftty.app release).

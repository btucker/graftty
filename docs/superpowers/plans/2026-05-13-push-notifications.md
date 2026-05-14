# Push Notifications to GrafttyMobile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver APNs alerts to GrafttyMobile whenever a Claude/Codex agent needs the user's input, suppressed while the user is demonstrably active at the Mac.

**Architecture:** Mac acts as the APNs application server (signs ES256 JWTs from a bundled `.p8`, POSTs to `api.push.apple.com` over HTTP/2). Logic-heavy components (`PushDeviceStore`, `AttentionPushDecider`, `ApnsClient`, `DesktopActivityMonitor`) live in `GrafttyKit` so they're testable under `swift test`. NSWorkspace-bound glue lives in the macOS app target. iOS-side `PushRegistrar` / `PushReceiver` / `DeepLinkRouter` live in `GrafttyMobileKit`.

**Tech Stack:** Swift 5.10, Swift Testing, CryptoKit (ES256), URLSession HTTP/2, NIOHTTP1 (for new `/push/register` route), CGEventSource (idle detection), NSWorkspace + DistributedNotificationCenter (sleep/lock detection), UIKit + UserNotifications (iOS).

**Reference spec:** `docs/superpowers/specs/2026-05-13-push-notifications-design.md`

---

## File map

**New files (Mac, cross-platform — GrafttyKit):**
- `Sources/GrafttyKit/Push/PushDevice.swift` — `PushDevice` model.
- `Sources/GrafttyKit/Push/PushDeviceStore.swift` — atomic JSON-backed store of registered devices.
- `Sources/GrafttyKit/Push/PushDedupeStore.swift` — in-memory per-process dedupe map.
- `Sources/GrafttyKit/Push/DesktopActivityMonitor.swift` — `DesktopActivitySource` protocol + cached monitor.
- `Sources/GrafttyKit/Push/AttentionPushDecider.swift` — pure suppression+dedupe function.
- `Sources/GrafttyKit/Push/ApnsEnvelope.swift` — envelope value type.
- `Sources/GrafttyKit/Push/ApnsJWT.swift` — ES256 JWT signer.
- `Sources/GrafttyKit/Push/ApnsClient.swift` — HTTP/2 push sender.
- `Sources/GrafttyKit/Push/PushConfig.swift` — `KEYID`/`TEAMID`/`TOPIC` resolver.
- `Sources/GrafttyKit/Push/PushClearService.swift` — sends silent-remove on attention clear.
- `Sources/GrafttyKit/Web/PushRegisterEndpoint.swift` — request/response type + WebServer wire-in.

**New files (Mac app — Graftty):**
- `Sources/Graftty/Push/PushOrchestrator.swift` — singletons + glue into `recordAgentStop` and `clearAttentionIfTimestamp` callsites.
- `Sources/Graftty/Push/CGEventActivitySource.swift` — concrete `DesktopActivitySource` impl.

**New files (iOS — GrafttyMobileKit):**
- `Sources/GrafttyMobileKit/Push/PushRegistrar.swift` — token request + fanout to hosts.
- `Sources/GrafttyMobileKit/Push/PushReceiver.swift` — `UNUserNotificationCenterDelegate` + silent-push handler.
- `Sources/GrafttyMobileKit/Push/DeepLinkRouter.swift` — observable navigation target.
- `Sources/GrafttyMobileKit/Push/PushAppDelegate.swift` — `UIApplicationDelegate` adapter (registers `PushRegistrar` + `PushReceiver`).

**New tests:**
- `Tests/GrafttyKitTests/Push/PushDeviceStoreTests.swift`
- `Tests/GrafttyKitTests/Push/PushDedupeStoreTests.swift`
- `Tests/GrafttyKitTests/Push/DesktopActivityMonitorTests.swift`
- `Tests/GrafttyKitTests/Push/AttentionPushDeciderTests.swift`
- `Tests/GrafttyKitTests/Push/ApnsJWTTests.swift`
- `Tests/GrafttyKitTests/Push/ApnsClientTests.swift`
- `Tests/GrafttyKitTests/Push/PushClearServiceTests.swift`
- `Tests/GrafttyKitTests/Web/PushRegisterEndpointTests.swift`
- `Tests/GrafttyMobileKitTests/Push/PushRegistrarTests.swift`
- `Tests/GrafttyMobileKitTests/Push/PushReceiverTests.swift`
- `Tests/GrafttyMobileKitTests/Push/DeepLinkRouterTests.swift`

**New spec file:**
- `Tests/GrafttyTests/Specs/PushTodo.swift` — `.disabled` inventory for PUSH-1..6 (promoted into real tests as tasks progress).

**Modified files:**
- `Tests/GrafttyTests/Specs/IosTodo.swift` — narrow IOS-8.5 text.
- `Package.swift` — add `Resources/apns` copy to the `Graftty` executable target (placeholder dir even if empty).
- `Apps/GrafttyMobile/project.yml` + new `Apps/GrafttyMobile/GrafttyMobile/GrafttyMobile.entitlements` — add `aps-environment`.
- `Sources/Graftty/Web/WebServerController.swift` — pass `pushRegisterHandler` into `WebServer.Config`.
- `Sources/GrafttyKit/Web/WebServer.swift` — add `/push/register` route and `pushRegisterHandler` config field.
- `Sources/Graftty/GrafttyApp.swift` — invoke `PushOrchestrator` from `recordAgentStop` and `clearAttentionIfTimestamp` sites.
- `Sources/GrafttyMobileKit/App/GrafttyMobileApp.swift` — attach `PushAppDelegate` via `@UIApplicationDelegateAdaptor`.
- `Sources/GrafttyMobileKit/App/RootView.swift` — observe `DeepLinkRouter` and reconstruct navigation.
- `Sources/GrafttyMobileKit/Hosts/HostStore.swift` — call `PushRegistrar.registerWithAllHosts()` on `add(_:)`.
- `SPECS.md` — regenerated.
- `docs/push/README.md` (new) — manual checklist for minting the `.p8` and end-to-end verification.

---

## Task 1: Add PUSH spec inventory + narrow IOS-8.5

**Files:**
- Create: `Tests/GrafttyTests/Specs/PushTodo.swift`
- Modify: `Tests/GrafttyTests/Specs/IosTodo.swift`
- Regenerate: `SPECS.md`

- [ ] **Step 1: Create the PUSH inventory file**

```swift
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
```

- [ ] **Step 2: Narrow IOS-8.5**

Edit `Tests/GrafttyTests/Specs/IosTodo.swift` — replace the existing IOS-8.5 text:

```swift
    @Test("""
@spec IOS-8.5: The v1 iOS app shall not use push notifications for PR status, build completions, or session events other than the agent-attention notifications defined in PUSH-1..6.
""", .disabled("not yet implemented"))
    func ios_8_5() async throws { }
```

- [ ] **Step 3: Regenerate SPECS.md and run the verify check**

Run:
```bash
python3 scripts/generate-specs.py
python3 scripts/generate-specs.py --check
```
Expected: SPECS.md updated; `--check` exits 0.

- [ ] **Step 4: Build to verify the new file compiles**

Run: `swift build`
Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add Tests/GrafttyTests/Specs/PushTodo.swift Tests/GrafttyTests/Specs/IosTodo.swift SPECS.md
git commit -m "docs(push): add PUSH-1..6 spec inventory; narrow IOS-8.5"
```

---

## Task 2: `PushDevice` + `PushDeviceStore` (PUSH-1.3)

**Files:**
- Create: `Sources/GrafttyKit/Push/PushDevice.swift`
- Create: `Sources/GrafttyKit/Push/PushDeviceStore.swift`
- Create: `Tests/GrafttyKitTests/Push/PushDeviceStoreTests.swift`
- Modify: `Tests/GrafttyTests/Specs/PushTodo.swift` (remove PUSH-1.3 entry once promoted)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/GrafttyKitTests/Push/PushDeviceStoreTests.swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec PUSH-1.3: PushDeviceStore persists registrations and filters stale entries on read.")
struct PushDeviceStoreTests {
    private func makeTempStore() -> (PushDeviceStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("push-devices-\(UUID()).json")
        return (PushDeviceStore(fileURL: url), url)
    }

    @Test func roundTripsRegisteredDevice() throws {
        let (store, _) = makeTempStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let dev = PushDevice(token: "deadbeef", deviceName: "iPhone", platform: "ios", lastRegisteredAt: now)
        try store.register(dev)
        #expect(store.liveDevices(now: now) == [dev])
    }

    @Test func filtersDevicesOlderThan90Days() throws {
        let (store, _) = makeTempStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = PushDevice(token: "stale", deviceName: "Old", platform: "ios",
                               lastRegisteredAt: now.addingTimeInterval(-91 * 86_400))
        let fresh = PushDevice(token: "fresh", deviceName: "New", platform: "ios", lastRegisteredAt: now)
        try store.register(stale)
        try store.register(fresh)
        let live = store.liveDevices(now: now)
        #expect(live.map(\.token) == ["fresh"])
    }

    @Test func replacingTokenUpdatesLastRegisteredAt() throws {
        let (store, _) = makeTempStore()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(60)
        try store.register(PushDevice(token: "tok", deviceName: "A", platform: "ios", lastRegisteredAt: t0))
        try store.register(PushDevice(token: "tok", deviceName: "B", platform: "ios", lastRegisteredAt: t1))
        let devices = store.liveDevices(now: t1)
        #expect(devices.count == 1)
        #expect(devices[0].deviceName == "B")
        #expect(devices[0].lastRegisteredAt == t1)
    }

    @Test func removeDropsToken() throws {
        let (store, _) = makeTempStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try store.register(PushDevice(token: "gone", deviceName: "X", platform: "ios", lastRegisteredAt: now))
        try store.remove(token: "gone")
        #expect(store.liveDevices(now: now).isEmpty)
    }

    @Test func atomicReplaceOnEachWrite() throws {
        let (store, url) = makeTempStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try store.register(PushDevice(token: "a", deviceName: "A", platform: "ios", lastRegisteredAt: now))
        #expect(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder.iso8601().decode([PushDevice].self, from: data)
        #expect(decoded.map(\.token) == ["a"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter PushDeviceStoreTests`
Expected: compile error — `PushDevice`/`PushDeviceStore` undefined.

- [ ] **Step 3: Create `PushDevice`**

```swift
// Sources/GrafttyKit/Push/PushDevice.swift
import Foundation

public struct PushDevice: Codable, Sendable, Equatable {
    public let token: String
    public let deviceName: String
    public let platform: String  // "ios" today; "macos" reserved for future cross-push
    public let lastRegisteredAt: Date

    public init(token: String, deviceName: String, platform: String, lastRegisteredAt: Date) {
        self.token = token
        self.deviceName = deviceName
        self.platform = platform
        self.lastRegisteredAt = lastRegisteredAt
    }
}

extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
```

- [ ] **Step 4: Create `PushDeviceStore`**

```swift
// Sources/GrafttyKit/Push/PushDeviceStore.swift
import Foundation

/// Atomic JSON-backed store of registered push targets.
/// `register`/`remove` rewrite the entire file; `liveDevices(now:)` filters
/// records whose `lastRegisteredAt` is older than 90 days.
public final class PushDeviceStore: @unchecked Sendable {
    public static let defaultFileURL: URL = {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Graftty/push-devices.json")
    }()

    private static let retention: TimeInterval = 90 * 86_400

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL = PushDeviceStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func register(_ device: PushDevice) throws {
        try mutate { all in
            all.removeAll { $0.token == device.token }
            all.append(device)
        }
    }

    public func remove(token: String) throws {
        try mutate { all in
            all.removeAll { $0.token == token }
        }
    }

    public func liveDevices(now: Date = Date()) -> [PushDevice] {
        (try? load()).map { $0.filter { now.timeIntervalSince($0.lastRegisteredAt) <= Self.retention } } ?? []
    }

    private func mutate(_ apply: (inout [PushDevice]) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var all = (try? load()) ?? []
        apply(&all)
        try write(all)
    }

    private func load() throws -> [PushDevice] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.iso8601().decode([PushDevice].self, from: data)
    }

    private func write(_ devices: [PushDevice]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder.iso8601().encode(devices)
        let tmp = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
    }
}
```

- [ ] **Step 4b: Promote PUSH-1.3 — remove the `.disabled` entry**

In `Tests/GrafttyTests/Specs/PushTodo.swift`, delete the PUSH-1.3 `@Test` block (per CLAUDE.md: "promote a .disabled test to a real @Test in a *Tests.swift file before implementing the behavior, and delete the inventory entry in the same commit").

- [ ] **Step 5: Run tests to verify they pass and regenerate SPECS.md**

Run:
```bash
swift test --filter PushDeviceStoreTests
python3 scripts/generate-specs.py
python3 scripts/generate-specs.py --check
```
Expected: tests pass; SPECS.md updated; `--check` exits 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Push/PushDevice.swift Sources/GrafttyKit/Push/PushDeviceStore.swift \
        Tests/GrafttyKitTests/Push/PushDeviceStoreTests.swift \
        Tests/GrafttyTests/Specs/PushTodo.swift SPECS.md
git commit -m "feat(push): PushDeviceStore atomic JSON registration (PUSH-1.3)"
```

---

## Task 3: `PushDedupeStore` + `AttentionPushDecider` (PUSH-2.1, 2.2, 2.4)

**Files:**
- Create: `Sources/GrafttyKit/Push/PushDedupeStore.swift`
- Create: `Sources/GrafttyKit/Push/AttentionPushDecider.swift`
- Create: `Tests/GrafttyKitTests/Push/PushDedupeStoreTests.swift`
- Create: `Tests/GrafttyKitTests/Push/AttentionPushDeciderTests.swift`
- Modify: `Tests/GrafttyTests/Specs/PushTodo.swift` (remove PUSH-2.1, 2.2, 2.4)

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/GrafttyKitTests/Push/PushDedupeStoreTests.swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("PushDedupeStore")
struct PushDedupeStoreTests {
    @Test func returnsNilForUnknownWorktree() {
        let s = PushDedupeStore()
        #expect(s.lastPushed(forWorktree: "/x") == nil)
    }

    @Test func markPushedRecordsTimestamp() {
        let s = PushDedupeStore()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        s.markPushed(worktree: "/x", attentionTimestamp: t)
        #expect(s.lastPushed(forWorktree: "/x") == t)
    }

    @Test func separateWorktreesAreIndependent() {
        let s = PushDedupeStore()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        s.markPushed(worktree: "/a", attentionTimestamp: t)
        #expect(s.lastPushed(forWorktree: "/b") == nil)
    }
}
```

```swift
// Tests/GrafttyKitTests/Push/AttentionPushDeciderTests.swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("AttentionPushDecider")
struct AttentionPushDeciderTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let path = "/repo/wt"

    private func payload(_ ts: Date) -> AgentStopNotificationPayload {
        AgentStopNotificationPayload(runtime: .claude, worktreePath: path,
                                     sessionID: "sess", attentionTimestamp: ts)
    }

    @Test("@spec PUSH-2.1: user not active on desktop → push fires.")
    func push_2_1_pushesWhenInactive() {
        let dedupe = PushDedupeStore()
        #expect(AttentionPushDecider.shouldPush(
            payload: payload(now),
            isUserActiveOnDesktop: false,
            dedupe: dedupe) == true)
    }

    @Test("@spec PUSH-2.2: user active on desktop → push suppressed.")
    func push_2_2_suppressesWhenActive() {
        let dedupe = PushDedupeStore()
        #expect(AttentionPushDecider.shouldPush(
            payload: payload(now),
            isUserActiveOnDesktop: true,
            dedupe: dedupe) == false)
    }

    @Test("@spec PUSH-2.4: same (worktree, timestamp) only pushes once.")
    func push_2_4_dedupes() {
        let dedupe = PushDedupeStore()
        let p = payload(now)
        #expect(AttentionPushDecider.shouldPush(
            payload: p, isUserActiveOnDesktop: false, dedupe: dedupe) == true)
        dedupe.markPushed(worktree: path, attentionTimestamp: now)
        #expect(AttentionPushDecider.shouldPush(
            payload: p, isUserActiveOnDesktop: false, dedupe: dedupe) == false)
        // A *new* timestamp on the same worktree pushes again.
        let p2 = payload(now.addingTimeInterval(1))
        #expect(AttentionPushDecider.shouldPush(
            payload: p2, isUserActiveOnDesktop: false, dedupe: dedupe) == true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (types undefined)**

Run: `swift test --filter PushDedupe`
Expected: compile errors.

- [ ] **Step 3: Implement `PushDedupeStore`**

```swift
// Sources/GrafttyKit/Push/PushDedupeStore.swift
import Foundation

public final class PushDedupeStore: @unchecked Sendable {
    private var lastByWorktree: [String: Date] = [:]
    private let lock = NSLock()

    public init() {}

    public func lastPushed(forWorktree path: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return lastByWorktree[path]
    }

    public func markPushed(worktree: String, attentionTimestamp: Date) {
        lock.lock(); defer { lock.unlock() }
        lastByWorktree[worktree] = attentionTimestamp
    }
}
```

- [ ] **Step 4: Implement `AttentionPushDecider`**

```swift
// Sources/GrafttyKit/Push/AttentionPushDecider.swift
import Foundation

public enum AttentionPushDecider {
    /// Returns true iff the user is not active at the desktop AND we have
    /// not already pushed this exact (worktreePath, attentionTimestamp) pair.
    /// Callers update `dedupe` after a successful send.
    public static func shouldPush(
        payload: AgentStopNotificationPayload,
        isUserActiveOnDesktop: Bool,
        dedupe: PushDedupeStore
    ) -> Bool {
        if isUserActiveOnDesktop { return false }
        return dedupe.lastPushed(forWorktree: payload.worktreePath) != payload.attentionTimestamp
    }
}
```

- [ ] **Step 5: Promote PUSH-2.1, 2.2, 2.4 — delete their inventory entries.**

- [ ] **Step 6: Run tests and regenerate SPECS.md**

```bash
swift test --filter PushDedupe
swift test --filter AttentionPushDecider
python3 scripts/generate-specs.py
python3 scripts/generate-specs.py --check
```
Expected: tests pass; SPECS.md current.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Push/PushDedupeStore.swift Sources/GrafttyKit/Push/AttentionPushDecider.swift \
        Tests/GrafttyKitTests/Push/PushDedupeStoreTests.swift Tests/GrafttyKitTests/Push/AttentionPushDeciderTests.swift \
        Tests/GrafttyTests/Specs/PushTodo.swift SPECS.md
git commit -m "feat(push): AttentionPushDecider + PushDedupeStore (PUSH-2.1, 2.2, 2.4)"
```

---

## Task 4: `DesktopActivityMonitor` + activity source (PUSH-2.3)

**Files:**
- Create: `Sources/GrafttyKit/Push/DesktopActivityMonitor.swift`
- Create: `Tests/GrafttyKitTests/Push/DesktopActivityMonitorTests.swift`
- Modify: `Tests/GrafttyTests/Specs/PushTodo.swift` (remove PUSH-2.3)

- [ ] **Step 1: Write failing tests against a mock source**

```swift
// Tests/GrafttyKitTests/Push/DesktopActivityMonitorTests.swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec PUSH-2.3: DesktopActivityMonitor truth table")
struct DesktopActivityMonitorTests {
    @Test func activeWhenAwakeUnlockedAndRecentInput() {
        let src = MockDesktopActivitySource(systemAsleep: false, screenLocked: false, lastInputAgeSeconds: 5)
        let m = DesktopActivityMonitor(source: src)
        #expect(m.isUserActiveOnDesktop == true)
    }

    @Test func inactiveWhenSleeping() {
        let src = MockDesktopActivitySource(systemAsleep: true, screenLocked: false, lastInputAgeSeconds: 1)
        #expect(DesktopActivityMonitor(source: src).isUserActiveOnDesktop == false)
    }

    @Test func inactiveWhenScreenLocked() {
        let src = MockDesktopActivitySource(systemAsleep: false, screenLocked: true, lastInputAgeSeconds: 1)
        #expect(DesktopActivityMonitor(source: src).isUserActiveOnDesktop == false)
    }

    @Test func inactiveWhenIdleAtLeast60Seconds() {
        let src = MockDesktopActivitySource(systemAsleep: false, screenLocked: false, lastInputAgeSeconds: 60)
        #expect(DesktopActivityMonitor(source: src).isUserActiveOnDesktop == false)
    }

    @Test func activeAtBoundaryUnder60Seconds() {
        let src = MockDesktopActivitySource(systemAsleep: false, screenLocked: false, lastInputAgeSeconds: 59.999)
        #expect(DesktopActivityMonitor(source: src).isUserActiveOnDesktop == true)
    }
}

private final class MockDesktopActivitySource: DesktopActivitySource, @unchecked Sendable {
    var systemAsleep: Bool
    var screenLocked: Bool
    var lastInputAgeSeconds: TimeInterval
    init(systemAsleep: Bool, screenLocked: Bool, lastInputAgeSeconds: TimeInterval) {
        self.systemAsleep = systemAsleep
        self.screenLocked = screenLocked
        self.lastInputAgeSeconds = lastInputAgeSeconds
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DesktopActivityMonitor`
Expected: compile error.

- [ ] **Step 3: Implement the protocol + monitor**

```swift
// Sources/GrafttyKit/Push/DesktopActivityMonitor.swift
import Foundation

public protocol DesktopActivitySource: AnyObject {
    var systemAsleep: Bool { get }
    var screenLocked: Bool { get }
    var lastInputAgeSeconds: TimeInterval { get }
}

public final class DesktopActivityMonitor: @unchecked Sendable {
    private let source: DesktopActivitySource

    public init(source: DesktopActivitySource) {
        self.source = source
    }

    /// True iff the Mac is awake, unlocked, and the user has interacted
    /// with the system within the last 60 seconds.
    public var isUserActiveOnDesktop: Bool {
        !source.systemAsleep && !source.screenLocked && source.lastInputAgeSeconds < 60
    }
}
```

- [ ] **Step 4: Promote PUSH-2.3** — delete its inventory entry.

- [ ] **Step 5: Run tests + regenerate SPECS.md**

```bash
swift test --filter DesktopActivityMonitor
python3 scripts/generate-specs.py
python3 scripts/generate-specs.py --check
```
Expected: tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Push/DesktopActivityMonitor.swift \
        Tests/GrafttyKitTests/Push/DesktopActivityMonitorTests.swift \
        Tests/GrafttyTests/Specs/PushTodo.swift SPECS.md
git commit -m "feat(push): DesktopActivityMonitor with injectable source (PUSH-2.3)"
```

---

## Task 5: `ApnsEnvelope` + `ApnsJWT` ES256 signer (PUSH-3.1 partial, PUSH-3.2)

**Files:**
- Create: `Sources/GrafttyKit/Push/ApnsEnvelope.swift`
- Create: `Sources/GrafttyKit/Push/ApnsJWT.swift`
- Create: `Tests/GrafttyKitTests/Push/ApnsJWTTests.swift`
- Modify: `Tests/GrafttyTests/Specs/PushTodo.swift` (remove PUSH-3.2)

- [ ] **Step 1: Write the failing JWT test**

```swift
// Tests/GrafttyKitTests/Push/ApnsJWTTests.swift
import Foundation
import CryptoKit
import Testing
@testable import GrafttyKit

@Suite("@spec PUSH-3.2: ApnsJWT signs ES256 tokens with cached lifetime.")
struct ApnsJWTTests {
    // A real P-256 PEM-equivalent .p8 body (sec1/pkcs8). Generated once with
    // `openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt`
    // and pasted here for deterministic signing tests.
    private let testP8: String = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg2hZ29NbukDOzgshu
SS0qHmFC2T0eOY/8q0sP4apw/JuhRANCAATFp1iWMaeWZeoDqUNFM2sLCXVbvLAW
TGW+r8wH8WiZkXm/o3GbtACMR4xwgGu0u3uW5JhmpcwsB4u91YgC9jWA
-----END PRIVATE KEY-----
"""

    @Test func producesThreeSegmentToken() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let signer = ApnsJWT(privateKeyPEM: testP8, keyID: "KEY123ABCD", teamID: "TEAM67890",
                             clock: { now })
        let token = try signer.token()
        #expect(token.split(separator: ".").count == 3)
    }

    @Test func reusesTokenWithinFiftyMinutes() throws {
        var virtual = Date(timeIntervalSince1970: 1_700_000_000)
        let signer = ApnsJWT(privateKeyPEM: testP8, keyID: "K", teamID: "T",
                             clock: { virtual })
        let first = try signer.token()
        virtual = virtual.addingTimeInterval(49 * 60)
        let second = try signer.token()
        #expect(first == second)
    }

    @Test func mintsNewTokenAfterFiftyMinutes() throws {
        var virtual = Date(timeIntervalSince1970: 1_700_000_000)
        let signer = ApnsJWT(privateKeyPEM: testP8, keyID: "K", teamID: "T",
                             clock: { virtual })
        let first = try signer.token()
        virtual = virtual.addingTimeInterval(51 * 60)
        let second = try signer.token()
        #expect(first != second)
    }

    @Test func headerCarriesKeyIDAndAlgorithm() throws {
        let signer = ApnsJWT(privateKeyPEM: testP8, keyID: "MYKEYID", teamID: "T",
                             clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        let token = try signer.token()
        let header = token.split(separator: ".")[0]
        let padded = String(header) + String(repeating: "=", count: (4 - header.count % 4) % 4)
        let decoded = Data(base64Encoded: padded.replacingOccurrences(of: "-", with: "+")
                                                .replacingOccurrences(of: "_", with: "/"))!
        let json = try JSONSerialization.jsonObject(with: decoded) as! [String: String]
        #expect(json["alg"] == "ES256")
        #expect(json["kid"] == "MYKEYID")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ApnsJWT`
Expected: compile error.

- [ ] **Step 3: Implement `ApnsEnvelope`**

```swift
// Sources/GrafttyKit/Push/ApnsEnvelope.swift
import Foundation

public struct ApnsEnvelope: Sendable, Equatable {
    public enum PushType: String, Sendable { case alert, background }

    public let pushType: PushType
    public let topic: String
    public let collapseID: String
    public let payload: Data         // JSON-encoded `aps + userInfo`
    public let priority: Int         // 10 for alert, 5 for background

    public init(pushType: PushType, topic: String, collapseID: String, payload: Data, priority: Int) {
        self.pushType = pushType
        self.topic = topic
        self.collapseID = collapseID
        self.payload = payload
        self.priority = priority
    }

    /// Construct an alert envelope from an `AgentStopNotificationContent`.
    public static func alert(
        topic: String,
        worktreePath: String,
        attentionTimestamp: Date,
        content: AgentStopNotificationContent
    ) throws -> ApnsEnvelope {
        let aps: [String: Any] = [
            "aps": ["alert": ["title": content.title, "body": content.body], "sound": "default"]
        ]
        var merged = aps
        var info: [String: Any] = aps
        for (k, v) in content.userInfo { info[k] = v }
        merged = info
        let data = try JSONSerialization.data(withJSONObject: merged,
                                              options: [.sortedKeys])
        return ApnsEnvelope(pushType: .alert, topic: topic,
                            collapseID: collapseID(worktreePath: worktreePath, attentionTimestamp: attentionTimestamp),
                            payload: data, priority: 10)
    }

    /// Construct a silent-remove envelope. Carries `content-available: 1`
    /// + a `userInfo.kind == "agent_stop_clear"` marker so iOS can
    /// call `removeDeliveredNotifications(withIdentifiers:)`.
    public static func clear(
        topic: String,
        worktreePath: String,
        attentionTimestamp: Date
    ) throws -> ApnsEnvelope {
        let cid = collapseID(worktreePath: worktreePath, attentionTimestamp: attentionTimestamp)
        let payload: [String: Any] = [
            "aps": ["content-available": 1],
            "kind": "agent_stop_clear",
            "collapse_id": cid,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return ApnsEnvelope(pushType: .background, topic: topic, collapseID: cid,
                            payload: data, priority: 5)
    }

    private static func collapseID(worktreePath: String, attentionTimestamp: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(worktreePath):\(iso.string(from: attentionTimestamp))"
    }
}
```

- [ ] **Step 4: Implement `ApnsJWT`**

```swift
// Sources/GrafttyKit/Push/ApnsJWT.swift
import Foundation
import CryptoKit

public enum ApnsJWTError: Error, Equatable {
    case malformedPEM
    case signingFailed
}

/// ES256 JWT signer for APNs. Caches one token per ~50 minutes so we don't
/// re-sign on every push (Apple allows up to 60 minutes; 50 leaves slack
/// for clock skew).
public final class ApnsJWT: @unchecked Sendable {
    public let keyID: String
    public let teamID: String

    private let key: P256.Signing.PrivateKey
    private let clock: @Sendable () -> Date

    private let lock = NSLock()
    private var cachedToken: (token: String, issuedAt: Date)?

    public init(privateKeyPEM: String, keyID: String, teamID: String,
                clock: @escaping @Sendable () -> Date = Date.init) throws {
        self.keyID = keyID
        self.teamID = teamID
        self.clock = clock
        self.key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
    }

    public func token() throws -> String {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        if let cached = cachedToken, now.timeIntervalSince(cached.issuedAt) < 50 * 60 {
            return cached.token
        }
        let header: [String: String] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let payload: [String: Any] = ["iss": teamID, "iat": Int(now.timeIntervalSince1970)]
        let headerSeg = try Self.base64URL(JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let payloadSeg = try Self.base64URL(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let signingInput = "\(headerSeg).\(payloadSeg)"
        let signature = try key.signature(for: Data(signingInput.utf8))
        let sigSeg = Self.base64URL(signature.rawRepresentation)
        let token = "\(signingInput).\(sigSeg)"
        cachedToken = (token, now)
        return token
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

- [ ] **Step 5: Promote PUSH-3.2** — delete inventory entry.

- [ ] **Step 6: Run tests + regenerate SPECS.md**

```bash
swift test --filter ApnsJWT
python3 scripts/generate-specs.py
python3 scripts/generate-specs.py --check
```

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Push/ApnsEnvelope.swift Sources/GrafttyKit/Push/ApnsJWT.swift \
        Tests/GrafttyKitTests/Push/ApnsJWTTests.swift \
        Tests/GrafttyTests/Specs/PushTodo.swift SPECS.md
git commit -m "feat(push): ApnsEnvelope + ApnsJWT ES256 signer (PUSH-3.2)"
```

---

## Task 6: `ApnsClient` (PUSH-3.1, PUSH-6.1, PUSH-6.2)

**Files:**
- Create: `Sources/GrafttyKit/Push/ApnsClient.swift`
- Create: `Tests/GrafttyKitTests/Push/ApnsClientTests.swift`
- Modify: `Tests/GrafttyTests/Specs/PushTodo.swift` (remove PUSH-3.1, 6.1, 6.2)

- [ ] **Step 1: Write failing tests with URLProtocol stub**

```swift
// Tests/GrafttyKitTests/Push/ApnsClientTests.swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("ApnsClient")
struct ApnsClientTests {
    private let testP8 = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg2hZ29NbukDOzgshu
SS0qHmFC2T0eOY/8q0sP4apw/JuhRANCAATFp1iWMaeWZeoDqUNFM2sLCXVbvLAW
TGW+r8wH8WiZkXm/o3GbtACMR4xwgGu0u3uW5JhmpcwsB4u91YgC9jWA
-----END PRIVATE KEY-----
"""

    private func makeClient(stub: @escaping (URLRequest) -> (Int, Data?)) throws -> ApnsClient {
        APNsStubProtocol.handler = stub
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [APNsStubProtocol.self]
        let session = URLSession(configuration: cfg)
        let jwt = try ApnsJWT(privateKeyPEM: testP8, keyID: "K", teamID: "T",
                              clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        return ApnsClient(jwt: jwt, session: session, topic: "com.quotably.graftty")
    }

    @Test("@spec PUSH-3.1: alert envelope carries topic, push-type, collapse-id, authorization.")
    func push_3_1_alertHeaders() async throws {
        var captured: URLRequest?
        let client = try makeClient { req in
            captured = req
            return (200, nil)
        }
        let env = try ApnsEnvelope.alert(
            topic: "com.quotably.graftty",
            worktreePath: "/r/wt",
            attentionTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
            content: AgentStopNotification.content(
                runtime: .claude, worktreeName: "wt", worktreePath: "/r/wt",
                sessionID: "s1", timestamp: Date(timeIntervalSince1970: 1_700_000_000)))
        let result = try await client.send(env, to: PushDevice(token: "abc",
                                                               deviceName: "iPhone",
                                                               platform: "ios",
                                                               lastRegisteredAt: Date()))
        #expect(result == .delivered)
        #expect(captured?.url?.absoluteString.contains("/3/device/abc") == true)
        #expect(captured?.value(forHTTPHeaderField: "apns-topic") == "com.quotably.graftty")
        #expect(captured?.value(forHTTPHeaderField: "apns-push-type") == "alert")
        #expect(captured?.value(forHTTPHeaderField: "apns-collapse-id") != nil)
        #expect(captured?.value(forHTTPHeaderField: "authorization")?.hasPrefix("bearer ") == true)
    }

    @Test("@spec PUSH-6.1: 410 Unregistered reports unregistered to caller.")
    func push_6_1_unregistered() async throws {
        let client = try makeClient { _ in (410, Data(#"{"reason":"Unregistered"}"#.utf8)) }
        let env = try ApnsEnvelope.clear(topic: "com.quotably.graftty",
                                         worktreePath: "/r/wt",
                                         attentionTimestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let res = try await client.send(env, to: PushDevice(token: "x", deviceName: "x",
                                                            platform: "ios", lastRegisteredAt: Date()))
        #expect(res == .badDeviceToken)
    }

    @Test("@spec PUSH-6.2: sandbox fallback when production returns BadDeviceToken everywhere.")
    func push_6_2_sandboxFallback() async throws {
        var hostsCalled: [String] = []
        let client = try makeClient { req in
            hostsCalled.append(req.url?.host ?? "")
            if req.url?.host == "api.push.apple.com" {
                return (400, Data(#"{"reason":"BadDeviceToken"}"#.utf8))
            } else {
                return (200, nil)
            }
        }
        let env = try ApnsEnvelope.clear(topic: "com.quotably.graftty",
                                         worktreePath: "/r/wt",
                                         attentionTimestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let devs = [PushDevice(token: "a", deviceName: "a", platform: "ios", lastRegisteredAt: Date())]
        let results = await client.sendFanout(env, to: devs)
        #expect(results.allSatisfy { $0.outcome == .delivered })
        #expect(hostsCalled.contains("api.sandbox.push.apple.com"))
        // Second fanout should hit sandbox directly (endpoint cached).
        let resultsTwo = await client.sendFanout(env, to: devs)
        #expect(resultsTwo.allSatisfy { $0.outcome == .delivered })
        #expect(hostsCalled.filter { $0 == "api.push.apple.com" }.count == 1)
    }
}

/// URLProtocol stub used by ApnsClient tests. Captures the outgoing
/// request and replays a canned response.
final class APNsStubProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) -> (Int, Data?))!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/2", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ApnsClient`
Expected: compile error.

- [ ] **Step 3: Implement `ApnsClient`**

```swift
// Sources/GrafttyKit/Push/ApnsClient.swift
import Foundation

public enum ApnsSendOutcome: Sendable, Equatable {
    case delivered
    case badDeviceToken
    case skippedNoKey
    case error(String)
}

public struct ApnsFanoutResult: Sendable, Equatable {
    public let device: PushDevice
    public let outcome: ApnsSendOutcome
}

/// HTTP/2 sender to Apple's APNs gateway. Holds a single long-lived
/// URLSession (HTTP/2 multiplexed) and remembers which endpoint (prod
/// vs sandbox) successfully delivered the most recent batch.
public actor ApnsClient {
    private let jwt: ApnsJWT
    private let session: URLSession
    private let topic: String

    private var cachedEndpointHost: String?

    private static let productionHost = "api.push.apple.com"
    private static let sandboxHost = "api.sandbox.push.apple.com"

    public init(jwt: ApnsJWT, session: URLSession = URLSession(configuration: .default),
                topic: String) {
        self.jwt = jwt
        self.session = session
        self.topic = topic
    }

    /// Single-device send. Used by tests; production callers use `sendFanout`.
    public func send(_ env: ApnsEnvelope, to device: PushDevice) async throws -> ApnsSendOutcome {
        try await send(env, to: device, host: cachedEndpointHost ?? Self.productionHost)
    }

    /// Fan a single envelope out across multiple devices. If every device
    /// returns `BadDeviceToken` on production, retry the whole fanout on
    /// sandbox and cache the working endpoint for the rest of this actor's
    /// lifetime (PUSH-6.2).
    public func sendFanout(_ env: ApnsEnvelope, to devices: [PushDevice]) async -> [ApnsFanoutResult] {
        guard !devices.isEmpty else { return [] }
        let primary = cachedEndpointHost ?? Self.productionHost
        let primaryResults = await fanout(env, to: devices, host: primary)
        let allBad = primaryResults.allSatisfy { $0.outcome == .badDeviceToken }
        if allBad && primary == Self.productionHost {
            let fallback = await fanout(env, to: devices, host: Self.sandboxHost)
            if fallback.contains(where: { $0.outcome == .delivered }) {
                cachedEndpointHost = Self.sandboxHost
            }
            return fallback
        }
        if primaryResults.contains(where: { $0.outcome == .delivered }) {
            cachedEndpointHost = primary
        }
        return primaryResults
    }

    private func fanout(_ env: ApnsEnvelope, to devices: [PushDevice], host: String) async -> [ApnsFanoutResult] {
        await withTaskGroup(of: ApnsFanoutResult.self) { group in
            for d in devices {
                group.addTask {
                    let outcome = (try? await self.send(env, to: d, host: host)) ?? .error("dispatch failed")
                    return ApnsFanoutResult(device: d, outcome: outcome)
                }
            }
            var out: [ApnsFanoutResult] = []
            for await r in group { out.append(r) }
            return out
        }
    }

    private func send(_ env: ApnsEnvelope, to device: PushDevice, host: String) async throws -> ApnsSendOutcome {
        var req = URLRequest(url: URL(string: "https://\(host)/3/device/\(device.token)")!)
        req.httpMethod = "POST"
        req.httpBody = env.payload
        req.setValue("bearer \(try jwt.token())", forHTTPHeaderField: "authorization")
        req.setValue(env.topic, forHTTPHeaderField: "apns-topic")
        req.setValue(env.pushType.rawValue, forHTTPHeaderField: "apns-push-type")
        req.setValue(env.collapseID, forHTTPHeaderField: "apns-collapse-id")
        req.setValue(String(env.priority), forHTTPHeaderField: "apns-priority")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return .error("non-HTTP response") }
        switch http.statusCode {
        case 200: return .delivered
        case 400, 410:
            let reason = (try? JSONDecoder().decode([String: String].self, from: data))?["reason"] ?? "unknown"
            if reason == "BadDeviceToken" || reason == "Unregistered" { return .badDeviceToken }
            return .error("\(http.statusCode) \(reason)")
        case 429, 500, 503:
            return .error("transient \(http.statusCode)")
        default:
            return .error("status \(http.statusCode)")
        }
    }
}
```

- [ ] **Step 4: Promote PUSH-3.1, PUSH-6.1, PUSH-6.2** — delete inventory entries.

- [ ] **Step 5: Run tests + regenerate SPECS.md**

```bash
swift test --filter ApnsClient
python3 scripts/generate-specs.py
python3 scripts/generate-specs.py --check
```

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Push/ApnsClient.swift \
        Tests/GrafttyKitTests/Push/ApnsClientTests.swift \
        Tests/GrafttyTests/Specs/PushTodo.swift SPECS.md
git commit -m "feat(push): ApnsClient HTTP/2 sender with sandbox fallback (PUSH-3.1, 6.1, 6.2)"
```

---

## Task 7: `PushClearService` (PUSH-5.1)

**Files:**
- Create: `Sources/GrafttyKit/Push/PushClearService.swift`
- Create: `Tests/GrafttyKitTests/Push/PushClearServiceTests.swift`
- Modify: `Tests/GrafttyTests/Specs/PushTodo.swift` (remove PUSH-5.1)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/GrafttyKitTests/Push/PushClearServiceTests.swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec PUSH-5.1: PushClearService sends silent-remove envelope to all live devices for previously-pushed attentions.")
struct PushClearServiceTests {
    @Test func sendsClearWhenPreviouslyPushed() async throws {
        let dedupe = PushDedupeStore()
        let path = "/r/wt"
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        dedupe.markPushed(worktree: path, attentionTimestamp: ts)
        let sender = MockEnvelopeSender()
        let store = PushDeviceStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                              .appendingPathComponent("pds-\(UUID()).json"))
        try store.register(PushDevice(token: "abc", deviceName: "iP", platform: "ios", lastRegisteredAt: ts))
        let svc = PushClearService(topic: "com.quotably.graftty", deviceStore: store,
                                   dedupe: dedupe, sender: sender)
        await svc.attentionCleared(worktreePath: path, attentionTimestamp: ts)
        #expect(sender.sentEnvelopes.count == 1)
        #expect(sender.sentEnvelopes[0].envelope.pushType == .background)
        #expect(sender.sentEnvelopes[0].envelope.collapseID == "\(path):2023-11-14T22:13:20.000Z")
    }

    @Test func skipsWhenNotPreviouslyPushed() async throws {
        let svc = PushClearService(
            topic: "com.quotably.graftty",
            deviceStore: PushDeviceStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pds-\(UUID()).json")),
            dedupe: PushDedupeStore(),
            sender: MockEnvelopeSender())
        await svc.attentionCleared(worktreePath: "/r/wt",
                                   attentionTimestamp: Date(timeIntervalSince1970: 1_700_000_000))
        // No assertion needed beyond "no crash"; nothing was pushed so nothing
        // to clear. Verified implicitly by the empty MockEnvelopeSender.
    }
}

final class MockEnvelopeSender: ApnsFanoutSender, @unchecked Sendable {
    struct Call { let envelope: ApnsEnvelope; let devices: [PushDevice] }
    var sentEnvelopes: [Call] = []
    func sendFanout(_ env: ApnsEnvelope, to devices: [PushDevice]) async -> [ApnsFanoutResult] {
        sentEnvelopes.append(Call(envelope: env, devices: devices))
        return devices.map { ApnsFanoutResult(device: $0, outcome: .delivered) }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PushClearService`
Expected: compile error.

- [ ] **Step 3: Implement `PushClearService` (and extract `ApnsFanoutSender` protocol)**

Add to top of `ApnsClient.swift` (so tests can inject a mock without spinning up URLSession):

```swift
// in Sources/GrafttyKit/Push/ApnsClient.swift
public protocol ApnsFanoutSender: Sendable {
    func sendFanout(_ env: ApnsEnvelope, to devices: [PushDevice]) async -> [ApnsFanoutResult]
}

extension ApnsClient: ApnsFanoutSender {}
```

Then create:

```swift
// Sources/GrafttyKit/Push/PushClearService.swift
import Foundation

public actor PushClearService {
    private let topic: String
    private let deviceStore: PushDeviceStore
    private let dedupe: PushDedupeStore
    private let sender: ApnsFanoutSender

    public init(topic: String, deviceStore: PushDeviceStore,
                dedupe: PushDedupeStore, sender: ApnsFanoutSender) {
        self.topic = topic
        self.deviceStore = deviceStore
        self.dedupe = dedupe
        self.sender = sender
    }

    public func attentionCleared(worktreePath: String, attentionTimestamp: Date) async {
        guard dedupe.lastPushed(forWorktree: worktreePath) == attentionTimestamp else { return }
        let env: ApnsEnvelope
        do {
            env = try ApnsEnvelope.clear(topic: topic, worktreePath: worktreePath,
                                         attentionTimestamp: attentionTimestamp)
        } catch {
            return
        }
        let devices = deviceStore.liveDevices()
        guard !devices.isEmpty else { return }
        _ = await sender.sendFanout(env, to: devices)
    }
}
```

- [ ] **Step 4: Promote PUSH-5.1** — delete inventory entry.

- [ ] **Step 5: Run tests + regenerate SPECS.md**

```bash
swift test --filter PushClearService
python3 scripts/generate-specs.py
python3 scripts/generate-specs.py --check
```

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Push/PushClearService.swift Sources/GrafttyKit/Push/ApnsClient.swift \
        Tests/GrafttyKitTests/Push/PushClearServiceTests.swift \
        Tests/GrafttyTests/Specs/PushTodo.swift SPECS.md
git commit -m "feat(push): PushClearService silent-remove path (PUSH-5.1)"
```

---

## Task 8: `POST /push/register` web endpoint (PUSH-1.1 server-side)

**Files:**
- Modify: `Sources/GrafttyKit/Web/WebServer.swift` — add `pushRegisterHandler` config + route.
- Create: `Tests/GrafttyKitTests/Web/PushRegisterEndpointTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/GrafttyKitTests/Web/PushRegisterEndpointTests.swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("POST /push/register")
struct PushRegisterEndpointTests {
    @Test func storesValidRegistration() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pds-\(UUID()).json")
        let store = PushDeviceStore(fileURL: tmp)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let cfg = WebServer.Config(
            port: 0,
            zmxExecutable: URL(fileURLWithPath: "/bin/true"),
            zmxDir: URL(fileURLWithPath: NSTemporaryDirectory()),
            pushRegisterHandler: { req in
                try? store.register(PushDevice(token: req.deviceToken,
                                               deviceName: req.deviceName,
                                               platform: req.platform,
                                               lastRegisteredAt: now))
                return PushRegisterResponse(registeredAt: now)
            }
        )
        // ... boot WebServer onto an ephemeral port, POST JSON, assert response code 200,
        // assert store.liveDevices(now: now).map(\.token) == ["abcd"].
        // (Use existing WebServer test scaffolding pattern from SocketIntegrationTests.swift)
    }
}
```

(Refer to `Tests/GrafttyKitTests/Notification/SocketIntegrationTests.swift` for the ephemeral-port bootstrap pattern used elsewhere in this codebase.)

- [ ] **Step 2: Add request/response types + Config field + route**

In `Sources/GrafttyKit/Web/WebServer.swift`:

```swift
public struct PushRegisterRequest: Codable, Sendable {
    public let deviceToken: String
    public let deviceName: String
    public let platform: String  // "ios"
}

public struct PushRegisterResponse: Codable, Sendable {
    public let registeredAt: Date
}
```

Add to `Config`:

```swift
public let pushRegisterHandler: (@Sendable (PushRegisterRequest) async -> PushRegisterResponse)?

// in init():
public init(
    port: Int,
    zmxExecutable: URL,
    zmxDir: URL,
    sessionsProvider: @escaping @Sendable () async -> [SessionInfo] = { [] },
    sessionWorktreeProvider: @escaping @Sendable (String) async -> String? = { _ in nil },
    reposProvider: @escaping @Sendable () async -> [RepoInfo] = { [] },
    worktreeCreator: (@Sendable (CreateWorktreeRequest) async -> CreateWorktreeOutcome)? = nil,
    ghosttyConfigProvider: @escaping @Sendable () async -> String = { "" },
    worktreePanesProvider: @escaping @Sendable () async -> [WorktreePanes] = { [] },
    pushRegisterHandler: (@Sendable (PushRegisterRequest) async -> PushRegisterResponse)? = nil
) {
    // ...
    self.pushRegisterHandler = pushRegisterHandler
}
```

Add route alongside `/worktrees`:

```swift
if path == "/push/register" {
    guard head.method == .POST else {
        Self.respondJSON(context: context, status: .methodNotAllowed,
                         error: "only POST is supported")
        return
    }
    handlePushRegister(context: context, body: body)
    return
}
```

And:

```swift
private func handlePushRegister(context: ChannelHandlerContext, body: Data) {
    guard let handler = config.pushRegisterHandler else {
        Self.respondJSON(context: context, status: .serviceUnavailable,
                         error: "push registration not available")
        return
    }
    let decoded: PushRegisterRequest
    do {
        decoded = try JSONDecoder().decode(PushRegisterRequest.self, from: body)
    } catch {
        Self.respondJSON(context: context, status: .badRequest,
                         error: "invalid JSON body")
        return
    }
    guard !decoded.deviceToken.isEmpty,
          !decoded.deviceName.isEmpty,
          decoded.platform == "ios" else {
        Self.respondJSON(context: context, status: .badRequest,
                         error: "deviceToken, deviceName, and platform=\"ios\" are required")
        return
    }
    let promise = context.eventLoop.makePromise(of: PushRegisterResponse.self)
    promise.futureResult.whenComplete { result in
        switch result {
        case .success(let resp):
            do {
                let data = try JSONEncoder.iso8601().encode(resp)
                Self.respond(context: context, status: .ok, body: data,
                             contentType: "application/json; charset=utf-8")
            } catch {
                Self.respondJSON(context: context, status: .internalServerError, error: "encoding error")
            }
        case .failure:
            Self.respondJSON(context: context, status: .internalServerError, error: "internal error")
        }
    }
    Task { promise.succeed(await handler(decoded)) }
}
```

- [ ] **Step 3: Run tests**

```bash
swift test --filter PushRegisterEndpoint
```
Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyKit/Web/WebServer.swift Tests/GrafttyKitTests/Web/PushRegisterEndpointTests.swift
git commit -m "feat(push): /push/register endpoint plumbing"
```

---

## Task 9: `PushConfig` + APNs resource bundling

**Files:**
- Create: `Sources/GrafttyKit/Push/PushConfig.swift`
- Modify: `Package.swift`
- Create: `Sources/Graftty/Resources/apns/.gitkeep` (placeholder directory; the actual `.p8` ships out-of-band).
- Create: `docs/push/README.md` — minting + installation checklist.

- [ ] **Step 1: Implement PushConfig**

```swift
// Sources/GrafttyKit/Push/PushConfig.swift
import Foundation

public struct PushConfig: Sendable {
    public let keyID: String
    public let teamID: String
    public let topic: String
    public let privateKeyPEM: String

    public init(keyID: String, teamID: String, topic: String, privateKeyPEM: String) {
        self.keyID = keyID
        self.teamID = teamID
        self.topic = topic
        self.privateKeyPEM = privateKeyPEM
    }

    public enum LoadError: Error, Equatable {
        case missingInfoPlistKeys
        case missingP8
        case unreadableP8
    }

    /// Load from Info.plist (`APNsKeyID`, `APNsTeamID`, `APNsTopic`) + a
    /// `.p8` at `Resources/apns/AuthKey_<KEYID>.p8`. Returns `nil` if any
    /// component is missing — caller logs and disables push, matching the
    /// "missing key → silent skip" behavior of NOTIF-1.3.
    public static func loadFromMainBundle() -> PushConfig? {
        let bundle = Bundle.main
        guard let keyID = bundle.object(forInfoDictionaryKey: "APNsKeyID") as? String,
              let teamID = bundle.object(forInfoDictionaryKey: "APNsTeamID") as? String,
              let topic = bundle.object(forInfoDictionaryKey: "APNsTopic") as? String,
              !keyID.isEmpty, !teamID.isEmpty, !topic.isEmpty
        else { return nil }
        guard let p8URL = bundle.url(forResource: "AuthKey_\(keyID)", withExtension: "p8",
                                     subdirectory: "apns") else { return nil }
        guard let pem = try? String(contentsOf: p8URL, encoding: .utf8) else { return nil }
        return PushConfig(keyID: keyID, teamID: teamID, topic: topic, privateKeyPEM: pem)
    }
}
```

- [ ] **Step 2: Update Package.swift to bundle the apns resource dir into the Graftty target**

In `Package.swift`, find the `Graftty` `.executableTarget(...)` and add:

```swift
.executableTarget(
    name: "Graftty",
    dependencies: [
        "GrafttyKit",
        "GrafttyProtocol",
        .product(name: "GhosttyKit", package: "libghostty-spm"),
        .product(name: "Sparkle", package: "Sparkle"),
        .product(name: "Stencil", package: "Stencil"),
    ],
    resources: [
        .copy("Resources/apns"),
    ],
    swiftSettings: strictWarnings
),
```

Create the placeholder directory:

```bash
mkdir -p Sources/Graftty/Resources/apns
touch Sources/Graftty/Resources/apns/.gitkeep
```

- [ ] **Step 3: Write the manual checklist**

```markdown
<!-- docs/push/README.md -->
# Push Notifications: Minting and Installing the APNs Auth Key

Push notifications require a `.p8` APNs Auth Key minted from Apple's developer
portal. This is a one-time setup per Graftty release.

## Minting

1. Visit https://developer.apple.com/account/resources/authkeys/list.
2. Click "+" to create a new key.
3. Name it "Graftty APNs" and check **Apple Push Notifications service (APNs)**.
4. Choose **Sandbox & Production** (one key supports both environments).
5. Register, then **download the .p8 immediately** — Apple only allows one download.
6. Note the **Key ID** (e.g. `ABCDE12345`) and your **Team ID** (top-right of the page).

## Installing into Graftty.app source tree

1. Place the file at `Sources/Graftty/Resources/apns/AuthKey_<KEYID>.p8` (do not commit it — `.gitignore` excludes the directory contents).
2. Add to `Apps/GrafttyMobile/GrafttyMobile/Info.plist` (already templated via project.yml):
   ```
   APNsKeyID:  <KEYID>
   APNsTeamID: <TEAMID>
   APNsTopic:  com.quotably.graftty
   ```
3. The same three keys go into the macOS app's Info.plist (`Sources/Graftty/Info.plist` if present, or via SwiftPM's bundle plist).

## End-to-end verification

1. Build Graftty for macOS: `swift build`. Run from Xcode or `.build/debug/Graftty`.
2. Build GrafttyMobile to a real iOS device (simulator does not receive APNs pushes): open `Apps/GrafttyMobile/GrafttyMobile.xcodeproj`, select your device, Cmd-R.
3. Add your Mac as a host in GrafttyMobile, accept the notification prompt.
4. On the Mac, observe a record in `~/Library/Application Support/Graftty/push-devices.json`.
5. Trigger an agent stop (e.g. `claude` in a Graftty worktree, ask it a question, wait for it to finish). The macOS banner appears.
6. Lock the Mac. Trigger another agent stop. Within ~5s an iOS banner should appear.
7. Tap the banner → GrafttyMobile opens to the waiting pane.
8. Unlock the Mac, click the macOS banner → iOS banner is removed.

If the iOS banner never appears, check:
- Console.app filtered by `Graftty` for `ApnsClient` errors.
- The `.p8` file exists at the expected path in the built `.app` (`Graftty.app/Contents/Resources/apns/AuthKey_<KEYID>.p8`).
- iOS Settings → Notifications → Graftty is allowed.
```

Add to `.gitignore`:

```
# APNs keys — minted per-developer, never committed
Sources/Graftty/Resources/apns/*.p8
```

- [ ] **Step 4: Build + commit**

```bash
swift build
git add Sources/GrafttyKit/Push/PushConfig.swift Package.swift \
        Sources/Graftty/Resources/apns/.gitkeep docs/push/README.md .gitignore
git commit -m "feat(push): bundle APNs .p8 resource path + manual setup doc"
```

---

## Task 10: `PushOrchestrator` + wire into `recordAgentStop` / `clearAttentionIfTimestamp`

**Files:**
- Create: `Sources/Graftty/Push/PushOrchestrator.swift`
- Create: `Sources/Graftty/Push/CGEventActivitySource.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`

- [ ] **Step 1: Implement the concrete activity source**

```swift
// Sources/Graftty/Push/CGEventActivitySource.swift
import AppKit
import CoreGraphics
import GrafttyKit

/// Production `DesktopActivitySource`. Observes screen lock/unlock,
/// sleep/wake, and refreshes a cached "last input age" via
/// CGEventSourceSecondsSinceLastEventType on a 5s timer.
@MainActor
final class CGEventActivitySource: DesktopActivitySource {
    private(set) var systemAsleep = false
    private(set) var screenLocked = false
    private(set) var lastInputAgeSeconds: TimeInterval = 0
    private var timer: Timer?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(willSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenLockedNote),
                        name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenUnlockedNote),
                        name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshIdle()
        }
        refreshIdle()
    }

    @objc private func willSleep() { systemAsleep = true }
    @objc private func didWake() { systemAsleep = false; refreshIdle() }
    @objc private func screenLockedNote() { screenLocked = true }
    @objc private func screenUnlockedNote() { screenLocked = false }

    private func refreshIdle() {
        lastInputAgeSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                                      eventType: .init(rawValue: ~0)!)
    }
}
```

- [ ] **Step 2: Implement the orchestrator**

```swift
// Sources/Graftty/Push/PushOrchestrator.swift
import Foundation
import GrafttyKit

/// Shared glue holding the singletons that recordAgentStop /
/// clearAttentionIfTimestamp call into. Constructed once at app launch
/// in GrafttyApp; nil out if PushConfig.loadFromMainBundle() returns nil
/// (push is disabled).
@MainActor
final class PushOrchestrator {
    static var shared: PushOrchestrator?

    let deviceStore: PushDeviceStore
    let dedupe: PushDedupeStore
    let activity: DesktopActivityMonitor
    let apns: ApnsClient
    let clearService: PushClearService
    let topic: String

    init?() {
        guard let config = PushConfig.loadFromMainBundle() else {
            NSLog("Graftty: push disabled — APNs config or .p8 missing")
            return nil
        }
        let source = CGEventActivitySource()
        let store = PushDeviceStore()
        let dedupe = PushDedupeStore()
        let activity = DesktopActivityMonitor(source: source)
        do {
            let jwt = try ApnsJWT(privateKeyPEM: config.privateKeyPEM,
                                  keyID: config.keyID, teamID: config.teamID)
            let session = URLSession(configuration: .default)
            let apns = ApnsClient(jwt: jwt, session: session, topic: config.topic)
            self.deviceStore = store
            self.dedupe = dedupe
            self.activity = activity
            self.apns = apns
            self.clearService = PushClearService(topic: config.topic,
                                                 deviceStore: store,
                                                 dedupe: dedupe, sender: apns)
            self.topic = config.topic
        } catch {
            NSLog("Graftty: push disabled — JWT init failed: \(error)")
            return nil
        }
    }

    /// Handles a fresh agent-stop signal: decides if a push should fire,
    /// builds the alert envelope, fans out to every live device.
    func handleAgentStop(payload: AgentStopNotificationPayload, worktreeName: String) async {
        guard AttentionPushDecider.shouldPush(payload: payload,
                                              isUserActiveOnDesktop: activity.isUserActiveOnDesktop,
                                              dedupe: dedupe) else { return }
        let content = AgentStopNotification.content(
            runtime: payload.runtime, worktreeName: worktreeName,
            worktreePath: payload.worktreePath, sessionID: payload.sessionID,
            timestamp: payload.attentionTimestamp)
        do {
            let env = try ApnsEnvelope.alert(
                topic: topic,
                worktreePath: payload.worktreePath,
                attentionTimestamp: payload.attentionTimestamp,
                content: content)
            let devices = deviceStore.liveDevices()
            guard !devices.isEmpty else { return }
            let results = await apns.sendFanout(env, to: devices)
            for r in results where r.outcome == .badDeviceToken {
                try? deviceStore.remove(token: r.device.token)
            }
            dedupe.markPushed(worktree: payload.worktreePath,
                              attentionTimestamp: payload.attentionTimestamp)
        } catch {
            NSLog("Graftty: push send failed: \(error)")
        }
    }

    /// Called from clearAttentionIfTimestamp callers.
    func handleAttentionCleared(worktreePath: String, attentionTimestamp: Date) async {
        await clearService.attentionCleared(worktreePath: worktreePath,
                                            attentionTimestamp: attentionTimestamp)
    }

    /// Routes /push/register POST bodies into the device store.
    nonisolated func handleRegister(_ req: PushRegisterRequest) -> PushRegisterResponse {
        let now = Date()
        try? deviceStore.register(PushDevice(token: req.deviceToken,
                                             deviceName: req.deviceName,
                                             platform: req.platform,
                                             lastRegisteredAt: now))
        return PushRegisterResponse(registeredAt: now)
    }
}
```

- [ ] **Step 3: Initialize from `GrafttyApp.init` and wire into both callsites**

In `Sources/Graftty/GrafttyApp.swift`:

1. Near the existing `AgentNotificationRouter` singleton init (around line 60-150), add:
   ```swift
   private static let pushOrchestrator: PushOrchestrator? = {
       MainActor.assumeIsolated { PushOrchestrator() }
   }()
   ```
2. In `recordAgentStop(...)` (around line 1911), after the existing `agentNotificationRouter.post(...)` call, add:
   ```swift
   if let orch = Self.pushOrchestrator {
       let payload = AgentStopNotificationPayload(
           runtime: runtime, worktreePath: worktreePath,
           sessionID: sessionID, attentionTimestamp: timestamp)
       Task { await orch.handleAgentStop(payload: payload, worktreeName: worktreeName) }
   }
   ```
3. Find the two `clearAttentionIfTimestamp(stamp)` callsites at GrafttyApp.swift:1609 and :1675. After each, add:
   ```swift
   if let orch = Self.pushOrchestrator {
       Task { await orch.handleAttentionCleared(worktreePath: <path>, attentionTimestamp: <stamp>) }
   }
   ```
   Use the correct `<path>` and `<stamp>` from the surrounding scope at each site.
4. In `WebServerController` (`Sources/Graftty/Web/WebServerController.swift`), wire `pushRegisterHandler`:
   ```swift
   // wherever the existing Config is built
   pushRegisterHandler: { [orch = GrafttyApp.pushOrchestrator] req in
       orch?.handleRegister(req) ?? PushRegisterResponse(registeredAt: Date())
   }
   ```

- [ ] **Step 4: Build + run tests**

```bash
swift build
swift test
```
Expected: build succeeds; all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/Push/PushOrchestrator.swift \
        Sources/Graftty/Push/CGEventActivitySource.swift \
        Sources/Graftty/GrafttyApp.swift Sources/Graftty/Web/WebServerController.swift
git commit -m "feat(push): wire PushOrchestrator into recordAgentStop and attention-clear sites"
```

---

## Task 11: iOS — entitlements + `PushAppDelegate` + `PushRegistrar` (PUSH-1.1, PUSH-1.2)

**Files:**
- Modify: `Apps/GrafttyMobile/project.yml`
- Create: `Apps/GrafttyMobile/GrafttyMobile/GrafttyMobile.entitlements`
- Create: `Sources/GrafttyMobileKit/Push/PushAppDelegate.swift`
- Create: `Sources/GrafttyMobileKit/Push/PushRegistrar.swift`
- Create: `Tests/GrafttyMobileKitTests/Push/PushRegistrarTests.swift`
- Modify: `Tests/GrafttyTests/Specs/PushTodo.swift` (remove PUSH-1.1, 1.2)
- Modify: `Sources/GrafttyMobileKit/App/GrafttyMobileApp.swift`
- Modify: `Sources/GrafttyMobileKit/Hosts/HostStore.swift` — conform to `PushHostSource` (so `PushAppDelegate.init` can construct the registrar from `HostStore.shared`).

- [ ] **Step 1: Add the iOS entitlement file**

```xml
<!-- Apps/GrafttyMobile/GrafttyMobile/GrafttyMobile.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>aps-environment</key>
    <string>development</string>
</dict>
</plist>
```

In `Apps/GrafttyMobile/project.yml`, add the entitlements build setting under `targets.GrafttyMobile.settings.base`:

```yaml
        CODE_SIGN_ENTITLEMENTS: GrafttyMobile/GrafttyMobile.entitlements
```

Regenerate the xcodeproj (xcodegen) per the project's existing convention (or manually update `Apps/GrafttyMobile/GrafttyMobile.xcodeproj/project.pbxproj` to reference the entitlements file).

- [ ] **Step 2: Write the failing test**

```swift
// Tests/GrafttyMobileKitTests/Push/PushRegistrarTests.swift
#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite("PushRegistrar")
struct PushRegistrarTests {
    private struct FakeHostStore: PushHostSource {
        let hosts: [PushTargetHost]
    }

    private final class CapturingNetwork: PushRegisterNetwork, @unchecked Sendable {
        struct Call { let baseURL: URL; let body: PushRegisterRequest }
        var calls: [Call] = []
        func register(baseURL: URL, body: PushRegisterRequest) async throws {
            calls.append(Call(baseURL: baseURL, body: body))
        }
    }

    @Test("@spec PUSH-1.1: registers token with every host on registerWithAllHosts.")
    func push_1_1_fansToEveryHost() async throws {
        let hosts: [PushTargetHost] = [
            .init(baseURL: URL(string: "http://h1.local")!, lastUsedAt: Date()),
            .init(baseURL: URL(string: "http://h2.local")!, lastUsedAt: Date()),
        ]
        let net = CapturingNetwork()
        let registrar = PushRegistrar(hostSource: FakeHostStore(hosts: hosts), network: net,
                                      deviceName: "iPhone-Test")
        await registrar.deviceTokenDidArrive(token: "deadbeef")
        await registrar.registerWithAllHosts()
        #expect(net.calls.count == 2)
        #expect(Set(net.calls.map(\.baseURL.host!)) == ["h1.local", "h2.local"])
        #expect(net.calls.allSatisfy { $0.body.deviceToken == "deadbeef" })
    }

    @Test("@spec PUSH-1.2: no register call when authorization denied (no token captured).")
    func push_1_2_skipsWithoutToken() async throws {
        let net = CapturingNetwork()
        let registrar = PushRegistrar(hostSource: FakeHostStore(hosts: [
            .init(baseURL: URL(string: "http://h.local")!, lastUsedAt: Date())
        ]), network: net, deviceName: "iPhone")
        // Never call deviceTokenDidArrive(...) — simulating denied authorization.
        await registrar.registerWithAllHosts()
        #expect(net.calls.isEmpty)
    }
}
#endif
```

- [ ] **Step 3: Run to verify failure**

```bash
xcodebuild test -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
                -scheme GrafttyMobile \
                -destination 'platform=iOS Simulator,name=iPhone 15' \
                -only-testing:GrafttyMobileKitTests/PushRegistrarTests \
                2>&1 | tail -20
```
Expected: compile errors (`PushRegistrar` etc. undefined).

- [ ] **Step 4: Implement `PushRegistrar` and supporting types**

```swift
// Sources/GrafttyMobileKit/Push/PushRegistrar.swift
#if canImport(UIKit)
import Foundation
import UIKit
import UserNotifications

/// Minimal view of a host the registrar can reach.
public struct PushTargetHost: Sendable, Equatable {
    public let baseURL: URL
    public let lastUsedAt: Date
    public init(baseURL: URL, lastUsedAt: Date) {
        self.baseURL = baseURL; self.lastUsedAt = lastUsedAt
    }
}

public protocol PushHostSource: AnyObject, Sendable {
    var hosts: [PushTargetHost] { get }
}

public protocol PushRegisterNetwork: Sendable {
    func register(baseURL: URL, body: PushRegisterRequest) async throws
}

public struct PushRegisterRequest: Codable, Sendable {
    public let deviceToken: String
    public let deviceName: String
    public let platform: String  // "ios"
    public init(deviceToken: String, deviceName: String, platform: String) {
        self.deviceToken = deviceToken; self.deviceName = deviceName; self.platform = platform
    }
}

/// Owns the iOS APNs lifecycle: authorization request, token capture
/// (via AppDelegate), and per-host POST /push/register fanout.
/// Held as an instance var on `PushAppDelegate` (no singleton) so the
/// constructor's dependencies are always live.
public actor PushRegistrar {
    private let hostSource: PushHostSource
    private let network: PushRegisterNetwork
    private let deviceName: String
    private var deviceToken: String?

    public init(hostSource: PushHostSource, network: PushRegisterNetwork, deviceName: String) {
        self.hostSource = hostSource
        self.network = network
        self.deviceName = deviceName
    }

    public func deviceTokenDidArrive(token: String) {
        deviceToken = token
    }

    public func requestAuthorizationAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { return }   // PUSH-1.2
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            NSLog("PushRegistrar: authorization failed: \(error)")
        }
    }

    /// PUSH-1.1: fan out to every host with lastUsedAt within 90 days.
    public func registerWithAllHosts() async {
        guard let token = deviceToken else { return }
        let now = Date()
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        let live = hostSource.hosts.filter { $0.lastUsedAt > cutoff }
        for host in live {
            let body = PushRegisterRequest(deviceToken: token, deviceName: deviceName, platform: "ios")
            do {
                try await network.register(baseURL: host.baseURL, body: body)
            } catch {
                NSLog("PushRegistrar: register at \(host.baseURL) failed: \(error)")
            }
        }
    }
}

/// Concrete `PushRegisterNetwork` using URLSession.
public final class URLSessionPushNetwork: PushRegisterNetwork {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func register(baseURL: URL, body: PushRegisterRequest) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("push/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

#endif
```

- [ ] **Step 4b: Conform `HostStore` to `PushHostSource`**

In `Sources/GrafttyMobileKit/Hosts/HostStore.swift`, add at the bottom (adjusting field names to match the actual `Host` struct — read the file before editing to confirm names; the existing record holds at least a `URL` and a `lastUsedAt` per IOS-2.3):

```swift
#if canImport(UIKit)
extension HostStore: PushHostSource {
    public var hosts: [PushTargetHost] {
        // `savedHosts` is the existing in-memory list. Replace the field
        // names below with the live ones if they differ (e.g. `baseURL`
        // → `host.baseURL`).
        savedHosts.map { PushTargetHost(baseURL: $0.baseURL, lastUsedAt: $0.lastUsedAt) }
    }
}
#endif
```

- [ ] **Step 5: Implement `PushAppDelegate`**

```swift
// Sources/GrafttyMobileKit/Push/PushAppDelegate.swift
#if canImport(UIKit)
import UIKit
import UserNotifications

public final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Exposed for foreground triggers (RootView observes scenePhase and
    /// calls `registerWithAllHosts()` on `.active`).
    public private(set) static var registrar: PushRegistrar!

    public override init() {
        super.init()
        Self.registrar = PushRegistrar(
            hostSource: HostStore.shared,
            network: URLSessionPushNetwork(),
            deviceName: UIDevice.current.name)
    }

    public func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { await Self.registrar.requestAuthorizationAndRegister() }
        return true
    }

    public func application(_ application: UIApplication,
                            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            await Self.registrar.deviceTokenDidArrive(token: hex)
            await Self.registrar.registerWithAllHosts()
        }
    }

    public func application(_ application: UIApplication,
                            didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("PushAppDelegate: APNs registration failed: \(error)")
    }
}
#endif
```

- [ ] **Step 6: Wire `@UIApplicationDelegateAdaptor`**

In `Sources/GrafttyMobileKit/App/GrafttyMobileApp.swift`, add:

```swift
@UIApplicationDelegateAdaptor(PushAppDelegate.self) var appDelegate
```

- [ ] **Step 7: Promote PUSH-1.1, PUSH-1.2** — delete inventory entries.

- [ ] **Step 8: Run tests + regenerate SPECS.md**

```bash
xcodebuild test -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile \
                -destination 'platform=iOS Simulator,name=iPhone 15' \
                -only-testing:GrafttyMobileKitTests/PushRegistrarTests
python3 scripts/generate-specs.py
python3 scripts/generate-specs.py --check
```

- [ ] **Step 9: Commit**

```bash
git add Apps/GrafttyMobile/project.yml \
        Apps/GrafttyMobile/GrafttyMobile/GrafttyMobile.entitlements \
        Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
        Sources/GrafttyMobileKit/Push/ \
        Sources/GrafttyMobileKit/App/GrafttyMobileApp.swift \
        Tests/GrafttyMobileKitTests/Push/PushRegistrarTests.swift \
        Tests/GrafttyTests/Specs/PushTodo.swift SPECS.md
git commit -m "feat(push): iOS PushRegistrar + AppDelegate + APNs entitlement (PUSH-1.1, 1.2)"
```

---

## Task 12: iOS — `PushReceiver` silent-remove handler (PUSH-5.2)

**Files:**
- Create: `Sources/GrafttyMobileKit/Push/PushReceiver.swift`
- Create: `Tests/GrafttyMobileKitTests/Push/PushReceiverTests.swift`
- Modify: `Sources/GrafttyMobileKit/Push/PushAppDelegate.swift` — route remote-notification + tap callbacks to `PushReceiver`.
- Modify: `Tests/GrafttyTests/Specs/PushTodo.swift` (remove PUSH-5.2)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/GrafttyMobileKitTests/Push/PushReceiverTests.swift
#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite("@spec PUSH-5.2: PushReceiver removes the delivered notification on agent_stop_clear.")
struct PushReceiverTests {
    private final class FakeCenter: NotificationCenterRemover, @unchecked Sendable {
        var removedIDs: [String] = []
        func removeDeliveredNotifications(withIdentifiers ids: [String]) {
            removedIDs.append(contentsOf: ids)
        }
    }

    @Test func handlesAgentStopClear() async {
        let center = FakeCenter()
        let recv = PushReceiver(remover: center)
        let userInfo: [String: Any] = [
            "kind": "agent_stop_clear",
            "collapse_id": "/r/wt:2026-05-13T12:00:00.000Z",
        ]
        let handled = await recv.handleSilentPush(userInfo: userInfo)
        #expect(handled == true)
        #expect(center.removedIDs == ["/r/wt:2026-05-13T12:00:00.000Z"])
    }

    @Test func ignoresUnknownKind() async {
        let center = FakeCenter()
        let recv = PushReceiver(remover: center)
        let handled = await recv.handleSilentPush(userInfo: ["kind": "something_else"])
        #expect(handled == false)
        #expect(center.removedIDs.isEmpty)
    }
}
#endif
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild test -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile \
                -destination 'platform=iOS Simulator,name=iPhone 15' \
                -only-testing:GrafttyMobileKitTests/PushReceiverTests
```
Expected: compile error.

- [ ] **Step 3: Implement `PushReceiver`**

```swift
// Sources/GrafttyMobileKit/Push/PushReceiver.swift
#if canImport(UIKit)
import Foundation
import UserNotifications

public protocol NotificationCenterRemover: Sendable {
    func removeDeliveredNotifications(withIdentifiers ids: [String])
}

extension UNUserNotificationCenter: NotificationCenterRemover {}

public actor PushReceiver {
    private let remover: NotificationCenterRemover

    public init(remover: NotificationCenterRemover = UNUserNotificationCenter.current()) {
        self.remover = remover
    }

    /// Called from AppDelegate's didReceiveRemoteNotification. Returns true
    /// if the receiver matched a known silent-push kind.
    public func handleSilentPush(userInfo: [AnyHashable: Any]) async -> Bool {
        guard let kind = userInfo["kind"] as? String, kind == "agent_stop_clear" else { return false }
        guard let collapseID = userInfo["collapse_id"] as? String else { return false }
        remover.removeDeliveredNotifications(withIdentifiers: [collapseID])
        return true
    }
}
#endif
```

- [ ] **Step 4: Wire into `PushAppDelegate`**

```swift
// in Sources/GrafttyMobileKit/Push/PushAppDelegate.swift, add:
public func application(_ application: UIApplication,
                        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    Task {
        let handled = await PushReceiver().handleSilentPush(userInfo: userInfo)
        completionHandler(handled ? .newData : .noData)
    }
}
```

When posting alerts as `request.identifier`, use the collapse-id so the remove call matches. The Mac already sets `apns-collapse-id` — APNs uses that as the system identifier on the iOS side, so no change needed on the alert path.

- [ ] **Step 5: Promote PUSH-5.2**.

- [ ] **Step 6: Run tests + regenerate SPECS.md**

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyMobileKit/Push/PushReceiver.swift \
        Sources/GrafttyMobileKit/Push/PushAppDelegate.swift \
        Tests/GrafttyMobileKitTests/Push/PushReceiverTests.swift \
        Tests/GrafttyTests/Specs/PushTodo.swift SPECS.md
git commit -m "feat(push): iOS PushReceiver silent-remove handler (PUSH-5.2)"
```

---

## Task 13: iOS — `DeepLinkRouter` + tap routing (PUSH-4.1, PUSH-4.2)

**Files:**
- Create: `Sources/GrafttyMobileKit/Push/DeepLinkRouter.swift`
- Create: `Tests/GrafttyMobileKitTests/Push/DeepLinkRouterTests.swift`
- Modify: `Sources/GrafttyMobileKit/Push/PushAppDelegate.swift` — implement `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift` — observe router and reconstruct NavigationPath.
- Modify: `Tests/GrafttyTests/Specs/PushTodo.swift` (remove PUSH-4.1, 4.2)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/GrafttyMobileKitTests/Push/DeepLinkRouterTests.swift
#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit
@testable import GrafttyKit

@Suite("DeepLinkRouter")
struct DeepLinkRouterTests {
    @Test("@spec PUSH-4.1: tap payload becomes a pending pane target.")
    func push_4_1_publishesTarget() {
        let router = DeepLinkRouter()
        let userInfo: [String: String] = [
            "kind": "agent_stop",
            "runtime": "claude",
            "worktree_path": "/r/wt",
            "session_id": "sess",
            "attention_timestamp": "2026-05-13T12:00:00Z",
        ]
        router.handleTap(userInfo: userInfo, isAppLocked: false)
        #expect(router.pendingTarget?.worktreePath == "/r/wt")
        #expect(router.pendingTarget?.sessionID == "sess")
    }

    @Test("@spec PUSH-4.2: while locked, target is queued; flushed on unlock.")
    func push_4_2_queuesWhileLocked() {
        let router = DeepLinkRouter()
        let userInfo: [String: String] = [
            "kind": "agent_stop",
            "runtime": "claude",
            "worktree_path": "/r/wt",
            "session_id": "sess",
            "attention_timestamp": "2026-05-13T12:00:00Z",
        ]
        router.handleTap(userInfo: userInfo, isAppLocked: true)
        #expect(router.pendingTarget == nil)
        router.unlockDidSucceed()
        #expect(router.pendingTarget?.worktreePath == "/r/wt")
    }

    @Test func ignoresMalformedPayloads() {
        let router = DeepLinkRouter()
        router.handleTap(userInfo: ["kind": "agent_stop_clear"], isAppLocked: false)
        #expect(router.pendingTarget == nil)
    }
}
#endif
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild test ... -only-testing:GrafttyMobileKitTests/DeepLinkRouterTests
```
Expected: compile error.

- [ ] **Step 3: Implement `DeepLinkRouter`**

```swift
// Sources/GrafttyMobileKit/Push/DeepLinkRouter.swift
#if canImport(UIKit)
import Foundation
import Observation
import GrafttyKit

public struct DeepLinkTarget: Equatable, Sendable {
    public let worktreePath: String
    public let sessionID: String
    public let runtime: TeamHookRuntime
}

@MainActor
@Observable
public final class DeepLinkRouter {
    public static let shared = DeepLinkRouter()

    public private(set) var pendingTarget: DeepLinkTarget?
    private var queuedWhileLocked: DeepLinkTarget?

    public init() {}

    /// PUSH-4.1: decode the userInfo payload and publish the target.
    /// PUSH-4.2: if the app is locked, queue and flush on unlockDidSucceed.
    public func handleTap(userInfo: [AnyHashable: Any], isAppLocked: Bool) {
        let stringified = userInfo.reduce(into: [String: Any]()) { $0[String(describing: $1.key)] = $1.value }
        guard let payload = try? AgentStopNotification.payload(from: stringified) else { return }
        let target = DeepLinkTarget(worktreePath: payload.worktreePath,
                                    sessionID: payload.sessionID, runtime: payload.runtime)
        if isAppLocked {
            queuedWhileLocked = target
        } else {
            pendingTarget = target
        }
    }

    public func unlockDidSucceed() {
        if let queued = queuedWhileLocked {
            pendingTarget = queued
            queuedWhileLocked = nil
        }
    }

    public func consume() {
        pendingTarget = nil
    }
}
#endif
```

- [ ] **Step 4: Wire into `PushAppDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`**

```swift
public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                   didReceive response: UNNotificationResponse,
                                   withCompletionHandler completionHandler: @escaping () -> Void) {
    Task { @MainActor in
        let locked = AuthGate.shared.isLocked
        DeepLinkRouter.shared.handleTap(
            userInfo: response.notification.request.content.userInfo,
            isAppLocked: locked)
        completionHandler()
    }
}

public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                   willPresent notification: UNNotification,
                                   withCompletionHandler completionHandler:
                                   @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .sound])
}
```

If `AuthGate.shared.isLocked` doesn't exist in the current `GrafttyMobileKit` (the IOS-3.1 lock implementation), substitute the actual property. If the project uses a different name, use that name verbatim.

- [ ] **Step 5: Have `RootView` observe `DeepLinkRouter`**

In `Sources/GrafttyMobileKit/App/RootView.swift`, add:

```swift
.onChange(of: DeepLinkRouter.shared.pendingTarget) { _, target in
    guard let target else { return }
    // Find the host that owns this worktreePath (HostStore knows the mapping
    // via /worktrees/panes recent fetch — fall back to the most-recently-used
    // host if the path isn't yet associated).
    if let host = HostStore.shared.bestHost(forWorktreePath: target.worktreePath) {
        navigationPath = NavigationPath([
            HostPickerRoute.host(host),
            WorktreePickerRoute.worktree(target.worktreePath),
            PaneRoute.session(target.sessionID),
        ])
    }
    DeepLinkRouter.shared.consume()
}
.onReceive(AuthGate.shared.unlockPublisher) {
    DeepLinkRouter.shared.unlockDidSucceed()
}
```

If `HostStore.bestHost(forWorktreePath:)` doesn't exist yet, add it as a simple helper that returns the most-recently-used host (an honest approximation for v1).

- [ ] **Step 6: Promote PUSH-4.1, PUSH-4.2** — delete inventory entries.

- [ ] **Step 7: Run tests + regenerate SPECS.md**

- [ ] **Step 8: Commit**

```bash
git add Sources/GrafttyMobileKit/Push/DeepLinkRouter.swift \
        Sources/GrafttyMobileKit/Push/PushAppDelegate.swift \
        Sources/GrafttyMobileKit/App/RootView.swift \
        Sources/GrafttyMobileKit/Hosts/HostStore.swift \
        Tests/GrafttyMobileKitTests/Push/DeepLinkRouterTests.swift \
        Tests/GrafttyTests/Specs/PushTodo.swift SPECS.md
git commit -m "feat(push): iOS DeepLinkRouter + tap-to-pane routing (PUSH-4.1, 4.2)"
```

---

## Task 14: Wire foreground + host-add triggers for re-registration

**Files:**
- Modify: `Sources/GrafttyMobileKit/Hosts/HostStore.swift` — call `registerWithAllHosts()` after `add(_:)`.
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift` (or `GrafttyMobileApp.swift`) — call `registerWithAllHosts()` on `.scenePhase == .active`.

- [ ] **Step 1: Re-register on foreground**

In the scene-phase observer (likely `RootView.body`), add:

```swift
.onChange(of: scenePhase) { _, phase in
    if phase == .active {
        Task { await PushAppDelegate.registrar.registerWithAllHosts() }
    }
}
```

- [ ] **Step 2: Re-register on `HostStore.add(_:)`**

In `HostStore.add(_:)` after the `lastUsedAt` mutation that the function already does (see IOS-2.3), fire-and-forget:

```swift
Task { await PushAppDelegate.registrar.registerWithAllHosts() }
```

- [ ] **Step 3: Build the iOS app**

```bash
xcodebuild build -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile \
                 -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -20
```
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyMobileKit/Hosts/HostStore.swift \
        Sources/GrafttyMobileKit/App/RootView.swift
git commit -m "feat(push): foreground + host-add re-registration triggers"
```

---

## Task 15: Final spec regeneration + smoke pass

- [ ] **Step 1: Verify all PUSH specs are real `@Test`s and the inventory is empty (or holds only deferred items)**

```bash
grep -rn "@spec PUSH" Tests/ Sources/
```
Every PUSH-1..6 spec should appear in a real `@Test` somewhere under `Tests/GrafttyKitTests/Push` or `Tests/GrafttyMobileKitTests/Push`. The inventory file `Tests/GrafttyTests/Specs/PushTodo.swift` should be empty (just `@Suite` + empty body) or deleted entirely.

- [ ] **Step 2: Run the full test suite and the SPECS check**

```bash
swift test
python3 scripts/generate-specs.py
python3 scripts/generate-specs.py --check
```
Expected: all tests pass; `--check` exits 0.

- [ ] **Step 3: Build the iOS app**

```bash
xcodebuild build -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile \
                 -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -10
```

- [ ] **Step 4: Commit any cleanup**

```bash
git add -A
git diff --cached --stat
# If nothing remains, skip this commit.
git commit -m "chore(push): final spec regeneration" || true
```

---

## Self-review notes (executor: read once before starting)

1. **Spec coverage:** Tasks 1–14 each cite the PUSH spec they implement. Task 15 is the close-out audit.
2. **`AgentStopNotification.content` reuse:** Task 6 (`ApnsEnvelope.alert`) and Task 10 (`PushOrchestrator.handleAgentStop`) both feed off this same existing API. Don't duplicate — the spec keeps the userInfo identical to the macOS banner deliberately.
3. **TDD discipline:** every test step references a spec ID, every test fails before the implementation step is begun (per CLAUDE.md). Don't skip the failure check.
4. **macOS vs iOS test runners:** `Tests/GrafttyKitTests/` runs under `swift test`. `Tests/GrafttyMobileKitTests/` runs only under `xcodebuild test` because of UIKit guards. Don't try to run mobile tests via `swift test` — they won't execute.
5. **Strict warnings:** Debug builds have `-warnings-as-errors`. Be careful with unused `let`s, deprecated APIs, and concurrency warnings.
6. **`.p8` file is gitignored:** The plan creates `Resources/apns/.gitkeep` so the directory exists; the actual `AuthKey_<KEYID>.p8` is minted manually per `docs/push/README.md` and never committed.
7. **Sandbox vs production:** A development-signed iOS build only receives sandbox pushes. The Mac auto-detects via `PUSH-6.2`'s fallback, so the test rig works without manual configuration.
8. **iOS simulator can't receive APNs pushes.** End-to-end push verification requires a real device. Document this in the manual checklist.

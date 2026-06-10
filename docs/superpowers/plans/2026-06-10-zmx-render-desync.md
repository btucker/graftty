# zmx Render Desync — Conditional Silent Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the IOS-12.1 silent gate conditional on actual remote-client attachment so the zmx PTY winsize always matches libghostty's grid in the Mac-only case, eliminating jumbled output.

**Architecture:** A new `RemoteAttachmentRegistry` (GrafttyKit) counts remote clients per zmx session, fed by both remote attach paths (`WebSession`, `ZmxAttachStream`). `HostManagedZmxBackend` consults it: while silent, resize callbacks forward to the PTY immediately unless a remote client is attached OR layout hasn't settled yet. Engagement flush uses the surface's *current* grid size plus a forced refresh. When the last remote client detaches, still-silent panes sync immediately.

**Tech Stack:** Swift 5.9+, Swift Testing (`@Test`/`@Suite`), XCTest (existing SSH tests), SwiftNIO (web/SSH paths), libghostty C API.

**Spec doc:** `docs/superpowers/specs/2026-06-10-zmx-render-desync-design.md`

**Key semantics (read first):**
- The backend has three gating inputs: `attachState` (`.silent`/`.engaged`, flips on first user input — unchanged), a new `layoutSettled` flag (flips when the NSView first gets a nonzero frame), and a new `hasRemoteClient()` closure.
- A silent-state viewport callback is **withheld** iff `!layoutSettled || hasRemoteClient()`. Otherwise it forwards to the PTY (without flipping engagement).
- `markLayoutSettled()` runs a one-shot PTY←grid sync when silent and no remote attached.
- Engagement flush resizes to `currentGridSize()` (fallback: last withheld callback) and calls `requestRefresh()`.
- `remoteClientsDidDetach()` does the same sync if still silent.
- Locking rule: `RemoteAttachmentRegistry` must NEVER invoke `onLastDetach` while holding its own lock (the backend calls `isRemoteAttached` under the backend lock; the detach path takes the backend lock via the observer — holding the registry lock across the callback would deadlock).
- Conventions: every test title carries `@spec` EARS text per CLAUDE.md; **no literal quote characters inside @spec titles** (silently truncates SPECS.md). Run `scripts/generate-specs.py` after spec changes.

---

### Task 1: `RemoteAttachmentRegistry` (GrafttyKit)

**Files:**
- Create: `Sources/GrafttyKit/RemoteAttachmentRegistry.swift`
- Create: `Tests/GrafttyKitTests/RemoteAttachmentRegistryTests.swift`

- [ ] **Step 1.1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec TERM-11.5: The application shall track the number of remote clients attached to each zmx session; a session is remote-attached while its count is positive, and an observer fires when the count returns to zero.")
struct RemoteAttachmentRegistryTests {
    @Test func attachIncrementsAndDetachDecrements() {
        let registry = RemoteAttachmentRegistry()
        #expect(!registry.isRemoteAttached(sessionName: "s1"))

        registry.attach(sessionName: "s1")
        #expect(registry.isRemoteAttached(sessionName: "s1"))
        #expect(!registry.isRemoteAttached(sessionName: "s2"))

        registry.attach(sessionName: "s1")
        registry.detach(sessionName: "s1")
        #expect(registry.isRemoteAttached(sessionName: "s1"))

        registry.detach(sessionName: "s1")
        #expect(!registry.isRemoteAttached(sessionName: "s1"))
    }

    @Test func detachBelowZeroIsClampedAndDoesNotFireObserver() {
        let registry = RemoteAttachmentRegistry()
        var fired: [String] = []
        registry.onLastDetach = { fired.append($0) }

        registry.detach(sessionName: "never-attached")
        #expect(fired.isEmpty)
        #expect(!registry.isRemoteAttached(sessionName: "never-attached"))
    }

    @Test func onLastDetachFiresOnlyWhenCountReachesZero() {
        let registry = RemoteAttachmentRegistry()
        var fired: [String] = []
        registry.onLastDetach = { fired.append($0) }

        registry.attach(sessionName: "s1")
        registry.attach(sessionName: "s1")
        registry.detach(sessionName: "s1")
        #expect(fired.isEmpty)

        registry.detach(sessionName: "s1")
        #expect(fired == ["s1"])
    }

    @Test func observerCanReenterRegistryWithoutDeadlock() {
        // Locking rule: onLastDetach is invoked outside the registry lock,
        // so an observer may query the registry synchronously.
        let registry = RemoteAttachmentRegistry()
        var observedDuringCallback: Bool? = nil
        registry.onLastDetach = { name in
            observedDuringCallback = registry.isRemoteAttached(sessionName: name)
        }
        registry.attach(sessionName: "s1")
        registry.detach(sessionName: "s1")
        #expect(observedDuringCallback == false)
    }
}
```

- [ ] **Step 1.2: Run tests to verify they fail**

Run: `swift test --filter RemoteAttachmentRegistryTests 2>&1 | tail -20`
Expected: compile FAILURE — `cannot find 'RemoteAttachmentRegistry' in scope`.

- [ ] **Step 1.3: Implement the registry**

```swift
import Foundation

/// @spec TERM-11.5
/// The application shall track the number of remote clients attached to each
/// zmx session; a session is remote-attached while its count is positive, and
/// an observer fires when the count returns to zero.
///
/// Fed by both remote attach paths — `WebSession` (WebSocket `/ws` bridge)
/// and `ZmxAttachStream` (SSH-over-WebRTC terminal channel). Consulted by
/// `HostManagedZmxBackend` to decide whether the IOS-12.1 silent gate
/// applies: the Mac pane withholds PTY resizes only while a remote client
/// is attached to the same session.
///
/// Locking: `onLastDetach` is invoked OUTSIDE the registry lock, on the
/// detaching caller's thread. Observers may take their own locks (the
/// host-managed backend does) without deadlocking against `isRemoteAttached`
/// calls made under those locks.
public final class RemoteAttachmentRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var storedOnLastDetach: ((String) -> Void)?

    /// Fires when a session's attach count drops to zero. Invoked outside
    /// the registry's lock, on the detaching caller's thread.
    public var onLastDetach: ((String) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedOnLastDetach
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedOnLastDetach = newValue
        }
    }

    public init() {}

    public func attach(sessionName: String) {
        lock.lock()
        counts[sessionName, default: 0] += 1
        lock.unlock()
    }

    public func detach(sessionName: String) {
        lock.lock()
        let current = counts[sessionName] ?? 0
        let droppedToZero = current == 1
        if current <= 1 {
            counts.removeValue(forKey: sessionName)
        } else {
            counts[sessionName] = current - 1
        }
        let callback = droppedToZero ? storedOnLastDetach : nil
        lock.unlock()
        callback?(sessionName)
    }

    public func isRemoteAttached(sessionName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (counts[sessionName] ?? 0) > 0
    }
}
```

- [ ] **Step 1.4: Run tests to verify they pass**

Run: `swift test --filter RemoteAttachmentRegistryTests 2>&1 | tail -20`
Expected: 4 tests PASS.

- [ ] **Step 1.5: Commit**

```bash
git add Sources/GrafttyKit/RemoteAttachmentRegistry.swift Tests/GrafttyKitTests/RemoteAttachmentRegistryTests.swift
git commit -m "feat(TERM-11.5): RemoteAttachmentRegistry — per-session remote attach counts"
```

---

### Task 2: `HostManagedZmxBackend` — conditional gate, layout-settled sync, fixed engagement flush

**Files:**
- Modify: `Sources/Graftty/Terminal/HostManagedZmxBackend.swift`
- Modify: `Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift`

The backend gains: `hasRemoteClient` init closure (default `{ false }`), `bindSurfaceSync(currentGridSize:requestRefresh:)`, `markLayoutSettled()`, `remoteClientsDidDetach()`, and a `layoutSettled` flag. Existing tests keep passing because `layoutSettled` defaults to `false` (pre-layout phase behaves exactly like the old unconditional gate). New tests exercise the post-layout behavior.

- [ ] **Step 2.1: Write the failing reproduction + new behavior tests**

Add to `Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift` (inside `struct HostManagedZmxBackendTests`). Note the existing private helpers `makeBackend(session:)`, `FakeHostManagedSession`, `Resize`, `fakeSurface()` — extend `makeBackend` as shown in Step 2.2's test-helper change below; write these tests against that extended helper:

```swift
    // MARK: - TERM-11.x — PTY/grid size sync (conditional IOS-12.1 gate)

    @Test("@spec TERM-11.1: When pane layout settles and no remote client is attached to the zmx session, the application shall resize the zmx PTY to the current libghostty grid size without waiting for user input.")
    func layoutSettleSyncsPtyToGridWhenNoRemoteAttached() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 142, rows: 38) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())

        backend.markLayoutSettled()

        #expect(session.resizes() == [Resize(cols: 142, rows: 38)])
    }

    @Test("@spec TERM-11.2: While no remote client is attached and layout has settled, a libghostty viewport callback shall resize the zmx PTY immediately, before any user input.")
    func postLayoutViewportCallbackForwardsImmediatelyWhenNoRemoteAttached() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(currentGridSize: { nil }, requestRefresh: {})
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )

        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])
    }

    @Test("Forwarding a silent-state viewport callback shall not flip the engagement gate — programmatic-input policy still applies until real user input (IOS-12.1).")
    func silentForwardingDoesNotEngageGate() throws {
        let session = FakeHostManagedSession()
        let remoteAttached = LockedFlag(false)
        let backend = Self.makeBackend(
            session: session,
            hasRemoteClient: { remoteAttached.value() }
        )
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(currentGridSize: { nil }, requestRefresh: {})
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )
        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])

        // A remote client attaches; the still-silent gate must re-engage
        // withholding because engagement never flipped.
        remoteAttached.set(true)
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            100, 30, 1200, 720
        )
        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])
    }

    @Test("@spec TERM-11.3: When the silent gate disengages on first user input, the application shall resize the PTY to the current libghostty grid size and force a surface refresh.")
    func engagementFlushUsesCurrentGridSizeAndRefreshes() throws {
        let session = FakeHostManagedSession()
        let refreshes = LockedCounter()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 142, rows: 38) },
            requestRefresh: { _ = refreshes.increment() }
        )
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        // Remote attached: viewport callbacks are withheld.
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )
        #expect(session.resizes().isEmpty)

        // First user input flushes the CURRENT grid (142x38), not the stale
        // recorded callback (132x43), and forces a refresh.
        try backend.write(Data([0x68]))
        #expect(session.resizes() == [Resize(cols: 142, rows: 38)])
        #expect(refreshes.value() == 1)
    }

    @Test("Engagement flush shall fall back to the last withheld viewport size when no grid size provider is bound (IOS-12.1 compatibility).")
    func engagementFlushFallsBackToLastWithheldSize() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132, 43, 2112, 1032
        )
        try backend.write(Data([0x68]))
        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])
    }

    @Test("@spec TERM-11.4: When the last remote client detaches from a session whose pane has not yet been engaged, the application shall resize the PTY to the current libghostty grid size.")
    func lastRemoteDetachSyncsStillSilentPane() throws {
        let session = FakeHostManagedSession()
        let remoteAttached = LockedFlag(true)
        let backend = Self.makeBackend(
            session: session,
            hasRemoteClient: { remoteAttached.value() }
        )
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 142, rows: 38) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()
        #expect(session.resizes().isEmpty)   // gated: remote attached

        remoteAttached.set(false)
        backend.remoteClientsDidDetach()

        #expect(session.resizes() == [Resize(cols: 142, rows: 38)])
    }

    @Test("remoteClientsDidDetach shall be a no-op once the pane is engaged — engaged panes already forward every viewport callback.")
    func remoteDetachAfterEngagementDoesNothing() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        try backend.write(Data([0x68]))   // engage, nothing queued
        let countAfterEngage = session.resizes().count

        backend.remoteClientsDidDetach()
        #expect(session.resizes().count == countAfterEngage)
    }

    @Test("markLayoutSettled shall be idempotent — only the first call performs the one-shot sync.")
    func markLayoutSettledIsIdempotent() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        backend.bindSurfaceSync(
            currentGridSize: { (cols: 142, rows: 38) },
            requestRefresh: {}
        )
        try backend.start(surface: Self.fakeSurface())

        backend.markLayoutSettled()
        backend.markLayoutSettled()
        #expect(session.resizes() == [Resize(cols: 142, rows: 38)])
    }

    @Test("While layout has not settled, a silent-state viewport callback shall be withheld even with no remote client attached — protection against the pre-layout libghostty callback that PR 201 fixed.")
    func preLayoutCallbackIsWithheldEvenWithoutRemote() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())

        // No markLayoutSettled() — the pre-layout phase.
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            80, 24, 960, 576
        )
        #expect(session.resizes().isEmpty)
    }
```

Add these helpers next to `LockedCounter` at the bottom of the test file (outside the struct):

```swift
private final class LockedFlag {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) {
        self.stored = value
    }

    func value() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
```

- [ ] **Step 2.2: Update the test helper and the IOS-12.1 spec test**

In the same file, replace the private `makeBackend` helper:

```swift
    private static func makeBackend(
        session: FakeHostManagedSession,
        hasRemoteClient: @escaping () -> Bool = { false }
    ) -> HostManagedZmxBackend {
        HostManagedZmxBackend(
            spawnConfiguration: spawnConfiguration(),
            hasRemoteClient: hasRemoteClient,
            sessionFactory: { _, _, _ in session }
        )
    }
```

Replace the IOS-12.1 spec test (currently `reattachWithoutUserInputDoesNotResize`, line ~297) — new conditional EARS text, now exercising the remote-attached case explicitly:

```swift
    @Test("@spec IOS-12.1: While a remote client is attached to the zmx session, a fresh attach with a libghostty viewport callback but no user input shall not resize the zmx PTY. This is the Mac mirror of IOS-6.5 — the PTY cols/rows persist until the Mac user engages or the last remote client detaches.")
    func reattachWithoutUserInputDoesNotResizeWhileRemoteAttached() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session, hasRemoteClient: { true })
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())
        backend.markLayoutSettled()

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            80, 24, 960, 576
        )

        #expect(session.resizes().isEmpty)
    }
```

Three existing tests describe the old unconditional gate in their titles; their assertions still hold (they run in the pre-layout phase), but retitle them so the suite reads correctly:
- Line ~40 `receiveResizeCallbackForwardsGridSizeToStartedSessionOnlyAfterUserInputEngagement`: title → `"Pre-layout viewport callbacks are withheld; the first user input flushes the last one, then later callbacks pass through (IOS-12.1)."`
- Line ~316 `userInputFlushesPendingResize`: title → `"First user-input write after a withheld viewport callback flushes the queued size to the PTY as a single resize (IOS-12.1)."`
- Line ~393 `programmaticWriteDoesNotEngageGate` and ~417 `failedWriteDoesNotEngageGate` and ~474 `engagementFlushResizeOrdersBeforeConcurrentWriteBytes`: titles unchanged (still accurate); no assertion changes — they run pre-layout so withholding still applies.

- [ ] **Step 2.3: Run tests to verify the new ones fail**

Run: `swift test --filter HostManagedZmxBackendTests 2>&1 | tail -30`
Expected: compile FAILURE — `bindSurfaceSync`, `markLayoutSettled`, `remoteClientsDidDetach`, and the `hasRemoteClient:` init label don't exist yet.

- [ ] **Step 2.4: Implement the backend changes**

In `Sources/Graftty/Terminal/HostManagedZmxBackend.swift`:

(a) Update the `AttachState` doc comment (lines 34-42) to the new conditional semantics:

```swift
    /// @spec IOS-12.1
    /// Tracks user engagement since the most recent attach. While `.silent`,
    /// libghostty viewport callbacks propagate to the zmx PTY only when
    /// layout has settled AND no remote client is attached to the session
    /// (TERM-11.2); otherwise they are recorded and the PTY's existing dims
    /// persist. The first user input flips to `.engaged` and syncs the PTY
    /// to the current grid (TERM-11.3).
    private enum AttachState {
        case silent
        case engaged
    }
```

(b) Add stored properties after `private var programmaticInputDepth: Int = 0` (line ~89):

```swift
    /// TERM-11.x gating inputs. `hasRemoteClient` is injected at init
    /// (default false — direct-shell/test backends have no remote peers).
    /// The surface-sync closures are bound by SurfaceHandle after
    /// ghostty_surface_new succeeds, before start(surface:).
    private let hasRemoteClient: () -> Bool
    private var currentGridSize: () -> (cols: UInt16, rows: UInt16)? = { nil }
    private var requestRefresh: () -> Void = {}

    /// Flips true (once) when the owning NSView first receives a nonzero
    /// frame. Pre-settle viewport callbacks are never forwarded — they are
    /// libghostty pre-layout noise (the original PR #201 bug).
    private var layoutSettled = false
```

(c) Extend `init` — add the parameter between `initialSize` and `sessionFactory`:

```swift
    init(
        spawnConfiguration: ZmxSpawnConfiguration,
        initialSize: (cols: UInt16, rows: UInt16)? = nil,
        hasRemoteClient: @escaping () -> Bool = { false },
        sessionFactory: @escaping SessionFactory = { surface, configuration, initialSize in
            NativePtySession(
                surface: surface,
                argv: configuration.argv,
                env: configuration.env,
                workingDirectory: configuration.workingDirectory,
                initialSize: initialSize,
                spawnFailed: { _ in }
            )
        }
    ) {
        self.spawnConfiguration = spawnConfiguration
        self.initialSize = initialSize
        self.hasRemoteClient = hasRemoteClient
        self.sessionFactory = sessionFactory
        ...   // rest unchanged
```

(d) Add the new public methods (place after `withProgrammaticInputScope`):

```swift
    /// Binds the surface-sync closures. Called by SurfaceHandle after
    /// ghostty_surface_new succeeds and before start(surface:). The
    /// closures must be safe to call from the backend's lock (they issue
    /// a single libghostty query / refresh request — no re-entrancy into
    /// the backend).
    func bindSurfaceSync(
        currentGridSize: @escaping () -> (cols: UInt16, rows: UInt16)?,
        requestRefresh: @escaping () -> Void
    ) {
        lock.lock()
        self.currentGridSize = currentGridSize
        self.requestRefresh = requestRefresh
        lock.unlock()
    }

    /// TERM-11.1: the owning NSView received its first nonzero frame.
    /// One-shot: if the pane is still silent and no remote client is
    /// attached, sync the PTY to the current grid so zmx formats output
    /// for the dims libghostty is actually rendering.
    func markLayoutSettled() {
        lock.lock()
        defer { lock.unlock() }
        guard !layoutSettled else { return }
        layoutSettled = true
        guard case .silent = attachState, !hasRemoteClient() else { return }
        flushSizeToPtyLocked(refresh: false)
    }

    /// TERM-11.4: the last remote client detached from this session. A
    /// still-silent pane syncs the PTY to the current grid immediately —
    /// there is no longer anyone whose width we must preserve.
    func remoteClientsDidDetach() {
        lock.lock()
        defer { lock.unlock() }
        guard case .silent = attachState, layoutSettled else { return }
        flushSizeToPtyLocked(refresh: true)
    }
```

(e) Rewrite `receiveResize` (lines ~303-329). The silent branch withholds only when gated:

```swift
    private func receiveResize(cols: UInt16, rows: UInt16) {
        let currentSession: HostManagedZmxSession?

        lock.lock()
        if case .silent = attachState {
            // TERM-11.2 / IOS-12.1: withhold while layout hasn't settled
            // (pre-layout libghostty noise) or while a remote client is
            // attached (the Mac must not steal the session width without
            // user engagement). Otherwise forward without engaging.
            if !layoutSettled || hasRemoteClient() {
                lastSilentResize = PendingResize(cols: cols, rows: rows)
                lock.unlock()
                return
            }
            lastSilentResize = nil
        }
        switch lifecycle {
        case .idle, .starting:
            pendingResize = PendingResize(cols: cols, rows: rows)
            currentSession = nil
        case .running:
            currentSession = session
        case .closed:
            currentSession = nil
        }
        lock.unlock()

        try? currentSession?.resize(cols: cols, rows: rows)
    }
```

(f) Rewrite `markUserInput` to flush the current grid (TERM-11.3) via a shared helper:

```swift
    /// Marks that the user has acted on the surface since the most recent
    /// attach. The first call syncs the PTY to the current grid (TERM-11.3)
    /// so any dims withheld under IOS-12.1 land before post-engagement
    /// bytes. IOS-12.1.
    ///
    /// The lock is held across the flush `resize` call so any concurrent
    /// `write` on another thread cannot ship bytes to the PTY before the
    /// flush lands — invariant: post-engagement bytes always see the
    /// post-flush PTY dims.
    private func markUserInput() {
        lock.lock()
        defer { lock.unlock() }

        guard case .silent = attachState else { return }
        attachState = .engaged
        flushSizeToPtyLocked(refresh: true)
    }

    /// Shared sync tail for markUserInput / markLayoutSettled /
    /// remoteClientsDidDetach. Caller holds `lock`. Resolves the sync
    /// target — the live grid when a provider is bound, else the last
    /// withheld viewport size — and ships it to the PTY (or queues it
    /// when the session is still starting). `resize` is a TIOCSWINSZ
    /// ioctl — milliseconds at most, no nested locking — so holding the
    /// lock across it keeps the contention window bounded.
    private func flushSizeToPtyLocked(refresh: Bool) {
        let queued = lastSilentResize
        lastSilentResize = nil
        let target = currentGridSize() ?? queued.map { (cols: $0.cols, rows: $0.rows) }
        guard let target else { return }
        switch lifecycle {
        case .running:
            try? session?.resize(cols: target.cols, rows: target.rows)
            if refresh {
                requestRefresh()
            }
        case .idle, .starting:
            pendingResize = PendingResize(cols: target.cols, rows: target.rows)
        case .closed:
            break
        }
    }
```

- [ ] **Step 2.5: Run the backend suite**

Run: `swift test --filter HostManagedZmxBackendTests 2>&1 | tail -30`
Expected: ALL tests PASS (old + new). If `startResetsSilentGateAndDiscardsPreStartViewportCallbacks` fails: check that `start()` still resets `lastSilentResize = nil` and that `flushSizeToPtyLocked` returns early when both the provider returns nil and nothing is queued.

- [ ] **Step 2.6: Commit**

```bash
git add Sources/Graftty/Terminal/HostManagedZmxBackend.swift Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift
git commit -m "fix(TERM-11.1-11.4): conditional IOS-12.1 gate — forward PTY resizes when no remote client is attached"
```

---

### Task 3: `SurfaceHandle` / `SurfaceNSView` / `TerminalManager` wiring

**Files:**
- Modify: `Sources/Graftty/Terminal/SurfaceHandle.swift`
- Modify: `Sources/Graftty/Terminal/TerminalManager.swift`
- Modify: `Tests/GrafttyTests/Terminal/SurfaceHandleTestSupport.swift` (update fakes to new protocol)

- [ ] **Step 3.1: Extend the `SurfaceHandleZmxBackend` protocol** (SurfaceHandle.swift:34-46)

Add three requirements:

```swift
protocol SurfaceHandleZmxBackend: AnyObject {
    func configure(_ config: inout ghostty_surface_config_s)
    func start(surface: ghostty_surface_t) throws
    func write(_ data: Data) throws
    func write(_ data: Data, claimEngagement: Bool) throws
    /// Runs `body` while flagging that any bytes libghostty pushes back
    /// through the receive callback are automation, not user input. The
    /// backend gates IOS-12.1 engagement on this flag for the duration
    /// of `body`. See `HostManagedZmxBackend.withProgrammaticInput`.
    func withProgrammaticInput(_ body: () -> Void)
    /// Binds closures that let the backend query the live grid size and
    /// request a repaint without linking against libghostty (TERM-11.3).
    func bindSurfaceSync(
        currentGridSize: @escaping () -> (cols: UInt16, rows: UInt16)?,
        requestRefresh: @escaping () -> Void
    )
    /// The owning NSView received its first nonzero frame (TERM-11.1).
    func markLayoutSettled()
    /// The last remote client detached from this pane's session (TERM-11.4).
    func remoteClientsDidDetach()
    func close()
    func surfaceWasFreed()
}
```

`HostManagedZmxBackend` already implements all three after Task 2, so its conformance extension needs no new shims. Update any fakes in `Tests/GrafttyTests/Terminal/SurfaceHandleTestSupport.swift` conforming to `SurfaceHandleZmxBackend` with no-op implementations (record calls if the fake already records others):

```swift
    func bindSurfaceSync(
        currentGridSize: @escaping () -> (cols: UInt16, rows: UInt16)?,
        requestRefresh: @escaping () -> Void
    ) {}
    func markLayoutSettled() {}
    func remoteClientsDidDetach() {}
```

- [ ] **Step 3.2: Thread the registry through `SurfaceHandle.init`**

(a) Change the `zmxBackendFactory` parameter (line ~127) to carry the remote-presence closure, and add a `remoteAttachmentRegistry` parameter:

```swift
        remoteAttachmentRegistry: RemoteAttachmentRegistry? = nil,
        zmxBackendFactory: (
            ZmxSpawnConfiguration,
            (cols: UInt16, rows: UInt16)?,
            @escaping () -> Bool
        ) -> SurfaceHandleZmxBackend = { spawn, initialSize, hasRemoteClient in
            HostManagedZmxBackend(
                spawnConfiguration: spawn,
                initialSize: initialSize,
                hasRemoteClient: hasRemoteClient
            )
        },
```

(`RemoteAttachmentRegistry` lives in GrafttyKit; `SurfaceHandle.swift` already has `import GrafttyKit` via its existing imports — verify, add if missing.)

(b) Update the factory call site (line ~145):

```swift
        let backend = zmxSpawnConfiguration.map { spawn in
            zmxBackendFactory(
                spawn,
                initialGridSize.map { ($0.columns, $0.rows) },
                { [weak remoteAttachmentRegistry] in
                    remoteAttachmentRegistry?.isRemoteAttached(sessionName: spawn.sessionName) ?? false
                }
            )
        }
```

Note: `remoteAttachmentRegistry` is a plain parameter — capture it in a local `let registry = remoteAttachmentRegistry` first if the compiler rejects `weak` capture of a parameter, or capture strongly (the registry is app-lifetime; the backend → registry reference creates no cycle):

```swift
        let registry = remoteAttachmentRegistry
        let backend = zmxSpawnConfiguration.map { spawn in
            zmxBackendFactory(
                spawn,
                initialGridSize.map { ($0.columns, $0.rows) },
                { registry?.isRemoteAttached(sessionName: spawn.sessionName) ?? false }
            )
        }
```

(c) Store the session name. Add a stored property near `let worktreePath: String` (line ~102):

```swift
    /// zmx session this pane is attached to, nil for direct-shell panes.
    /// Used by TerminalManager to route last-remote-detach syncs (TERM-11.4).
    let zmxSessionName: String?
```

and in init, after `self.worktreePath = worktreePath`:

```swift
        self.zmxSessionName = zmxSpawnConfiguration?.sessionName
```

(d) Bind surface sync + layout notifier. After `surfaceView.surface = newSurface` (line ~276) and BEFORE the `initialGridSize` pre-size block, add:

```swift
        if let backend {
            // TERM-11.3: let the backend query the live grid and request
            // repaints without linking libghostty. Closures capture the
            // surface via surfaceFactory; the backend stops calling them
            // once closed, which SurfaceHandle.deinit orders before
            // surfaceFactory.free.
            let factory = surfaceFactory
            backend.bindSurfaceSync(
                currentGridSize: {
                    let size = factory.size(newSurface)
                    guard size.columns > 0, size.rows > 0 else { return nil }
                    return (cols: size.columns, rows: size.rows)
                },
                requestRefresh: {
                    ghostty_surface_refresh(newSurface)
                }
            )
            // TERM-11.1: first nonzero frame on the view = layout settled.
            surfaceView.hostManagedLayoutNotifier = { [weak backend] in
                backend?.markLayoutSettled()
            }
        }
```

(If `ghostty_surface_size_s.columns/rows` are not `UInt16`, convert with `UInt16(clamping:)` — check how line 146's `initialGridSize.map { ($0.columns, $0.rows) }` types flow; mirror that.)

(e) Add the forwarding method on `SurfaceHandle` (near `func refresh()`):

```swift
    /// TERM-11.4: forwarded by TerminalManager when the last remote client
    /// detaches from this pane's zmx session.
    func remoteClientsDidDetach() {
        zmxBackend?.remoteClientsDidDetach()
    }
```

- [ ] **Step 3.3: Notify layout-settled from `SurfaceNSView.setFrameSize`**

Add a property to `SurfaceNSView` (near `var hostManagedInputWriter` ~line 522):

```swift
    /// Fired (every time, debounced by the backend's one-shot) when the
    /// view receives a nonzero frame — the TERM-11.1 layout-settled signal.
    var hostManagedLayoutNotifier: (() -> Void)?
```

In `setFrameSize` (line ~620), after `ghostty_surface_refresh(surface)`:

```swift
        hostManagedLayoutNotifier?()
```

(The existing `guard let surface` + `resizeProposal` guards already filter zero/invalid frames, so reaching the end of `setFrameSize` means a real nonzero layout.)

- [ ] **Step 3.4: TerminalManager — registry property, pass-through, detach routing**

(a) Add near `var zmxLauncher` (TerminalManager.swift:~117):

```swift
    /// TERM-11.x: per-session remote attach counts; injected by
    /// GrafttyApp.startup() like zmxLauncher. Consulted (via SurfaceHandle)
    /// to decide whether the IOS-12.1 silent gate withholds PTY resizes.
    var remoteAttachmentRegistry: RemoteAttachmentRegistry?
```

(b) In BOTH `SurfaceHandle` construction sites (`createSurfaces` line ~499 and `createSurface` line ~543), add the argument:

```swift
                remoteAttachmentRegistry: remoteAttachmentRegistry,
```

(c) Add the routing method:

```swift
    /// TERM-11.4: the last remote client detached from `sessionName`; give
    /// any still-silent pane on that session the chance to sync its PTY to
    /// the current grid.
    func remoteClientsDetached(fromSession sessionName: String) {
        for handle in surfaces.values where handle.zmxSessionName == sessionName {
            handle.remoteClientsDidDetach()
        }
    }
```

- [ ] **Step 3.5: Build and run the full Graftty test target**

Run: `swift build 2>&1 | tail -5 && swift test --filter GrafttyTests 2>&1 | tail -15`
Expected: build SUCCESS; tests PASS. Fix any fake-conformance compile errors in test support files (Step 3.1 pattern).

- [ ] **Step 3.6: Commit**

```bash
git add Sources/Graftty/Terminal/SurfaceHandle.swift Sources/Graftty/Terminal/TerminalManager.swift Tests/GrafttyTests/Terminal/SurfaceHandleTestSupport.swift
git commit -m "feat(TERM-11.1/11.3/11.4): wire layout-settled signal, grid query, and detach routing into SurfaceHandle"
```

---

### Task 4: `WebSession` registry wiring (WebSocket remote path)

**Files:**
- Modify: `Sources/GrafttyKit/Web/WebSession.swift`
- Modify: `Sources/GrafttyKit/Web/WebServer.swift` (Config + `WebSocketBridgeHandler`)
- Modify: `Sources/Graftty/Web/WebServerController.swift`
- Modify: `Tests/GrafttyKitTests/Web/WebSessionTests.swift`

- [ ] **Step 4.1: Write the failing test**

Add to `Tests/GrafttyKitTests/Web/WebSessionTests.swift`, following the existing `makeFakeZmx` pattern in that file (a shell script standing in for the zmx binary):

```swift
    @Test("WebSession shall register with the RemoteAttachmentRegistry on successful start and deregister exactly once on close (TERM-11.5).")
    func registersAttachOnStartAndDetachOnClose() throws {
        let zmx = try makeFakeZmx()   // reuse the existing helper as-is
        let registry = RemoteAttachmentRegistry()
        let session = WebSession(config: WebSession.Config(
            zmxExecutable: zmx.executable,
            zmxDir: zmx.dir,
            sessionName: "reg-test",
            workingDirectory: nil
        ))
        session.attachmentRegistry = registry

        try session.start()
        #expect(registry.isRemoteAttached(sessionName: "reg-test"))

        session.close()
        #expect(!registry.isRemoteAttached(sessionName: "reg-test"))

        session.close()   // idempotent: no double-detach
        #expect(!registry.isRemoteAttached(sessionName: "reg-test"))
    }

    @Test("WebSession shall not deregister on close when start never succeeded (TERM-11.5).")
    func closeWithoutStartDoesNotDetach() {
        let registry = RemoteAttachmentRegistry()
        var fired = 0
        registry.onLastDetach = { _ in fired += 1 }
        let session = WebSession(config: WebSession.Config(
            zmxExecutable: URL(fileURLWithPath: "/nonexistent-zmx"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            sessionName: "never-started",
            workingDirectory: nil
        ))
        session.attachmentRegistry = registry

        session.close()
        #expect(fired == 0)
    }
```

Adapt the exact helper name/signature to what `WebSessionTests.swift` actually provides (`makeFakeZmx` returns the executable + dir per the existing tests — read the file and reuse).

- [ ] **Step 4.2: Run to verify failure**

Run: `swift test --filter WebSessionTests 2>&1 | tail -15`
Expected: compile FAILURE — `attachmentRegistry` doesn't exist.

- [ ] **Step 4.3: Implement in `WebSession`**

Add near `public var inputState: ZmxInputState?` (line ~70):

```swift
    /// TERM-11.5: per-session remote attach counts. Set by the owning
    /// WebSocket bridge before `start()`; `start()` registers this attach
    /// and `close()` deregisters it exactly once.
    public var attachmentRegistry: RemoteAttachmentRegistry?
    private var didRegisterAttach = false
```

In `start()`, after the spawn succeeds (after the `do/catch` around `PtyProcess.spawn`, still under `stateLock`):

```swift
        attachmentRegistry?.attach(sessionName: config.sessionName)
        didRegisterAttach = true
```

In `close()`, inside the once-only section (after `isClosed = true`, alongside the callback-clearing under the lock, but invoke `detach` AFTER `stateLock.unlock()` — the registry's `onLastDetach` observer may take other locks):

```swift
        let shouldDetach = didRegisterAttach
        didRegisterAttach = false
```
(under the lock), then after `stateLock.unlock()`:

```swift
        if shouldDetach {
            attachmentRegistry?.detach(sessionName: config.sessionName)
        }
```

- [ ] **Step 4.4: Plumb the registry through `WebServer`**

(a) Add to `WebServer.Config` (WebServer.swift:153, with the other fields) and its initializer with a `nil` default (read the existing `public init` and append the parameter last):

```swift
        /// TERM-11.5: when set, each WebSocket bridge's WebSession
        /// registers its zmx attach so Mac panes know a remote client
        /// is present. Nil (tests, early boot) disables tracking.
        public let remoteAttachmentRegistry: RemoteAttachmentRegistry?
```

(b) `WebSocketBridgeHandler` (line ~944): add `let remoteAttachmentRegistry: RemoteAttachmentRegistry?` property + init parameter; at the construction site (line ~405) pass `remoteAttachmentRegistry: config.remoteAttachmentRegistry` (adapt to how that closure accesses config — it may capture fields individually like `zmxExecutable`; follow the same pattern). In `handlerAdded`, before `try sess.start()`:

```swift
            sess.attachmentRegistry = remoteAttachmentRegistry
```

(c) `WebServerController.swift` (~line 230, `completeReconcile`): the `WebServer.Config(...)` construction gains `remoteAttachmentRegistry: remoteAttachmentRegistry`. Add a property to `WebServerController` to hold it (follow how `zmxExecutable`/providers reach this method — likely init parameters or stored properties; mirror the nearest existing optional dependency) and have `GrafttyApp` supply it (Task 6).

- [ ] **Step 4.5: Run tests**

Run: `swift test --filter WebSessionTests 2>&1 | tail -15`
Expected: PASS (new + existing).

- [ ] **Step 4.6: Commit**

```bash
git add Sources/GrafttyKit/Web/WebSession.swift Sources/GrafttyKit/Web/WebServer.swift Sources/Graftty/Web/WebServerController.swift Tests/GrafttyKitTests/Web/WebSessionTests.swift
git commit -m "feat(TERM-11.5): WebSession registers remote attaches with RemoteAttachmentRegistry"
```

---

### Task 5: `ZmxAttachStream` registry wiring (SSH-over-WebRTC remote path)

**Files:**
- Modify: `Sources/Graftty/Remote/ZmxAttachStream.swift`
- Create: `Tests/GrafttyTests/Remote/ZmxAttachStreamRegistryTests.swift`

- [ ] **Step 5.1: Write the failing test**

`ZmxAttachStream` runs a real `Process`; use `/bin/cat` as a stand-in executable (it ignores the `attach <name>` args and idles on stdin like `zmx attach` does):

```swift
import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("ZmxAttachStream — RemoteAttachmentRegistry wiring")
struct ZmxAttachStreamRegistryTests {
    @Test("ZmxAttachStream shall register with the RemoteAttachmentRegistry when the attach process spawns and deregister exactly once on close (TERM-11.5).")
    func registersAttachOnSpawnAndDetachOnClose() async throws {
        let registry = RemoteAttachmentRegistry()
        let stream = try ZmxAttachStream(
            zmxExecutable: URL(fileURLWithPath: "/bin/cat"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            sessionName: "ssh-reg-test",
            workingDirectory: nil,
            attachmentRegistry: registry
        )
        #expect(registry.isRemoteAttached(sessionName: "ssh-reg-test"))

        await stream.close()
        #expect(!registry.isRemoteAttached(sessionName: "ssh-reg-test"))

        await stream.close()   // idempotent
        #expect(!registry.isRemoteAttached(sessionName: "ssh-reg-test"))
    }

    @Test("ZmxAttachStream init failure shall leave the registry untouched (TERM-11.5).")
    func spawnFailureDoesNotRegister() {
        let registry = RemoteAttachmentRegistry()
        #expect(throws: Error.self) {
            _ = try ZmxAttachStream(
                zmxExecutable: URL(fileURLWithPath: "/nonexistent-zmx-binary"),
                zmxDir: URL(fileURLWithPath: "/tmp"),
                sessionName: "ssh-fail-test",
                workingDirectory: nil,
                attachmentRegistry: registry
            )
        }
        #expect(!registry.isRemoteAttached(sessionName: "ssh-fail-test"))
    }
}
```

- [ ] **Step 5.2: Run to verify failure**

Run: `swift test --filter ZmxAttachStreamRegistryTests 2>&1 | tail -15`
Expected: compile FAILURE — no `attachmentRegistry` init parameter.

- [ ] **Step 5.3: Implement**

In `ZmxAttachStream.swift`:

(a) Add stored properties:

```swift
    private let attachmentRegistry: RemoteAttachmentRegistry?
    private let sessionName: String
```

(b) Extend `init` signature with `attachmentRegistry: RemoteAttachmentRegistry? = nil`, store both (`self.sessionName = sessionName` — check whether sessionName is already stored; add if not), and register AFTER `try process.run()` succeeds (last line of init):

```swift
        try process.run()
        attachmentRegistry?.attach(sessionName: sessionName)
```

(c) In `close()` — it already guards with `closed` under `lock` (read the full method body first); inside the first-close-only branch, after releasing the lock, add:

```swift
        attachmentRegistry?.detach(sessionName: sessionName)
```

Make sure the detach call happens exactly once (tie it to the same `closed` flag transition) and outside the `NIOLock` critical section.

- [ ] **Step 5.4: Run tests**

Run: `swift test --filter ZmxAttachStreamRegistryTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5.5: Commit**

```bash
git add Sources/Graftty/Remote/ZmxAttachStream.swift Tests/GrafttyTests/Remote/ZmxAttachStreamRegistryTests.swift
git commit -m "feat(TERM-11.5): ZmxAttachStream registers SSH remote attaches with RemoteAttachmentRegistry"
```

---

### Task 6: App-level wiring (`GrafttyApp`)

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Modify: `Sources/Graftty/Web/WebServerController.swift` (if the registry property wasn't fully threaded in Task 4)

No new unit tests — this is dependency wiring exercised by the component tests above; verify by build + full suite.

- [ ] **Step 6.1: Construct the registry in `AppServices`**

Near `let claudeSessionRegistry: ClaudeSessionRegistry` (line ~135):

```swift
    /// TERM-11.5: per-zmx-session remote client attach counts. Fed by the
    /// web (/ws) and SSH-over-WebRTC attach paths; consulted by Mac pane
    /// backends to scope the IOS-12.1 silent gate to multi-device sessions.
    let remoteAttachmentRegistry = RemoteAttachmentRegistry()
```

- [ ] **Step 6.2: Inject into `TerminalManager` and route last-detach**

In `startup()`, next to `terminalManager.zmxLauncher = zmxLauncher` (line ~573):

```swift
        terminalManager.remoteAttachmentRegistry = services.remoteAttachmentRegistry
        services.remoteAttachmentRegistry.onLastDetach = { [weak terminalManager] sessionName in
            Task { @MainActor in
                terminalManager?.remoteClientsDetached(fromSession: sessionName)
            }
        }
```

(`terminalManager` here is the `TerminalManager` instance used at that line — adapt the capture to the surrounding code: if it's accessed as `self.terminalManager` / a local, follow suit. TerminalManager is `@MainActor`; the `Task { @MainActor in ... }` hop is required because `onLastDetach` fires on the detaching connection's thread.)

- [ ] **Step 6.3: Inject into the SSH `streamFactory`** (line ~332)

```swift
                streamFactory: { [registry = services.remoteAttachmentRegistry] sessionName in
                    try ZmxAttachStream(
                        zmxExecutable: zmxExe,
                        zmxDir: zmxDir,
                        sessionName: sessionName,
                        workingDirectory: nil,
                        attachmentRegistry: registry
                    )
                },
```

- [ ] **Step 6.4: Inject into `WebServerController`**

Wherever `GrafttyApp` constructs/configures `WebServerController` (search `WebServerController(` in GrafttyApp.swift), pass `services.remoteAttachmentRegistry` to the property added in Task 4 Step 4.4(c).

- [ ] **Step 6.5: Build + full test suite**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -15`
Expected: build SUCCESS, all tests PASS.

- [ ] **Step 6.6: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift Sources/Graftty/Web/WebServerController.swift
git commit -m "feat(TERM-11.x): wire RemoteAttachmentRegistry through AppServices to all attach paths"
```

---

### Task 7: Spec regeneration + cross-reference cleanup

**Files:**
- Modify: `SPECS.md` (generated — never hand-edit)
- Possibly modify: comments referencing IOS-12.1 in `Sources/Graftty/AppZmxWriter.swift`, `Sources/Graftty/GrafttyApp.swift`, `Sources/Graftty/Terminal/SurfaceHandle.swift`

- [ ] **Step 7.1: Audit stale IOS-12.1 prose**

Run: `grep -rn "IOS-12.1" Sources/ Tests/`
For each hit, check the surrounding comment still reads correctly under the new conditional semantics (gate applies only while a remote client is attached / pre-layout). Update prose that claims unconditional gating. Do NOT renumber or relocate spec IDs.

- [ ] **Step 7.2: Regenerate SPECS.md**

Run: `scripts/generate-specs.py && git diff --stat SPECS.md`
Expected: new `TERM-11.x` entries (11.1-11.5), updated IOS-12.1 text, no duplicate-ID errors. If the script fails on duplicate IDs, a `@spec` ID landed in two behavioral locations — fix the offending test title.

- [ ] **Step 7.3: Verify the disabled-inventory rule**

Run: `grep -rn "TERM-11" Tests/GrafttyTests/Specs/ || true`
Expected: no hits (all TERM-11.x specs are live tests, none in `*Todo.swift` inventory). If a TodoSwift entry exists for any of these IDs, delete it in this commit.

- [ ] **Step 7.4: Full suite + commit**

Run: `swift test 2>&1 | tail -10`
Expected: PASS.

```bash
git add SPECS.md Sources/ Tests/
git commit -m "docs(TERM-11.x/IOS-12.1): regenerate SPECS.md for conditional silent gate"
```

---

## Task dependency order

1 → 2 → 3 → (4, 5 in either order) → 6 → 7. Tasks 4 and 5 are independent of 3 (they only need Task 1) but keeping the order avoids merge friction in shared files.

## Verification notes for the final review

- The repro scenario: before this change, a pane attached at one size and watched (never typed in) rendered zmx output at mismatched dims until a window resize. After: `layoutSettleSyncsPtyToGridWhenNoRemoteAttached` + `postLayoutViewportCallbackForwardsImmediatelyWhenNoRemoteAttached` pin the fix.
- Manual check (optional, requires running app): open a worktree pane, let an agent stream output without typing; resize the window to a different width beforehand; output should remain correctly wrapped with the cursor on the bottom line.

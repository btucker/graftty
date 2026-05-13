# iOS swipe-to-delete worktrees + sidebar-order grouping — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user swipe a worktree row in GrafttyMobile to delete (or dismiss, for stale rows), mirroring the Mac sidebar's delete machinery; and render repo groups in the same order as the Mac sidebar instead of alphabetic.

**Architecture:** Add `POST /worktrees/delete` to the existing NIO web server, backed by a closure injected from `GrafttyApp`. Extract the Mac-side `MainWindow.performDeleteWorktree` body into a new `DeleteWorktreeFlow` so the web closure and the native NSAlert path share one funnel. Add `DeleteWorktreeClient` on iOS and wire `.swipeActions` + `confirmationDialog` chains into `WorktreePickerView`. Fix repo ordering by replacing `Dictionary(grouping:).sorted` with a first-occurrence-preserving group.

**Tech Stack:** Swift Testing + XCTest, SwiftNIO HTTP, SwiftUI (`WorktreePickerView`, NSAlert on macOS), `git worktree remove` / `git worktree prune` shelling out via `GitRunner`.

**Spec:** `docs/superpowers/specs/2026-05-12-ios-swipe-delete-worktrees-design.md`. Spec IDs introduced: **IOS-9.6, IOS-9.7, IOS-9.8, IOS-9.9, WEB-7.8, WEB-7.9, WEB-7.10**.

**TDD rule:** Per `CLAUDE.md`, every new spec begins as a `@Test(.disabled(...))` in `Tests/GrafttyTests/Specs/<Prefix>Todo.swift`, gets **promoted** (deleted from Todo, added as a real `@Test` in a `*Tests.swift` file) before implementation. `scripts/generate-specs.py` is the authoritative `SPECS.md` regenerator and must be re-run after every spec change.

---

## Task 1: Inventory the seven new EARS specs

**Goal:** Add `@Test(.disabled("not yet implemented"))` entries to `IosTodo.swift` and `WebTodo.swift` so `SPECS.md` lists the work to be done. Subsequent tasks promote each entry into a real test.

**Files:**
- Modify: `Tests/GrafttyTests/Specs/IosTodo.swift` — append IOS-9.6/9.7/9.8/9.9 entries
- Modify: `Tests/GrafttyTests/Specs/WebTodo.swift` — append WEB-7.8/7.9/7.10 entries
- Run: `python3 scripts/generate-specs.py` to regenerate `SPECS.md`

- [ ] **Step 1:** Append to the end of `IosTodo.swift`'s `IosTodo` suite (just before the closing `}`):

```swift
    @Test("""
@spec IOS-9.6: When the user swipes a worktree row in `WorktreePickerView` that is neither the repo's main checkout nor in the `.creating` state, the application shall reveal a trailing destructive action labeled "Delete" for non-stale rows and "Dismiss" for `.stale` rows. Rows for the main checkout or for `.creating` worktrees shall expose no swipe action.
""", .disabled("not yet implemented"))
    func ios_9_6() async throws { }

    @Test("""
@spec IOS-9.7: When the user taps the trailing destructive action revealed by `IOS-9.6`, the application shall present a SwiftUI confirmation dialog before any HTTP call. The dialog title shall be "Delete Worktree?" for non-stale rows and "Dismiss Worktree?" for `.stale` rows; the dialog body shall mirror the Mac's NSAlert copy ("This will delete the worktree but not the branch." / "This will remove this stale entry from Graftty."). On cancel, no request shall be issued.
""", .disabled("not yet implemented"))
    func ios_9_7() async throws { }

    @Test("""
@spec IOS-9.8: If `POST /worktrees/delete` returns 409 with `forceAllowed: true`, then the application shall present a Force Delete confirmation surfacing the `shortStatus` field as the dialog body, and shall retry the request with `force: true` only on user confirmation. A 409 with `forceAllowed: false` (or 4xx/5xx of any other shape) shall present a non-retryable error toast and shall not loop.
""", .disabled("not yet implemented"))
    func ios_9_8() async throws { }

    @Test("""
@spec IOS-9.9: While rendering grouped worktrees in `WorktreePickerView`, the application shall preserve the order of `repoDisplayName` first-occurrences in the `GET /worktrees/panes` response rather than sort the group keys alphabetically, so the mobile picker's repo order matches the user's Mac sidebar order.
""", .disabled("not yet implemented"))
    func ios_9_9() async throws { }
```

- [ ] **Step 2:** Append to the end of `WebTodo.swift`'s `WebTodo` suite:

```swift
    @Test("""
@spec WEB-7.8: When a client sends `POST /worktrees/delete` with `{ "worktreePath": "<abs>", "force": <bool> }`, the application shall route the request through `DeleteWorktreeFlow.delete` and respond `200 { "dismissed": <bool> }` on success. `dismissed` shall be `true` when the flow took the GIT-3.6 / GIT-4.13 prune-on-vanished branch and `false` when `git worktree remove` succeeded. The `/worktrees/delete` endpoint accepts `POST` only; other verbs return `405 Method Not Allowed`.
""", .disabled("not yet implemented"))
    func web_7_8() async throws { }

    @Test("""
@spec WEB-7.9: If the server-side delete flow encounters a git failure that `--force` could resolve, then the application shall respond `409 Conflict` with `{ "error": "<stderr>", "forceAllowed": true, "shortStatus": "<git status --short output>" }`. When `--force` has already been attempted, or the failure class is one `--force` cannot help (e.g. main-checkout rejection), the response shall be `409 Conflict` with `forceAllowed: false` and no `shortStatus` field.
""", .disabled("not yet implemented"))
    func web_7_9() async throws { }

    @Test("""
@spec WEB-7.10: If the server's `worktreeRemover` closure is not injected, then `POST /worktrees/delete` shall respond `503 Service Unavailable` with `{ "error": "worktree deletion not available" }`. This matches the create endpoint's pre-injection contract (WEB-7.4 sibling) so a mobile or web client can distinguish "not supported yet" from "wrong URL".
""", .disabled("not yet implemented"))
    func web_7_10() async throws { }
```

- [ ] **Step 3:** Regenerate `SPECS.md`:

Run: `python3 scripts/generate-specs.py`
Expected: exits 0, modifies `SPECS.md` to include the seven new bullets.

- [ ] **Step 4:** Verify no spec-ID collisions:

Run: `python3 scripts/generate-specs.py --check`
Expected: exits 0.

- [ ] **Step 5:** Commit.

```bash
git add Tests/GrafttyTests/Specs/IosTodo.swift Tests/GrafttyTests/Specs/WebTodo.swift SPECS.md
git commit -m "spec: inventory IOS-9.6..9.9 + WEB-7.8..7.10 (delete/dismiss + grouping)"
```

---

## Task 1.5: Fix pull-to-refresh error in `WorktreePickerView`

**Goal:** Pull-to-refresh in the worktree picker currently errors. The cause: `.refreshable { await load() }` calls `load()`, which sets `state = .loading`. That swaps the `List` (which owns the `.refreshable` action) for a `ProgressView` mid-gesture, so SwiftUI's refresh coordinator loses its host view while the action is still in flight. The right fix mirrors the `handleCreated` path, which already calls `refresh()` (not `load()`) so the list stays mounted.

**Per `~/.claude/CLAUDE.md`:** "whenever a bug is discovered, first write a test reproducing it, confirm it fails, fix the code, run the test again." We don't have a SwiftUI integration test harness for the refreshable gesture; the testable distinction is between `load()` (which mutates `state`) and `refresh()` (which doesn't until the result arrives). A test on a small extracted helper captures the contract.

**Files:**
- Create: `Tests/GrafttyMobileKitTests/UI/WorktreePickerRefreshContractTests.swift` (or extend the existing grouping test file if it already exists at the point Task 1.5 runs)
- Modify: `Sources/GrafttyMobileKit/UI/WorktreePickerView.swift`

**Spec:** Add as new EARS requirement. Pick the next ID in the IOS-4 family — IOS-4.20 (refresh contract is a picker-rendering concern):

- **IOS-4.20** — While the user pull-to-refreshes the worktree picker (`IOS-4.1`), the application shall not blank the already-loaded list to a loading placeholder; the refresh shall re-fetch in place so the SwiftUI `.refreshable` host view remains mounted and the gesture completes without error.

- [ ] **Step 1:** Add the disabled inventory entry to `Tests/GrafttyTests/Specs/IosTodo.swift` (before the closing brace of `IosTodo`):

```swift
    @Test("""
@spec IOS-4.20: While the user pull-to-refreshes the worktree picker (`IOS-4.1`), the application shall not blank the already-loaded list to a loading placeholder; the refresh shall re-fetch in place so the SwiftUI `.refreshable` host view remains mounted and the gesture completes without error.
""", .disabled("not yet implemented"))
    func ios_4_20() async throws { }
```

- [ ] **Step 2:** Regenerate `SPECS.md`:

Run: `python3 scripts/generate-specs.py && python3 scripts/generate-specs.py --check`
Expected: both exit 0.

- [ ] **Step 3:** Promote the inventory entry to a real `@Test` in `Tests/GrafttyMobileKitTests/UI/WorktreePickerRefreshContractTests.swift`. We can't drive `.refreshable` from a unit test, but we CAN verify the underlying contract: the pull-to-refresh entry point must not mutate `state` before the fetch completes.

Extract `WorktreePickerView`'s refresh entry into a separately-callable static helper that takes a closure for the actual fetch. The test then asserts that calling the helper does not produce an intermediate `.loading` state visible to a caller observing the state transitions.

Add to `Sources/GrafttyMobileKit/UI/WorktreePickerGrouping.swift` (or wherever the grouping helper now lives by the time Task 7 has run — for Task 1.5 we'll create a new file `Sources/GrafttyMobileKit/UI/WorktreePickerRefresh.swift`):

```swift
#if canImport(UIKit)
import GrafttyProtocol

/// Pure refresh-coordination helper used by `WorktreePickerView`.
/// Extracted so the IOS-4.20 contract — "pull-to-refresh re-fetches in
/// place rather than blanking the list" — is unit-testable without a
/// SwiftUI gesture harness.
public enum WorktreePickerRefresh {

    /// State transitions an in-progress refresh produces. The picker
    /// view ignores the intermediate `.refetching` value and just
    /// applies `.replaced(...)` on completion, so the `List` that
    /// owns `.refreshable` stays mounted throughout.
    public enum Transition: Equatable {
        case refetching
        case replaced([WorktreePanes])
        case failed(String)
    }

    /// Drive a refresh against `fetch`. Yields exactly one terminal
    /// transition (`replaced` or `failed`). Does NOT yield `refetching`
    /// in this path — the caller is responsible for not setting an
    /// intermediate loading state.
    public static func refresh(
        fetch: () async throws -> [WorktreePanes]
    ) async -> Transition {
        do {
            return .replaced(try await fetch())
        } catch {
            return .failed("\(error)")
        }
    }
}
#endif
```

- [ ] **Step 4:** Add the failing test in `Tests/GrafttyMobileKitTests/UI/WorktreePickerRefreshContractTests.swift`:

```swift
#if canImport(UIKit)
import Testing
import Foundation
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("WorktreePickerRefresh")
struct WorktreePickerRefreshContractTests {

    @Test("""
    @spec IOS-4.20: While the user pull-to-refreshes the worktree picker (`IOS-4.1`), the application shall not blank the already-loaded list to a loading placeholder; the refresh shall re-fetch in place so the SwiftUI `.refreshable` host view remains mounted and the gesture completes without error.
    """)
    func refreshYieldsOnlyTerminalTransition() async {
        let payload = [WorktreePanes(
            path: "/p/wt", displayName: "wt", repoDisplayName: "r",
            displayBranch: "wt", state: .running, isMainCheckout: false,
            prBadge: nil, stats: nil, attentionText: nil, layout: nil
        )]
        let outcome = await WorktreePickerRefresh.refresh { payload }
        if case .replaced(let list) = outcome {
            #expect(list.count == 1)
        } else {
            Issue.record("expected .replaced, got \(outcome)")
        }
    }

    @Test func refreshFailureProducesTerminalFailure() async {
        struct Boom: Error {}
        let outcome = await WorktreePickerRefresh.refresh {
            throw Boom()
        }
        if case .failed = outcome {} else {
            Issue.record("expected .failed, got \(outcome)")
        }
    }
}
#endif
```

- [ ] **Step 5:** Run the test to confirm it fails (helper doesn't exist yet).

Run: `swift test --filter WorktreePickerRefreshContractTests`
Expected: compile error or test failure.

- [ ] **Step 6:** Add the helper (per Step 3 code block above).

- [ ] **Step 7:** Run the test again — should pass.

Run: `swift test --filter WorktreePickerRefreshContractTests`
Expected: GREEN.

- [ ] **Step 8:** Delete the `ios_4_20` `.disabled` entry from `IosTodo.swift`.

- [ ] **Step 9:** Fix `WorktreePickerView.swift`. Change the `.refreshable` modifier from:

```swift
                .refreshable { await load() }
```

to:

```swift
                .refreshable { await refresh() }
```

This is the actual bugfix. The contract test in Step 4 covers the helper; the manual fix here applies the same principle to the real call site.

- [ ] **Step 10:** Regenerate `SPECS.md`.

Run: `python3 scripts/generate-specs.py && python3 scripts/generate-specs.py --check`
Expected: both exit 0.

- [ ] **Step 11:** Commit.

```bash
git add Sources/GrafttyMobileKit/UI/WorktreePickerRefresh.swift Sources/GrafttyMobileKit/UI/WorktreePickerView.swift Tests/GrafttyMobileKitTests/UI/WorktreePickerRefreshContractTests.swift Tests/GrafttyTests/Specs/IosTodo.swift SPECS.md
git commit -m "mobile: stop blanking picker list on pull-to-refresh (IOS-4.20)"
```

---

## Task 2: Wire types + `worktreeRemover` plumbing through `WebServer.Config` and `WebServerController`

**Goal:** Add the request/response/outcome shapes and the closure field so subsequent tasks can wire the route and the Mac-side flow against them. No route handler yet — that's Task 3.

**Files:**
- Modify: `Sources/GrafttyKit/Web/WebServer.swift` — add types + Config field + init parameter
- Modify: `Sources/Graftty/Web/WebServerController.swift` — add `setWorktreeRemover` setter, store closure, pass it into `WebServer(config:)`

- [ ] **Step 1:** In `WebServer.swift`, immediately below the existing `CreateWorktreeOutcome` enum (around line 81), add:

```swift
    /// JSON body accepted by `POST /worktrees/delete`. `force` mirrors
    /// the Mac's GIT-4.12 "Force Delete" branch — clients send `false`
    /// first, then re-issue with `true` if they receive a 409 carrying
    /// `forceAllowed: true`.
    public struct DeleteWorktreeRequest: Codable, Sendable, Equatable {
        public let worktreePath: String
        public let force: Bool

        public init(worktreePath: String, force: Bool) {
            self.worktreePath = worktreePath
            self.force = force
        }
    }

    /// JSON body returned by `POST /worktrees/delete` on success.
    /// `dismissed == true` when the flow ran the GIT-4.13 prune-on-
    /// vanished branch; `false` when `git worktree remove` succeeded.
    public struct DeleteWorktreeResponse: Codable, Sendable, Equatable {
        public let dismissed: Bool

        public init(dismissed: Bool) {
            self.dismissed = dismissed
        }
    }

    /// Outcome a `worktreeRemover` reports back. `gitFailedForceable`
    /// holds the trimmed `git status --short` snapshot captured at the
    /// failure point — that's what the iOS Force Delete dialog shows
    /// the user, matching ForceDeleteAlert's macOS behavior.
    public enum DeleteWorktreeOutcome: Sendable {
        case success(DeleteWorktreeResponse)
        case invalid(String)                       // 400 — empty/main checkout
        case notFound(String)                      // 404 — unknown worktree path
        case gitFailedForceable(stderr: String, shortStatus: String) // 409 forceAllowed:true
        case gitFailedFinal(String)                // 409 forceAllowed:false
        case internalFailure(String)               // 500
    }
```

- [ ] **Step 2:** In `WebServer.Config`, add a new stored property between `worktreeCreator` and `ghosttyConfigProvider` (around line 103):

```swift
        /// Executes `POST /worktrees/delete`. Nil disables the endpoint
        /// (503), same contract as `worktreeCreator`. Production wires
        /// this to `DeleteWorktreeFlow.delete` via `GrafttyApp.startup()`.
        public let worktreeRemover: (@Sendable (DeleteWorktreeRequest) async -> DeleteWorktreeOutcome)?
```

- [ ] **Step 3:** Add the matching parameter to `Config.init` (around line 124), with a `nil` default:

```swift
            worktreeRemover: (@Sendable (DeleteWorktreeRequest) async -> DeleteWorktreeOutcome)? = nil,
```

…and assign it in the body of `init`:

```swift
            self.worktreeRemover = worktreeRemover
```

Place the parameter **after** `worktreeCreator` and **before** `ghosttyConfigProvider`, and place the assignment in the same relative order, matching how the existing fields are grouped.

- [ ] **Step 4:** In `WebServerController.swift`, add the stored closure (around line 39, adjacent to `worktreeCreator`):

```swift
    /// Executes `POST /worktrees/delete` (`WEB-7.8` / `WEB-7.9` /
    /// `WEB-7.10`). Routes into `DeleteWorktreeFlow.delete` on the
    /// main actor. Nil before injection causes the endpoint to respond
    /// `503 service unavailable`.
    private var worktreeRemover: (@Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome)?
```

- [ ] **Step 5:** Add the matching setter immediately below `setWorktreeCreator` (around line 117):

```swift
    /// Install the remover used for `POST /worktrees/delete`. Same
    /// contract as `setWorktreeCreator`: pre-injection requests get
    /// `503 service unavailable`.
    func setWorktreeRemover(
        _ remover: @escaping @Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome
    ) {
        worktreeRemover = remover
        rebuildIfRunning()
    }
```

- [ ] **Step 6:** In `completeReconcile`, pass the new closure through to `WebServer.Config`. Find the `let creator = worktreeCreator` line (around 241) and add immediately below:

```swift
        let remover = worktreeRemover
```

…then in the `WebServer(config: .init(...))` call (around 242), add `worktreeRemover: remover` after `worktreeCreator: creator,` so the argument list reads:

```swift
                worktreeCreator: creator,
                worktreeRemover: remover,
                ghosttyConfigProvider: { GhosttyConfigReader.resolvedConfig() },
                worktreePanesProvider: worktreePanesProvider ?? { [] }
```

- [ ] **Step 7:** Verify the project still builds.

Run: `swift build`
Expected: builds clean. No tests yet for the new path — Task 3 adds them.

- [ ] **Step 8:** Commit.

```bash
git add Sources/GrafttyKit/Web/WebServer.swift Sources/Graftty/Web/WebServerController.swift
git commit -m "web: plumb worktreeRemover through Config + Controller (WEB-7.8 prep)"
```

---

## Task 3: Server endpoint — TDD the `POST /worktrees/delete` handler

**Goal:** Promote WEB-7.8, WEB-7.9, WEB-7.10 from Todo entries to failing tests, then wire the NIO HTTP handler to make them pass.

**Files:**
- Create: `Tests/GrafttyKitTests/Web/WebServerDeleteEndpointTests.swift`
- Modify: `Tests/GrafttyTests/Specs/WebTodo.swift` — remove the three Todo entries for WEB-7.8/7.9/7.10 (they're now real @Tests in the new test file)
- Modify: `Sources/GrafttyKit/Web/WebServer.swift` — add `handleDeleteWorktree` private method on `HTTPHandler`; dispatch `/worktrees/delete` in `serveStatic`

- [ ] **Step 1:** Create the test file with three real `@Test`s carrying the EARS text. The skip-in-CI guard mirrors `WebServerWorktreeEndpointTests` exactly.

```swift
import Testing
import Foundation
@testable import GrafttyKit

/// Endpoint coverage for `POST /worktrees/delete`. Uses a stub
/// `worktreeRemover` closure so these tests stay independent of
/// `DeleteWorktreeFlow`, `AppState`, and the `git` binary.
///
/// Skipped in CI for the same swift-testing exit-path reasons that
/// skip `WebServerWorktreeEndpointTests`; see that file's header
/// comment for the full rationale.
@Suite("WebServer — /worktrees/delete endpoint", .serialized)
struct WebServerDeleteEndpointTests {

    private static var skipInCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    private static func makeConfig(
        remover: (@Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome)? = nil
    ) -> WebServer.Config {
        WebServer.Config(
            port: 0,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            worktreeRemover: remover
        )
    }

    private static func startServer(
        config: WebServer.Config,
        isAllowed: @escaping @Sendable (String) async -> Bool = { _ in true }
    ) throws -> (server: WebServer, port: Int) {
        let server = WebServer(
            config: config,
            auth: WebServer.AuthPolicy(isAllowed: isAllowed),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: try makeTestTLSProvider()
        )
        try server.start()
        guard case let .listening(_, port) = server.status else {
            throw NSError(domain: "test", code: 1)
        }
        return (server, port)
    }

    private static func postDelete(
        port: Int,
        worktreePath: String,
        force: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONEncoder().encode(WebServer.DeleteWorktreeRequest(
            worktreePath: worktreePath, force: force
        ))
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees/delete")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await trustAllData(for: req)
        return (data, response as! HTTPURLResponse)
    }

    @Test("""
    @spec WEB-7.8: When a client sends `POST /worktrees/delete` with `{ "worktreePath": "<abs>", "force": <bool> }`, the application shall route the request through `DeleteWorktreeFlow.delete` and respond `200 { "dismissed": <bool> }` on success. `dismissed` shall be `true` when the flow took the GIT-3.6 / GIT-4.13 prune-on-vanished branch and `false` when `git worktree remove` succeeded. The `/worktrees/delete` endpoint accepts `POST` only; other verbs return `405 Method Not Allowed`.
    """)
    func deleteSuccessReturnsDismissedFlag() async throws {
        if Self.skipInCI { return }

        let remover: @Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome = { req in
            #expect(req.worktreePath == "/tmp/repo/.worktrees/feature-x")
            #expect(req.force == false)
            return .success(WebServer.DeleteWorktreeResponse(dismissed: false))
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(remover: remover))
        defer { server.stop() }

        let (data, http) = try await Self.postDelete(
            port: port,
            worktreePath: "/tmp/repo/.worktrees/feature-x",
            force: false
        )
        #expect(http.statusCode == 200)
        let decoded = try JSONDecoder().decode(WebServer.DeleteWorktreeResponse.self, from: data)
        #expect(decoded.dismissed == false)
    }

    @Test func deleteSuccessWithPruneBranchReturnsDismissedTrue() async throws {
        if Self.skipInCI { return }

        let remover: @Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome = { _ in
            .success(WebServer.DeleteWorktreeResponse(dismissed: true))
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(remover: remover))
        defer { server.stop() }

        let (data, http) = try await Self.postDelete(
            port: port, worktreePath: "/tmp/repo/.worktrees/stale", force: false
        )
        #expect(http.statusCode == 200)
        let decoded = try JSONDecoder().decode(WebServer.DeleteWorktreeResponse.self, from: data)
        #expect(decoded.dismissed == true)
    }

    @Test func deleteGetReturns405() async throws {
        if Self.skipInCI { return }

        let (server, port) = try Self.startServer(config: Self.makeConfig(
            remover: { _ in .internalFailure("unused") }
        ))
        defer { server.stop() }

        let (_, response) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/worktrees/delete")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 405)
    }

    @Test("""
    @spec WEB-7.9: If the server-side delete flow encounters a git failure that `--force` could resolve, then the application shall respond `409 Conflict` with `{ "error": "<stderr>", "forceAllowed": true, "shortStatus": "<git status --short output>" }`. When `--force` has already been attempted, or the failure class is one `--force` cannot help (e.g. main-checkout rejection), the response shall be `409 Conflict` with `forceAllowed: false` and no `shortStatus` field.
    """)
    func deleteForceableFailureReturns409WithStatus() async throws {
        if Self.skipInCI { return }

        let remover: @Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome = { _ in
            .gitFailedForceable(
                stderr: "fatal: contains modified or untracked files, use --force to delete it",
                shortStatus: " M foo.swift\n?? bar.swift"
            )
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(remover: remover))
        defer { server.stop() }

        let (data, http) = try await Self.postDelete(
            port: port, worktreePath: "/tmp/repo/.worktrees/dirty", force: false
        )
        #expect(http.statusCode == 409)
        struct Body: Codable { let error: String; let forceAllowed: Bool; let shortStatus: String? }
        let decoded = try JSONDecoder().decode(Body.self, from: data)
        #expect(decoded.forceAllowed == true)
        #expect(decoded.shortStatus == " M foo.swift\n?? bar.swift")
        #expect(decoded.error.contains("--force"))
    }

    @Test func deleteFinalFailureReturns409WithoutShortStatus() async throws {
        if Self.skipInCI { return }

        let remover: @Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome = { _ in
            .gitFailedFinal("fatal: main working tree cannot be removed")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(remover: remover))
        defer { server.stop() }

        let (data, http) = try await Self.postDelete(
            port: port, worktreePath: "/tmp/repo", force: false
        )
        #expect(http.statusCode == 409)
        struct Body: Codable { let error: String; let forceAllowed: Bool; let shortStatus: String? }
        let decoded = try JSONDecoder().decode(Body.self, from: data)
        #expect(decoded.forceAllowed == false)
        #expect(decoded.shortStatus == nil)
    }

    @Test func deleteInvalidJSONReturns400() async throws {
        if Self.skipInCI { return }

        let (server, port) = try Self.startServer(config: Self.makeConfig(
            remover: { _ in Issue.record("remover should not run on invalid JSON"); return .internalFailure("x") }
        ))
        defer { server.stop() }

        var req = URLRequest(url: URL(string: "https://localhost:\(port)/worktrees/delete")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("not json".utf8)
        let (_, response) = try await trustAllData(for: req)
        #expect((response as! HTTPURLResponse).statusCode == 400)
    }

    @Test func deleteEmptyPathReturns400WithoutInvokingRemover() async throws {
        if Self.skipInCI { return }

        let (server, port) = try Self.startServer(config: Self.makeConfig(
            remover: { _ in Issue.record("remover should not run on empty path"); return .internalFailure("x") }
        ))
        defer { server.stop() }

        let (_, http) = try await Self.postDelete(port: port, worktreePath: "   ", force: false)
        #expect(http.statusCode == 400)
    }

    @Test func deleteNotFoundReturns404() async throws {
        if Self.skipInCI { return }

        let remover: @Sendable (WebServer.DeleteWorktreeRequest) async -> WebServer.DeleteWorktreeOutcome = { _ in
            .notFound("unknown worktree path")
        }
        let (server, port) = try Self.startServer(config: Self.makeConfig(remover: remover))
        defer { server.stop() }

        let (_, http) = try await Self.postDelete(
            port: port, worktreePath: "/tmp/nope", force: false
        )
        #expect(http.statusCode == 404)
    }

    @Test("""
    @spec WEB-7.10: If the server's `worktreeRemover` closure is not injected, then `POST /worktrees/delete` shall respond `503 Service Unavailable` with `{ "error": "worktree deletion not available" }`. This matches the create endpoint's pre-injection contract (WEB-7.4 sibling) so a mobile or web client can distinguish "not supported yet" from "wrong URL".
    """)
    func deleteWithoutRemoverReturns503() async throws {
        if Self.skipInCI { return }

        let (server, port) = try Self.startServer(config: Self.makeConfig(remover: nil))
        defer { server.stop() }

        let (data, http) = try await Self.postDelete(
            port: port, worktreePath: "/tmp/x", force: false
        )
        #expect(http.statusCode == 503)
        struct Body: Codable { let error: String }
        let decoded = try JSONDecoder().decode(Body.self, from: data)
        #expect(decoded.error.contains("not available"))
    }

    @Test func deleteDeniedReturns403WithoutInvokingRemover() async throws {
        if Self.skipInCI { return }

        let (server, port) = try Self.startServer(
            config: Self.makeConfig(
                remover: { _ in Issue.record("remover should not run before auth succeeds"); return .internalFailure("x") }
            ),
            isAllowed: { _ in false }
        )
        defer { server.stop() }

        let (_, http) = try await Self.postDelete(
            port: port, worktreePath: "/tmp/x", force: false
        )
        #expect(http.statusCode == 403)
    }
}
```

- [ ] **Step 2:** Delete the three `web_7_8` / `web_7_9` / `web_7_10` `.disabled` entries from `WebTodo.swift` (they were added in Task 1; now they live in `WebServerDeleteEndpointTests.swift`).

- [ ] **Step 3:** Run the tests to confirm they fail RED (no handler wired yet).

Run: `swift test --filter WebServerDeleteEndpointTests`
Expected: every test fails. Status codes are likely `404` or `200`-with-index-html (NIO's SPA fallback serves `index.html` for any unmatched path).

- [ ] **Step 4:** In `WebServer.swift`, inside `HTTPHandler.serveStatic`, add a new branch immediately after the existing `if path == "/worktrees"` block (so before the static-asset fallback). Match the existing style — POST-only, 405 otherwise, 503 when remover absent:

```swift
            // WEB-7.8 / WEB-7.9 / WEB-7.10: delete or dismiss a worktree.
            // POST-only; body is the same JSON envelope the iOS client
            // sends. Other verbs get 405 so caching proxies and curl
            // probes don't surprise the client.
            if path == "/worktrees/delete" {
                guard head.method == .POST else {
                    Self.respondJSON(
                        context: context,
                        status: .methodNotAllowed,
                        error: "only POST is supported"
                    )
                    return
                }
                handleDeleteWorktree(context: context, body: body)
                return
            }
```

- [ ] **Step 5:** Add the handler implementation as a new `private func` on `HTTPHandler`, immediately below `handleCreateWorktree`:

```swift
        /// Decode the JSON body, invoke the injected `worktreeRemover`,
        /// and map its `DeleteWorktreeOutcome` to an HTTP status + JSON
        /// envelope. Same scheduling shape as `handleCreateWorktree`.
        private func handleDeleteWorktree(context: ChannelHandlerContext, body: Data) {
            guard let remover = config.worktreeRemover else {
                Self.respondJSON(
                    context: context,
                    status: .serviceUnavailable,
                    error: "worktree deletion not available"
                )
                return
            }
            let decoded: WebServer.DeleteWorktreeRequest
            do {
                decoded = try JSONDecoder().decode(WebServer.DeleteWorktreeRequest.self, from: body)
            } catch {
                Self.respondJSON(
                    context: context,
                    status: .badRequest,
                    error: "invalid JSON body: \(error)"
                )
                return
            }
            let trimmedPath = decoded.worktreePath.trimmingCharacters(in: .whitespaces)
            if trimmedPath.isEmpty {
                Self.respondJSON(
                    context: context,
                    status: .badRequest,
                    error: "worktreePath is required"
                )
                return
            }

            let promise = context.eventLoop.makePromise(of: WebServer.DeleteWorktreeOutcome.self)
            promise.futureResult.whenComplete { result in
                let outcome = (try? result.get()) ?? .internalFailure("remover dispatch failed")
                switch outcome {
                case .success(let resp):
                    do {
                        let data = try JSONEncoder().encode(resp)
                        Self.respond(
                            context: context,
                            status: .ok,
                            body: data,
                            contentType: "application/json; charset=utf-8"
                        )
                    } catch {
                        Self.respondJSON(
                            context: context,
                            status: .internalServerError,
                            error: "encoding error"
                        )
                    }
                case .invalid(let msg):
                    Self.respondJSON(context: context, status: .badRequest, error: msg)
                case .notFound(let msg):
                    Self.respondJSON(context: context, status: .notFound, error: msg)
                case .gitFailedForceable(let stderr, let shortStatus):
                    struct ForceableBody: Codable {
                        let error: String
                        let forceAllowed: Bool
                        let shortStatus: String
                    }
                    let body = (try? JSONEncoder().encode(ForceableBody(
                        error: stderr, forceAllowed: true, shortStatus: shortStatus
                    ))) ?? Data(#"{"error":"unknown","forceAllowed":true}"#.utf8)
                    Self.respond(
                        context: context,
                        status: .conflict,
                        body: body,
                        contentType: "application/json; charset=utf-8"
                    )
                case .gitFailedFinal(let stderr):
                    struct FinalBody: Codable { let error: String; let forceAllowed: Bool }
                    let body = (try? JSONEncoder().encode(FinalBody(
                        error: stderr, forceAllowed: false
                    ))) ?? Data(#"{"error":"unknown","forceAllowed":false}"#.utf8)
                    Self.respond(
                        context: context,
                        status: .conflict,
                        body: body,
                        contentType: "application/json; charset=utf-8"
                    )
                case .internalFailure(let msg):
                    Self.respondJSON(context: context, status: .internalServerError, error: msg)
                }
            }
            Task {
                promise.succeed(await remover(decoded))
            }
        }
```

- [ ] **Step 6:** Re-run the tests.

Run: `swift test --filter WebServerDeleteEndpointTests`
Expected: all tests pass.

- [ ] **Step 7:** Regenerate `SPECS.md` and run the check.

Run: `python3 scripts/generate-specs.py && python3 scripts/generate-specs.py --check`
Expected: both exit 0.

- [ ] **Step 8:** Commit.

```bash
git add Sources/GrafttyKit/Web/WebServer.swift Tests/GrafttyKitTests/Web/WebServerDeleteEndpointTests.swift Tests/GrafttyTests/Specs/WebTodo.swift SPECS.md
git commit -m "web: implement POST /worktrees/delete (WEB-7.8/7.9/7.10)"
```

---

## Task 4: Extract `DeleteWorktreeFlow` from `MainWindow.performDeleteWorktree`

**Goal:** Pure refactor — pull the git invocation, prune fallback, and teardown into a new flow file mirroring `AddWorktreeFlow`. Behavior preserved; `MainWindow.performDeleteWorktree` shrinks to alert UX + flow call.

**Files:**
- Create: `Sources/Graftty/DeleteWorktreeFlow.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift` — `performDeleteWorktree` becomes a thin shim around the flow

- [ ] **Step 1:** Create `Sources/Graftty/DeleteWorktreeFlow.swift`:

```swift
import Foundation
import SwiftUI
import GrafttyKit

/// Shared "remove a worktree" flow used by:
///   - The native sidebar's `MainWindow.performDeleteWorktree`
///   - The web/iOS `POST /worktrees/delete` endpoint
///
/// Both entry points need the same sequence: `git worktree remove` (with
/// GIT-4.13 prune-on-vanished recovery), `git status --short` capture on
/// failure to drive the Force Delete UX (GIT-4.4), surface teardown,
/// per-path cache clears, model removal, and the TEAM-5.3 `left` event.
///
/// Confirmation UX is NOT part of this flow — every entry point owns
/// its own confirmation affordance (NSAlert on macOS, SwiftUI
/// `.confirmationDialog` on iOS), and the flow runs unconditionally
/// once invoked.
///
/// Mirrors `AddWorktreeFlow`'s placement (in the `Graftty` target, not
/// `GrafttyKit`) because `TerminalManager` and the SwiftUI bindings
/// are AppKit-bound.
@MainActor
enum DeleteWorktreeFlow {

    /// Successful outcome carries which branch the flow took so the
    /// caller can label its UI (mac alert message, mobile toast).
    /// `dismissed == true` means we ran `GitWorktreePrune` because the
    /// worktree directory was already gone; `false` means
    /// `git worktree remove` succeeded normally.
    struct Outcome {
        let dismissed: Bool
    }

    enum FlowError: Error {
        /// `git worktree remove` failed in a way `--force` could resolve
        /// (uncommitted/untracked files). Carries stderr + a `git status
        /// --short` snapshot to surface in the failure UI.
        case gitFailedForceable(stderr: String, shortStatus: String)
        /// Failure that `--force` cannot help with: either `--force` was
        /// already attempted, or the failure class is structural (main
        /// checkout, non-git repo, git binary missing).
        case gitFailedFinal(String)
        /// `worktreePath` did not resolve to any tracked worktree.
        case notFound
        /// `worktreePath` resolved to the repo's main checkout, which
        /// `git worktree remove` refuses by design.
        case mainCheckoutRejected
    }

    /// Run the flow. Confirmation must have already happened; this
    /// function performs the irreversible side effects unconditionally.
    static func delete(
        worktreePath: String,
        force: Bool,
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        teamEventDispatcher: TeamEventDispatcher
    ) async -> Swift.Result<Outcome, FlowError> {
        guard let (repoIdx, wtIdx) = appState.wrappedValue.indices(forWorktreePath: worktreePath) else {
            return .failure(.notFound)
        }
        let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
        let repoPath = appState.wrappedValue.repos[repoIdx].path

        if wt.path == repoPath {
            return .failure(.mainCheckoutRejected)
        }
        guard appState.wrappedValue.repos[repoIdx].isGitTracked else {
            return .failure(.gitFailedFinal("not a git repository"))
        }

        do {
            try await GitWorktreeRemove.remove(
                repoPath: repoPath,
                worktreePath: worktreePath,
                force: force
            )
        } catch GitWorktreeRemove.Error.gitFailed(_, let stderr) {
            // GIT-4.13: directory vanished but admin entry survives.
            // `--force` can't bypass git's path validation, so we
            // never offer Force Delete for this branch — we silently
            // prune and treat it as a dismiss.
            if !FileManager.default.fileExists(atPath: worktreePath) {
                try? await GitWorktreePrune.run(repoPath: repoPath)
                finishRemoval(
                    worktree: wt,
                    repoPath: repoPath,
                    appState: appState,
                    terminalManager: terminalManager,
                    statsStore: statsStore,
                    prStatusStore: prStatusStore,
                    teamEventDispatcher: teamEventDispatcher
                )
                return .success(Outcome(dismissed: true))
            }
            if force {
                return .failure(.gitFailedFinal(stderr.isEmpty ? "git worktree remove --force failed" : stderr))
            }
            let status = await GitStatusCapture.shortStatus(at: worktreePath)
            return .failure(.gitFailedForceable(
                stderr: stderr.isEmpty ? "git worktree remove failed" : stderr,
                shortStatus: status
            ))
        } catch {
            return .failure(.gitFailedFinal("\(error)"))
        }

        finishRemoval(
            worktree: wt,
            repoPath: repoPath,
            appState: appState,
            terminalManager: terminalManager,
            statsStore: statsStore,
            prStatusStore: prStatusStore,
            teamEventDispatcher: teamEventDispatcher
        )
        return .success(Outcome(dismissed: false))
    }

    /// Post-remove teardown. Identical ordering to the previous
    /// `MainWindow.finishWorktreeRemoval`: surface teardown for running
    /// worktrees, per-path cache clears BEFORE the model entry drops
    /// (GIT-4.10), then the `removeWorktree` mutation, then the
    /// TEAM-5.3 `left` event whose repo lookup must use the original
    /// `repoPath` because the worktree is gone from AppState by now.
    private static func finishRemoval(
        worktree wt: WorktreeEntry,
        repoPath: String,
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        teamEventDispatcher: TeamEventDispatcher
    ) {
        if wt.state == .running {
            terminalManager.destroySurfaces(terminalIDs: wt.splitTree.allLeaves)
        }
        prStatusStore.clear(worktreePath: wt.path)
        statsStore.clear(worktreePath: wt.path)
        let leaverBranch = wt.branch
        appState.wrappedValue.removeWorktree(atPath: wt.path)
        if let repo = appState.wrappedValue.repo(forWorktreePath: repoPath) {
            TeamMembershipEvents.fireLeft(
                repo: repo,
                leaverBranch: leaverBranch,
                leaverPath: wt.path,
                reason: .removed,
                teamsEnabled: UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled),
                dispatcher: teamEventDispatcher
            )
        }
    }
}
```

- [ ] **Step 2:** Modify `MainWindow.swift` — replace the body of `performDeleteWorktree` and delete the now-orphaned `finishWorktreeRemoval`.

Replace the current `performDeleteWorktree` (lines ~638–710) with:

```swift
    /// Shared `git worktree remove` + teardown path used by both the
    /// user-initiated "Delete Worktree" menu action and the PR-merged
    /// offer dialog. Callers own the confirmation UX — this helper runs
    /// git unconditionally and surfaces failures via the same error
    /// alert as the menu path. `force` is set internally on retry from
    /// the GIT-4.4 dialog; see GIT-4.12.
    private func performDeleteWorktree(_ worktreePath: String, force: Bool = false) {
        Task { @MainActor in
            let result = await DeleteWorktreeFlow.delete(
                worktreePath: worktreePath,
                force: force,
                appState: $appState,
                terminalManager: terminalManager,
                statsStore: statsStore,
                prStatusStore: prStatusStore,
                teamEventDispatcher: teamEventDispatcher
            )
            switch result {
            case .success:
                return
            case .failure(.notFound), .failure(.mainCheckoutRejected):
                // UI gating already prevents these; silently no-op
                // matches the pre-refactor behavior.
                return
            case .failure(.gitFailedForceable(let stderr, let status)):
                let errorAlert = NSAlert()
                errorAlert.messageText = "Could not delete worktree"
                errorAlert.informativeText = ForceDeleteAlert.informativeText(stderr: stderr, status: status)
                errorAlert.alertStyle = .warning
                errorAlert.addButton(withTitle: "Cancel")
                errorAlert.addButton(withTitle: "Force Delete")
                guard errorAlert.runModal() == .alertSecondButtonReturn else { return }
                performDeleteWorktree(worktreePath, force: true)
            case .failure(.gitFailedFinal(let msg)):
                NSLog("[Graftty] performDeleteWorktree: %@", msg)
                let errorAlert = NSAlert()
                errorAlert.messageText = "Could not delete worktree"
                errorAlert.informativeText = msg
                errorAlert.alertStyle = .warning
                errorAlert.runModal()
            }
        }
    }
```

Delete the original `finishWorktreeRemoval` method (lines ~718–737) — it now lives inside `DeleteWorktreeFlow`.

- [ ] **Step 3:** Build the Mac target and confirm nothing regressed structurally:

Run: `swift build`
Expected: clean build. (We deliberately don't add `DeleteWorktreeFlow` unit tests; see the spec's Testing section.)

- [ ] **Step 4:** Sanity-run the existing tests to make sure no test was relying on the removed `finishWorktreeRemoval` shape:

Run: `swift test --filter MainWindow` (or `swift test` if it's fast enough locally)
Expected: same set of pass/fail as before the refactor (no new failures introduced by the extraction).

- [ ] **Step 5:** Commit.

```bash
git add Sources/Graftty/DeleteWorktreeFlow.swift Sources/Graftty/Views/MainWindow.swift
git commit -m "graftty: extract DeleteWorktreeFlow for shared mac/web/iOS delete path"
```

---

## Task 5: Wire `setWorktreeRemover` in `GrafttyApp.startup()`

**Goal:** Connect the HTTP endpoint to the flow, completing the Mac → iOS round trip on the server side.

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift` — add a `webController.setWorktreeRemover { ... }` block adjacent to `setWorktreeCreator`

- [ ] **Step 1:** In `GrafttyApp.swift`, find the existing `webController.setWorktreeCreator { req in ... }` block (around line 1183). Immediately after that block's closing brace, add:

```swift
        // WEB-7.8: drive `POST /worktrees/delete` into the shared
        // `DeleteWorktreeFlow`. Mirrors the create wiring above —
        // closure runs on `MainActor` via `DeleteWorktreeFlow.delete`'s
        // `@MainActor` isolation, so every `appState` mutation and
        // surface teardown lands on the main actor, same as the native
        // sidebar's "Delete Worktree" path.
        let prStoreForWeb = services.prStatusStore
        let statsStoreForWeb = services.statsStore
        let dispatcherForWebDelete = services.teamEventDispatcher
        webController.setWorktreeRemover { req in
            let result = await DeleteWorktreeFlow.delete(
                worktreePath: req.worktreePath,
                force: req.force,
                appState: appStateBinding,
                terminalManager: tm,
                statsStore: statsStoreForWeb,
                prStatusStore: prStoreForWeb,
                teamEventDispatcher: dispatcherForWebDelete
            )
            switch result {
            case .success(let outcome):
                return .success(WebServer.DeleteWorktreeResponse(dismissed: outcome.dismissed))
            case .failure(.notFound):
                return .notFound("unknown worktree path")
            case .failure(.mainCheckoutRejected):
                return .invalid("cannot delete the repo's main checkout")
            case .failure(.gitFailedForceable(let stderr, let status)):
                return .gitFailedForceable(stderr: stderr, shortStatus: status)
            case .failure(.gitFailedFinal(let msg)):
                return .gitFailedFinal(msg)
            }
        }
```

- [ ] **Step 2:** Build.

Run: `swift build`
Expected: clean.

- [ ] **Step 3:** Commit.

```bash
git add Sources/Graftty/GrafttyApp.swift
git commit -m "graftty: wire POST /worktrees/delete to DeleteWorktreeFlow"
```

---

## Task 6: `DeleteWorktreeClient` + tests on iOS

**Goal:** Add the iOS-side HTTP client mirroring `CreateWorktreeClient`, with TDD coverage of the success/forceable/final/transport branches.

**Files:**
- Create: `Tests/GrafttyMobileKitTests/Session/DeleteWorktreeClientTests.swift`
- Create: `Sources/GrafttyMobileKit/Session/DeleteWorktreeClient.swift`

- [ ] **Step 1:** Read the existing `CreateWorktreeClientTests.swift` for the URLProtocol-stub fixture pattern so the new tests match it exactly.

Run: `cat Tests/GrafttyMobileKitTests/Session/CreateWorktreeClientTests.swift | head -50`
Expected: shows the URLProtocol-stub setup. Reuse it.

- [ ] **Step 2:** Create the test file. Match `CreateWorktreeClientTests`'s `#if canImport(UIKit)` guard.

```swift
#if canImport(UIKit)
import Testing
import Foundation
@testable import GrafttyMobileKit

@Suite("DeleteWorktreeClient — wire decoding")
struct DeleteWorktreeClientTests {

    @Test func successDismissedFalse() async throws {
        let body = Data(#"{"dismissed":false}"#.utf8)
        URLProtocolStub.stub(
            url: URL(string: "https://host/worktrees/delete")!,
            status: 200,
            body: body,
            contentType: "application/json"
        )
        let resp = try await DeleteWorktreeClient.delete(
            baseURL: URL(string: "https://host")!,
            body: DeleteWorktreeClient.Request(worktreePath: "/p", force: false),
            session: URLProtocolStub.session()
        )
        #expect(resp.dismissed == false)
    }

    @Test func successDismissedTrue() async throws {
        URLProtocolStub.stub(
            url: URL(string: "https://host/worktrees/delete")!,
            status: 200,
            body: Data(#"{"dismissed":true}"#.utf8),
            contentType: "application/json"
        )
        let resp = try await DeleteWorktreeClient.delete(
            baseURL: URL(string: "https://host")!,
            body: DeleteWorktreeClient.Request(worktreePath: "/p", force: false),
            session: URLProtocolStub.session()
        )
        #expect(resp.dismissed == true)
    }

    @Test func conflictForceableSurfacesShortStatus() async throws {
        let json = #"{"error":"contains modified files","forceAllowed":true,"shortStatus":" M foo.swift"}"#
        URLProtocolStub.stub(
            url: URL(string: "https://host/worktrees/delete")!,
            status: 409,
            body: Data(json.utf8),
            contentType: "application/json"
        )
        do {
            _ = try await DeleteWorktreeClient.delete(
                baseURL: URL(string: "https://host")!,
                body: DeleteWorktreeClient.Request(worktreePath: "/p", force: false),
                session: URLProtocolStub.session()
            )
            Issue.record("expected gitFailedForceable")
        } catch let DeleteWorktreeClient.DeleteError.gitFailedForceable(stderr, status) {
            #expect(stderr.contains("modified files"))
            #expect(status.contains("foo.swift"))
        }
    }

    @Test func conflictFinalReturnsGitFailedFinal() async throws {
        let json = #"{"error":"main checkout cannot be removed","forceAllowed":false}"#
        URLProtocolStub.stub(
            url: URL(string: "https://host/worktrees/delete")!,
            status: 409,
            body: Data(json.utf8),
            contentType: "application/json"
        )
        do {
            _ = try await DeleteWorktreeClient.delete(
                baseURL: URL(string: "https://host")!,
                body: DeleteWorktreeClient.Request(worktreePath: "/p", force: false),
                session: URLProtocolStub.session()
            )
            Issue.record("expected gitFailedFinal")
        } catch let DeleteWorktreeClient.DeleteError.gitFailedFinal(msg) {
            #expect(msg.contains("main checkout"))
        }
    }

    @Test func notFoundReturns404Error() async throws {
        URLProtocolStub.stub(
            url: URL(string: "https://host/worktrees/delete")!,
            status: 404,
            body: Data(#"{"error":"unknown worktree"}"#.utf8),
            contentType: "application/json"
        )
        do {
            _ = try await DeleteWorktreeClient.delete(
                baseURL: URL(string: "https://host")!,
                body: DeleteWorktreeClient.Request(worktreePath: "/p", force: false),
                session: URLProtocolStub.session()
            )
            Issue.record("expected notFound")
        } catch DeleteWorktreeClient.DeleteError.notFound { }
    }

    @Test func forbiddenReturnsForbidden() async throws {
        URLProtocolStub.stub(
            url: URL(string: "https://host/worktrees/delete")!,
            status: 403,
            body: Data(),
            contentType: "text/plain"
        )
        do {
            _ = try await DeleteWorktreeClient.delete(
                baseURL: URL(string: "https://host")!,
                body: DeleteWorktreeClient.Request(worktreePath: "/p", force: false),
                session: URLProtocolStub.session()
            )
            Issue.record("expected forbidden")
        } catch DeleteWorktreeClient.DeleteError.forbidden { }
    }

    @Test func serviceUnavailableReturnsUnavailable() async throws {
        URLProtocolStub.stub(
            url: URL(string: "https://host/worktrees/delete")!,
            status: 503,
            body: Data(#"{"error":"worktree deletion not available"}"#.utf8),
            contentType: "application/json"
        )
        do {
            _ = try await DeleteWorktreeClient.delete(
                baseURL: URL(string: "https://host")!,
                body: DeleteWorktreeClient.Request(worktreePath: "/p", force: false),
                session: URLProtocolStub.session()
            )
            Issue.record("expected unavailable")
        } catch let DeleteWorktreeClient.DeleteError.unavailable(msg) {
            #expect(msg.contains("not available"))
        }
    }
}
#endif
```

> If the stub harness here (`URLProtocolStub`) is named differently in `CreateWorktreeClientTests.swift`, rename the calls to match the existing harness exactly. Do not introduce a new stub.

- [ ] **Step 3:** Run the tests — they should fail RED (`DeleteWorktreeClient` doesn't exist yet).

Run: `swift test --filter DeleteWorktreeClientTests`
Expected: compile error or all tests fail.

- [ ] **Step 4:** Create `Sources/GrafttyMobileKit/Session/DeleteWorktreeClient.swift`:

```swift
#if canImport(UIKit)
import Foundation

public enum DeleteWorktreeClient {

    public struct Request: Encodable, Sendable, Equatable {
        public let worktreePath: String
        public let force: Bool

        public init(worktreePath: String, force: Bool) {
            self.worktreePath = worktreePath
            self.force = force
        }
    }

    public struct Response: Decodable, Sendable, Equatable {
        public let dismissed: Bool

        public init(dismissed: Bool) {
            self.dismissed = dismissed
        }
    }

    public enum DeleteError: Error, Equatable {
        case invalid(String)
        case notFound
        /// 409 with `forceAllowed: true` — caller should present a
        /// Force Delete confirmation and retry with `force: true`.
        case gitFailedForceable(stderr: String, shortStatus: String)
        /// 409 with `forceAllowed: false` — non-retryable; surface
        /// `stderr` to the user as a terminal error.
        case gitFailedFinal(String)
        case serverInternal(String)
        case unavailable(String)
        case forbidden
        case http(Int)
        case decode
        case transport
    }

    public static func request(baseURL: URL, body: Request) throws -> URLRequest {
        guard let url = baseURL.appendingAPIPath("worktrees/delete") else {
            throw DeleteError.transport
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw DeleteError.transport
        }
        return req
    }

    private struct ConflictBody: Decodable {
        let error: String
        let forceAllowed: Bool
        let shortStatus: String?
    }

    private struct ErrorEnvelope: Decodable { let error: String? }

    public static func delete(
        baseURL: URL,
        body: Request,
        session: URLSession = .shared
    ) async throws -> Response {
        let req = try request(baseURL: baseURL, body: body)
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw DeleteError.transport }
            switch http.statusCode {
            case 200..<300:
                do {
                    return try JSONDecoder().decode(Response.self, from: data)
                } catch {
                    throw DeleteError.decode
                }
            case 400:
                throw DeleteError.invalid(decodeErrorMessage(data) ?? "invalid request")
            case 403:
                throw DeleteError.forbidden
            case 404:
                throw DeleteError.notFound
            case 409:
                guard let conflict = try? JSONDecoder().decode(ConflictBody.self, from: data) else {
                    throw DeleteError.gitFailedFinal(decodeErrorMessage(data) ?? "git worktree remove failed")
                }
                if conflict.forceAllowed {
                    throw DeleteError.gitFailedForceable(
                        stderr: conflict.error,
                        shortStatus: conflict.shortStatus ?? ""
                    )
                }
                throw DeleteError.gitFailedFinal(conflict.error)
            case 500:
                throw DeleteError.serverInternal(decodeErrorMessage(data) ?? "server error")
            case 503:
                throw DeleteError.unavailable(decodeErrorMessage(data) ?? "worktree deletion not available")
            default:
                throw DeleteError.http(http.statusCode)
            }
        } catch let e as DeleteError {
            throw e
        } catch {
            throw DeleteError.transport
        }
    }

    private static func decodeErrorMessage(_ data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error
    }
}

extension DeleteWorktreeClient.DeleteError {
    /// User-facing message for inline toasts. `gitFailedForceable`
    /// returns nil because callers render a Force Delete dialog instead
    /// of a flat toast.
    public var userMessage: String? {
        switch self {
        case .invalid(let m): return m
        case .gitFailedFinal(let m): return m
        case .serverInternal(let m): return m
        case .unavailable(let m): return m
        case .notFound: return "Worktree no longer exists."
        case .forbidden: return "Not authorized — is this device on your tailnet?"
        case .http(let code): return "HTTP \(code)"
        case .decode: return "The server sent a response this version can't read."
        case .transport: return "Couldn't reach the server."
        case .gitFailedForceable: return nil
        }
    }
}
#endif
```

- [ ] **Step 5:** Run the tests — should be GREEN.

Run: `swift test --filter DeleteWorktreeClientTests`
Expected: all tests pass.

- [ ] **Step 6:** Commit.

```bash
git add Sources/GrafttyMobileKit/Session/DeleteWorktreeClient.swift Tests/GrafttyMobileKitTests/Session/DeleteWorktreeClientTests.swift
git commit -m "mobile: add DeleteWorktreeClient with TDD coverage"
```

---

## Task 7: First-occurrence repo ordering — IOS-9.9

**Goal:** Replace `WorktreePickerView.grouped`'s alphabetic sort with a first-occurrence-preserving group. Extract to a pure static helper for testing.

**Files:**
- Create: `Sources/GrafttyMobileKit/UI/WorktreePickerGrouping.swift` — namespace with `grouped(_:)` static
- Create: `Tests/GrafttyMobileKitTests/UI/WorktreePickerGroupingTests.swift`
- Modify: `Tests/GrafttyTests/Specs/IosTodo.swift` — remove the `ios_9_9` Todo entry
- Modify: `Sources/GrafttyMobileKit/UI/WorktreePickerView.swift` — call into the new helper, drop the inline `grouped` private function

- [ ] **Step 1:** Create the test file:

```swift
#if canImport(UIKit)
import Testing
import Foundation
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("WorktreePickerGrouping")
struct WorktreePickerGroupingTests {

    private static func wt(_ repo: String, _ name: String) -> WorktreePanes {
        WorktreePanes(
            path: "/p/\(repo)/\(name)",
            displayName: name,
            repoDisplayName: repo,
            displayBranch: name,
            state: .running,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: nil
        )
    }

    @Test("""
    @spec IOS-9.9: While rendering grouped worktrees in `WorktreePickerView`, the application shall preserve the order of `repoDisplayName` first-occurrences in the `GET /worktrees/panes` response rather than sort the group keys alphabetically, so the mobile picker's repo order matches the user's Mac sidebar order.
    """)
    func preservesFirstOccurrenceOrderNotAlphabetical() {
        // Wire arrives in order zebra, alpha, mango — sidebar order.
        // Alphabetical sort would put alpha first; first-occurrence
        // keeps zebra first.
        let list = [
            Self.wt("zebra", "main"),
            Self.wt("alpha", "main"),
            Self.wt("zebra", "feat-x"),
            Self.wt("mango", "main"),
            Self.wt("alpha", "feat-y"),
        ]
        let groups = WorktreePickerGrouping.grouped(list)
        #expect(groups.map(\.0) == ["zebra", "alpha", "mango"])
        #expect(groups[0].1.map(\.displayName) == ["main", "feat-x"])
        #expect(groups[1].1.map(\.displayName) == ["main", "feat-y"])
        #expect(groups[2].1.map(\.displayName) == ["main"])
    }

    @Test func emptyListReturnsEmpty() {
        #expect(WorktreePickerGrouping.grouped([]).isEmpty)
    }
}
#endif
```

- [ ] **Step 2:** Delete the `ios_9_9` `.disabled` entry from `IosTodo.swift`.

- [ ] **Step 3:** Run the test — should fail RED (`WorktreePickerGrouping` doesn't exist yet).

Run: `swift test --filter WorktreePickerGroupingTests`
Expected: compile error.

- [ ] **Step 4:** Create `Sources/GrafttyMobileKit/UI/WorktreePickerGrouping.swift`:

```swift
#if canImport(UIKit)
import GrafttyProtocol

/// Pure grouping helper for `WorktreePickerView`. Extracted from the
/// SwiftUI body so the order-preservation contract (IOS-9.9) can be
/// unit-tested without instantiating any view.
public enum WorktreePickerGrouping {

    /// Group `list` by `repoDisplayName`, preserving each key's
    /// first-occurrence order. This matches the order
    /// `GET /worktrees/panes` ships entries in, which mirrors the Mac
    /// sidebar's `appState.repos` ordering — so the mobile picker
    /// looks "the same" as the desktop sidebar.
    public static func grouped(_ list: [WorktreePanes]) -> [(String, [WorktreePanes])] {
        var order: [String] = []
        var groups: [String: [WorktreePanes]] = [:]
        for wt in list {
            if groups[wt.repoDisplayName] == nil { order.append(wt.repoDisplayName) }
            groups[wt.repoDisplayName, default: []].append(wt)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}
#endif
```

- [ ] **Step 5:** Modify `WorktreePickerView.swift` — replace the existing private `grouped` function (lines 100–104) with a call to the helper. Update the `body` to use `WorktreePickerGrouping.grouped(worktrees)` instead of `self.grouped(worktrees)`.

Replace this block in `body`'s `.loaded` case:

```swift
                    ForEach(grouped(worktrees), id: \.0) { repoName, entries in
```

with:

```swift
                    ForEach(WorktreePickerGrouping.grouped(worktrees), id: \.0) { repoName, entries in
```

…and delete the entire `private func grouped(_ list:)` method (lines ~100–104). The helper is now the single source of truth.

- [ ] **Step 6:** Run the test — should be GREEN.

Run: `swift test --filter WorktreePickerGroupingTests`
Expected: pass.

- [ ] **Step 7:** Regenerate `SPECS.md`.

Run: `python3 scripts/generate-specs.py && python3 scripts/generate-specs.py --check`
Expected: both exit 0.

- [ ] **Step 8:** Commit.

```bash
git add Sources/GrafttyMobileKit/UI/WorktreePickerGrouping.swift Sources/GrafttyMobileKit/UI/WorktreePickerView.swift Tests/GrafttyMobileKitTests/UI/WorktreePickerGroupingTests.swift Tests/GrafttyTests/Specs/IosTodo.swift SPECS.md
git commit -m "mobile: preserve sidebar repo order in picker (IOS-9.9)"
```

---

## Task 8: Swipe action helper — IOS-9.6

**Goal:** Extract a pure `swipeAction(for:)` helper so the "no swipe on main checkout or .creating; Delete vs Dismiss based on .stale" rule is unit-tested before being wired into SwiftUI.

**Files:**
- Modify: `Sources/GrafttyMobileKit/UI/WorktreePickerGrouping.swift` — add `WorktreePickerSwipeAction` enum + helper
- Create: `Tests/GrafttyMobileKitTests/UI/WorktreePickerSwipeActionTests.swift`
- Modify: `Tests/GrafttyTests/Specs/IosTodo.swift` — remove `ios_9_6` Todo entry

- [ ] **Step 1:** Add to the bottom of `WorktreePickerGrouping.swift` (still inside the `#if canImport(UIKit)`):

```swift
/// Trailing destructive action surfaced on swipe. Nil for rows that
/// cannot be removed via the picker (main checkout, `.creating`).
public enum WorktreePickerSwipeAction: Equatable {
    case delete    // non-stale, non-main rows: runs `git worktree remove`
    case dismiss   // `.stale` rows: prunes the orphan admin entry

    public var buttonLabel: String {
        switch self {
        case .delete: return "Delete"
        case .dismiss: return "Dismiss"
        }
    }

    public var dialogTitle: String {
        switch self {
        case .delete: return "Delete Worktree?"
        case .dismiss: return "Dismiss Worktree?"
        }
    }

    public var dialogBody: String {
        switch self {
        case .delete: return "This will delete the worktree but not the branch."
        case .dismiss: return "This will remove this stale entry from Graftty."
        }
    }
}

extension WorktreePickerGrouping {
    /// IOS-9.6 rule: main checkout and `.creating` rows have no swipe
    /// affordance. `.stale` rows offer Dismiss; everything else offers
    /// Delete.
    public static func swipeAction(for wt: WorktreePanes) -> WorktreePickerSwipeAction? {
        if wt.isMainCheckout { return nil }
        if wt.state == .creating { return nil }
        if wt.state == .stale { return .dismiss }
        return .delete
    }
}
```

- [ ] **Step 2:** Create the test file:

```swift
#if canImport(UIKit)
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("@spec IOS-9.6: WorktreePickerSwipeAction state mapping")
struct WorktreePickerSwipeActionTests {

    private static func wt(
        _ state: WorktreeWireState,
        isMainCheckout: Bool = false
    ) -> WorktreePanes {
        WorktreePanes(
            path: "/p/wt",
            displayName: "wt",
            repoDisplayName: "repo",
            displayBranch: "wt",
            state: state,
            isMainCheckout: isMainCheckout,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: nil
        )
    }

    @Test func mainCheckoutHasNoSwipe() {
        #expect(WorktreePickerGrouping.swipeAction(for: Self.wt(.running, isMainCheckout: true)) == nil)
    }

    @Test func creatingRowHasNoSwipe() {
        #expect(WorktreePickerGrouping.swipeAction(for: Self.wt(.creating)) == nil)
    }

    @Test func staleRowOffersDismiss() {
        #expect(WorktreePickerGrouping.swipeAction(for: Self.wt(.stale)) == .dismiss)
    }

    @Test func runningRowOffersDelete() {
        #expect(WorktreePickerGrouping.swipeAction(for: Self.wt(.running)) == .delete)
    }

    @Test func closedRowOffersDelete() {
        #expect(WorktreePickerGrouping.swipeAction(for: Self.wt(.closed)) == .delete)
    }

    @Test func mainCheckoutOverridesStale() {
        // Main checkout with stale state (rare but defined): swipe
        // still disabled so we don't offer dismiss on a row whose
        // removal would have to take the "Remove Repository" path.
        #expect(WorktreePickerGrouping.swipeAction(for: Self.wt(.stale, isMainCheckout: true)) == nil)
    }
}
#endif
```

- [ ] **Step 3:** Delete the `ios_9_6` `.disabled` entry from `IosTodo.swift`.

- [ ] **Step 4:** Run.

Run: `swift test --filter WorktreePickerSwipeActionTests`
Expected: all tests pass.

- [ ] **Step 5:** Regenerate `SPECS.md`.

Run: `python3 scripts/generate-specs.py && python3 scripts/generate-specs.py --check`
Expected: both exit 0.

- [ ] **Step 6:** Commit.

```bash
git add Sources/GrafttyMobileKit/UI/WorktreePickerGrouping.swift Tests/GrafttyMobileKitTests/UI/WorktreePickerSwipeActionTests.swift Tests/GrafttyTests/Specs/IosTodo.swift SPECS.md
git commit -m "mobile: extract WorktreePickerSwipeAction helper (IOS-9.6)"
```

---

## Task 9: Wire `.swipeActions` + confirmation + force-delete dialog into `WorktreePickerView`

**Goal:** Add the full UI. Per `feedback_macos_swift_test_misses_uikit_guarded_code`, SwiftUI dialog wiring is not unit-testable from `swift test` on macOS; iOS-sim CI is the real check. We promote IOS-9.7 and IOS-9.8 as real `@Test`s containing the wire-decoding expectations that ARE unit-testable, and rely on the iOS sim for the dialog plumbing.

**Files:**
- Modify: `Sources/GrafttyMobileKit/UI/WorktreePickerView.swift` — add swipe actions, confirmation dialog, force-delete dialog, error toast state
- Modify: `Tests/GrafttyTests/Specs/IosTodo.swift` — remove `ios_9_7` and `ios_9_8` Todo entries
- Modify: `Tests/GrafttyMobileKitTests/UI/WorktreePickerSwipeActionTests.swift` — add `@spec IOS-9.7` and `@spec IOS-9.8` annotated tests covering the wire-decoding portions (already partially covered in `DeleteWorktreeClientTests`)

- [ ] **Step 1:** Delete the `ios_9_7` and `ios_9_8` `.disabled` entries from `IosTodo.swift`.

- [ ] **Step 2:** Add two real-test `@Test` declarations to `WorktreePickerSwipeActionTests.swift` so the spec text is captured at the right granularity (these reference dialog-decoder helpers we'll add to `WorktreePickerGrouping`):

```swift
    @Test("""
    @spec IOS-9.7: When the user taps the trailing destructive action revealed by `IOS-9.6`, the application shall present a SwiftUI confirmation dialog before any HTTP call. The dialog title shall be "Delete Worktree?" for non-stale rows and "Dismiss Worktree?" for `.stale` rows; the dialog body shall mirror the Mac's NSAlert copy ("This will delete the worktree but not the branch." / "This will remove this stale entry from Graftty."). On cancel, no request shall be issued.
    """)
    func dialogCopyMatchesMacAlert() {
        #expect(WorktreePickerSwipeAction.delete.dialogTitle == "Delete Worktree?")
        #expect(WorktreePickerSwipeAction.delete.dialogBody == "This will delete the worktree but not the branch.")
        #expect(WorktreePickerSwipeAction.dismiss.dialogTitle == "Dismiss Worktree?")
        #expect(WorktreePickerSwipeAction.dismiss.dialogBody == "This will remove this stale entry from Graftty.")
    }

    @Test("""
    @spec IOS-9.8: If `POST /worktrees/delete` returns 409 with `forceAllowed: true`, then the application shall present a Force Delete confirmation surfacing the `shortStatus` field as the dialog body, and shall retry the request with `force: true` only on user confirmation. A 409 with `forceAllowed: false` (or 4xx/5xx of any other shape) shall present a non-retryable error toast and shall not loop.
    """)
    func forceableErrorIsDistinctFromFinalError() {
        // The DeleteWorktreeClient already decodes these branches into
        // .gitFailedForceable vs .gitFailedFinal — those decodings are
        // covered in DeleteWorktreeClientTests. This test asserts the
        // userMessage contract that drives the toast vs dialog choice
        // in WorktreePickerView: forceable returns nil (caller renders
        // a dialog), final returns a string (caller renders a toast).
        let forceable = DeleteWorktreeClient.DeleteError.gitFailedForceable(
            stderr: "err", shortStatus: "M foo"
        )
        let final = DeleteWorktreeClient.DeleteError.gitFailedFinal("main checkout")
        #expect(forceable.userMessage == nil)
        #expect(final.userMessage == "main checkout")
    }
```

- [ ] **Step 3:** Modify `WorktreePickerView.swift`. Update `LoadState` to carry a transient error message, add swipe + dialog state, and add the dialog views. Replace the existing `public struct WorktreePickerView` body wholesale with the version below (the changes are: new `@State` for the pending delete + force-delete + error toast; new `.swipeActions` per row; two `.confirmationDialog` modifiers; an overlay toast):

Apply these edits in order:

  (a) Add the new `@State` declarations near the top of `WorktreePickerView` (just after `isAddSheetPresented`):

```swift
    @State private var pendingDelete: PendingDelete?
    @State private var pendingForceDelete: PendingForceDelete?
    @State private var errorToast: String?
    @State private var errorToastTask: Task<Void, Never>?

    private struct PendingDelete: Identifiable, Equatable {
        let id = UUID()
        let worktree: WorktreePanes
        let action: WorktreePickerSwipeAction
    }

    private struct PendingForceDelete: Identifiable, Equatable {
        let id = UUID()
        let worktreePath: String
        let displayName: String
        let stderr: String
        let shortStatus: String
    }
```

  (b) Replace the row rendering inside `.loaded(let worktrees)` so each `WorktreeBlock` gains `.swipeActions`. Find the existing `ForEach(entries, id: \.path) { wt in ... }` and replace with:

```swift
                            ForEach(entries, id: \.path) { wt in
                                WorktreeBlock(worktree: wt) {
                                    onSelect(wt)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if let action = WorktreePickerGrouping.swipeAction(for: wt) {
                                        Button(role: .destructive) {
                                            pendingDelete = PendingDelete(worktree: wt, action: action)
                                        } label: {
                                            Label(action.buttonLabel, systemImage: action == .dismiss ? "eye.slash" : "trash")
                                        }
                                    }
                                }
                            }
```

  (c) Add the two `.confirmationDialog` modifiers and the error-toast overlay onto the outer `Group { switch state { ... } }` (immediately before `.navigationTitle(host.label)`):

```swift
        .confirmationDialog(
            pendingDelete?.action.dialogTitle ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { pending in
            Button(pending.action.buttonLabel, role: .destructive) {
                Task { await performDelete(worktree: pending.worktree, force: false) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { pending in
            Text(pending.action.dialogBody)
        }
        .confirmationDialog(
            "Could not delete worktree",
            isPresented: Binding(
                get: { pendingForceDelete != nil },
                set: { if !$0 { pendingForceDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingForceDelete
        ) { pending in
            Button("Force Delete", role: .destructive) {
                Task {
                    await performDelete(
                        worktree: WorktreePanes(
                            path: pending.worktreePath,
                            displayName: pending.displayName,
                            repoDisplayName: "",
                            displayBranch: "",
                            state: .running,
                            isMainCheckout: false,
                            prBadge: nil,
                            stats: nil,
                            attentionText: nil,
                            layout: nil
                        ),
                        force: true
                    )
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { pending in
            Text(pending.stderr + (pending.shortStatus.isEmpty ? "" : "\n\n" + pending.shortStatus))
        }
        .overlay(alignment: .bottom) {
            if let msg = errorToast {
                Text(msg)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
```

  (d) Add the `performDelete` and `showErrorToast` methods inside `WorktreePickerView`, below `handleCreated`:

```swift
    private func performDelete(worktree: WorktreePanes, force: Bool) async {
        do {
            _ = try await DeleteWorktreeClient.delete(
                baseURL: host.baseURL,
                body: DeleteWorktreeClient.Request(worktreePath: worktree.path, force: force)
            )
            await refresh()
        } catch let DeleteWorktreeClient.DeleteError.gitFailedForceable(stderr, status) {
            pendingForceDelete = PendingForceDelete(
                worktreePath: worktree.path,
                displayName: worktree.displayName,
                stderr: stderr,
                shortStatus: status
            )
        } catch let error as DeleteWorktreeClient.DeleteError {
            if let msg = error.userMessage {
                showErrorToast(msg)
            }
            await refresh()
        } catch {
            showErrorToast("Couldn't reach the server.")
        }
    }

    private func showErrorToast(_ message: String) {
        errorToastTask?.cancel()
        withAnimation { errorToast = message }
        errorToastTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    withAnimation { errorToast = nil }
                }
            }
        }
    }
```

- [ ] **Step 4:** Build for macOS (Swift Testing tests still run here):

Run: `swift build`
Expected: clean.

- [ ] **Step 5:** Run the targeted tests.

Run: `swift test --filter WorktreePickerSwipeActionTests`
Expected: all pass.

- [ ] **Step 6:** Regenerate `SPECS.md`.

Run: `python3 scripts/generate-specs.py && python3 scripts/generate-specs.py --check`
Expected: both exit 0.

- [ ] **Step 7:** Commit.

```bash
git add Sources/GrafttyMobileKit/UI/WorktreePickerView.swift Tests/GrafttyMobileKitTests/UI/WorktreePickerSwipeActionTests.swift Tests/GrafttyTests/Specs/IosTodo.swift SPECS.md
git commit -m "mobile: swipe-to-delete + force-delete dialog in WorktreePickerView (IOS-9.6/9.7/9.8)"
```

---

## Task 10: Whole-suite verification + `/simplify`

**Goal:** Run the full suite, fix any incidental regressions from the refactor, and run the project's required `/simplify` step before opening the PR.

- [ ] **Step 1:** Full Swift build + test on macOS.

Run: `swift build && swift test`
Expected: clean. Any pre-existing flakes documented in code comments (see `WebServerWorktreeEndpointTests` header) remain unchanged.

- [ ] **Step 2:** `SPECS.md` integrity check.

Run: `python3 scripts/generate-specs.py --check`
Expected: exits 0.

- [ ] **Step 3:** Run `/simplify` per `CLAUDE.md`'s "Always run /simplify before opening a PR" rule. Apply any suggested cleanups; commit the cleanups as their own commit titled `simplify: address /simplify findings`.

- [ ] **Step 4:** Final whole-suite sanity check after `/simplify`.

Run: `swift build && swift test`
Expected: clean.

---

## Task 11: Open the PR

**Goal:** Push the branch and open the PR. Confirm CI (including the iOS sim job) goes green.

- [ ] **Step 1:** Push the branch.

```bash
git push -u origin allow-deleting-worktrees-in-ios
```

- [ ] **Step 2:** Open PR via `gh pr create`. Body must mention the seven new spec IDs and the Mac-side refactor.

```bash
gh pr create --title "ios: swipe to delete/dismiss worktrees + sidebar-order grouping" --body "$(cat <<'EOF'
## Summary
- GrafttyMobile's `WorktreePickerView` gains swipe-to-delete (Delete / Dismiss based on row state) with a confirmation dialog matching the Mac's NSAlert copy, plus a Force Delete dialog on `--force`-able git failures.
- Mobile repo groups now follow the user's Mac sidebar order (first-occurrence) instead of being sorted alphabetically.
- Mac-side `MainWindow.performDeleteWorktree` body extracted into `DeleteWorktreeFlow.delete`; the Mac NSAlert path and the new `POST /worktrees/delete` HTTP endpoint share one funnel.

## Specs added
- **IOS-9.6** — swipe reveals Delete/Dismiss (gated on main checkout + `.creating`).
- **IOS-9.7** — confirmation dialog before HTTP call.
- **IOS-9.8** — Force Delete dialog on 409 `forceAllowed: true`.
- **IOS-9.9** — first-occurrence repo ordering.
- **WEB-7.8** — `POST /worktrees/delete` success contract.
- **WEB-7.9** — 409 forceable/final shapes.
- **WEB-7.10** — 503 when remover not injected.

## Test plan
- [x] `swift test --filter WebServerDeleteEndpointTests` (status-code branches)
- [x] `swift test --filter DeleteWorktreeClientTests` (wire decoding)
- [x] `swift test --filter WorktreePickerGroupingTests` (IOS-9.9 ordering)
- [x] `swift test --filter WorktreePickerSwipeActionTests` (IOS-9.6 + 9.7 + 9.8 helpers)
- [ ] iOS sim CI confirms swipe gesture + confirmation dialog wiring end-to-end (per `feedback_macos_swift_test_misses_uikit_guarded_code`, this is the authoritative check).
- [ ] Manual mac path: Delete Worktree from sidebar still works; Force Delete dialog still fires on a dirty worktree.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3:** Capture the PR URL.

- [ ] **Step 4:** Watch CI. The `verify-specs` job is the one that catches spec/test drift; the iOS-sim job is the one that catches SwiftUI dialog regressions per the memory note.

```bash
gh pr checks --watch
```

Expected: all checks green, or any failure is unrelated to this PR (re-check head-commit `ci.yml` against the release-cuttability rule in `CLAUDE.md`).

- [ ] **Step 5:** Report the PR URL back to the user.

---

## Self-review

Walked the spec against the plan:

1. **Spec coverage:**
   - IOS-9.6 → Task 8 + 9
   - IOS-9.7 → Task 9 (dialog copy in `WorktreePickerSwipeAction`)
   - IOS-9.8 → Task 6 (wire) + Task 9 (UI)
   - IOS-9.9 → Task 7
   - WEB-7.8 → Task 2 (types) + Task 3 (handler) + Task 5 (wiring)
   - WEB-7.9 → Task 3 (status + body) + Task 4 (flow returns forceable/final)
   - WEB-7.10 → Task 3
   - `DeleteWorktreeFlow` extraction → Task 4
   - All seven specs covered.

2. **Placeholder scan:** every step has either a verbatim code block or a verbatim shell command. No "TBD", "TODO", or "implement appropriate handling" stubs.

3. **Type consistency:**
   - `DeleteWorktreeRequest { worktreePath, force }` — same shape in Task 2 (server), Task 6 (client), Task 9 (UI).
   - `DeleteWorktreeOutcome` cases `.success` / `.invalid` / `.notFound` / `.gitFailedForceable` / `.gitFailedFinal` / `.internalFailure` — same in Task 2 (definition), Task 3 (handler match), Task 4 (`FlowError`→outcome bridging), Task 5 (wiring).
   - `DeleteError` client-side cases match: `.invalid` / `.notFound` / `.gitFailedForceable(stderr, shortStatus)` / `.gitFailedFinal(String)` / `.serverInternal` / `.unavailable` / `.forbidden` / `.http` / `.decode` / `.transport`.
   - `WorktreePickerSwipeAction.delete` / `.dismiss` — referenced consistently in Tasks 8 and 9.

4. **Scope:** still focused — no scope creep into "Remove Repository", web client parity, or multi-select.

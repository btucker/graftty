# Worktree URL Handler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `graftty://open?...` URL handler so a link selects a particular worktree (and optionally focuses a pane) in the macOS app; ship the shared parser + resolvers (incl. the iOS-snapshot resolver) and the Mac `.onOpenURL` wiring, registering the scheme in both apps' Info.plist.

**Architecture:** A pure parser (`GrafttyDeepLink.parse`) and a pure iOS-snapshot resolver live in `GrafttyProtocol` (the only module both apps share). A pure Mac resolver over `[RepoEntry]` lives in `GrafttyKit`. The macOS `WindowGroup` gains a thin `.onOpenURL` that parses → resolves → mutates `AppState`. iOS `.onOpenURL` wiring is a deferred follow-up (UIKit-guarded, not locally verifiable); its resolver still ships and is tested now.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing (`@Test`), SwiftUI (`.onOpenURL`), AppKit (`NSApp.activate`). Specs follow the project `@spec`/EARS convention; `scripts/generate-specs.py` regenerates `SPECS.md`.

**Spec prefix:** `URL` (verified unused). Register in `scripts/spec-sections.json`.

---

## File Structure

**Create:**
- `Sources/GrafttyProtocol/DeepLink/GrafttyDeepLink.swift` — `DeepLinkTarget`, `DeepLinkNotFoundReason`, `SnapshotDeepLinkOutcome`, `parse(_:)`, `resolve(_:inSnapshot:)`.
- `Sources/GrafttyKit/DeepLink/DeepLinkResolver.swift` — `MacDeepLinkOutcome`, `DeepLinkResolver.resolve(_:inRepos:)`.
- `Tests/GrafttyProtocolTests/GrafttyDeepLinkTests.swift` — parser + snapshot-resolver specs.
- `Tests/GrafttyKitTests/DeepLinkResolverTests.swift` — Mac resolver specs.
- `Tests/GrafttyTests/Specs/UrlTodo.swift` — disabled inventory for the deferred iOS wiring spec.

**Modify:**
- `scripts/spec-sections.json` — add `URL` to `section_order` + `sections`.
- `scripts/bundle.sh` — add `CFBundleURLTypes` (scheme `graftty`) to the macOS Info.plist heredoc.
- `Apps/GrafttyMobile/GrafttyMobile/Info.plist` — add `CFBundleURLTypes` (scheme `graftty`).
- `Sources/Graftty/GrafttyApp.swift` — add `.onOpenURL` to the `WindowGroup` content + a private `handleDeepLink` helper.
- `SPECS.md` — regenerated (do not hand-edit).

**Note on `Tests/GrafttyTests`:** that test target builds the `Graftty` (macOS app) target. `UrlTodo.swift` is inventory-only (`.disabled`), so it compiles but does not run. If the `GrafttyTests` target does not already exist / is not the right home for a `Specs/` inventory file, place `UrlTodo.swift` next to the other `*Todo.swift` files — find them first with `git ls-files '*Todo.swift'` and match that location/target.

---

## Task 1: Spec prefix registration

**Files:**
- Modify: `scripts/spec-sections.json`

- [ ] **Step 1: Locate the insertion points**

Run: `grep -n '"REMOTE"' scripts/spec-sections.json`
Expected: two hits — one in the `section_order` array, one key in the `sections` object.

- [ ] **Step 2: Add `URL` to `section_order`**

In the `section_order` array, add `"URL"` as the last element (after `"REMOTE"`). Example resulting tail:

```json
    "EDITOR",
    "REMOTE",
    "URL"
  ],
```

- [ ] **Step 3: Add `URL` to `sections`**

In the `sections` object, add after the `"REMOTE"` entry:

```json
    "REMOTE": "Secure Remote Access",
    "URL": "Worktree URL Handler"
```

- [ ] **Step 4: Verify JSON still parses**

Run: `python3 -c "import json; json.load(open('scripts/spec-sections.json'))" && echo OK`
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add scripts/spec-sections.json
git commit -m "feat(URL): register URL spec section (Worktree URL Handler)"
```

---

## Task 2: Parser + shared types (`GrafttyProtocol`)

**Files:**
- Create: `Sources/GrafttyProtocol/DeepLink/GrafttyDeepLink.swift`
- Test: `Tests/GrafttyProtocolTests/GrafttyDeepLinkTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/GrafttyProtocolTests/GrafttyDeepLinkTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GrafttyDeepLinkParseTests`
Expected: FAIL — `GrafttyDeepLink` is undefined.

- [ ] **Step 3: Write the implementation**

Create `Sources/GrafttyProtocol/DeepLink/GrafttyDeepLink.swift`:

```swift
import Foundation

/// @spec URL-1.0
/// A deep-link target parsed from a `graftty://open` URL: either a
/// specific pane session (which implies its worktree and pane) or a
/// repo+worktree pair (worktree-level, pane-agnostic).
public enum DeepLinkTarget: Equatable, Sendable {
    /// A zmx session name, e.g. `"graftty-ab12cd34"`.
    case session(String)
    /// `repo` matches a repo display name; `worktree` is the sanitized
    /// worktree address (same form as `graftty team msg` / `pane`).
    case worktree(repo: String, worktree: String)
}

/// @spec URL-1.0
/// Why a deep-link resolution failed.
public enum DeepLinkNotFoundReason: Equatable, Sendable {
    case unknownSession
    case unknownRepo
    case unknownWorktree
}

/// Parses and resolves `graftty://` deep links. Pure and dependency-free
/// beyond `GrafttyProtocol` so both the macOS app and the iOS app can
/// share it (`GrafttyMobileKit` depends on `GrafttyProtocol`, not
/// `GrafttyKit`).
public enum GrafttyDeepLink {

    /// Parse a URL into a `DeepLinkTarget`. Returns `nil` for any URL
    /// that is not `graftty://open` with usable params. When both a
    /// `session` and a `repo`+`worktree` pair are present, the session
    /// wins.
    public static func parse(_ url: URL) -> DeepLinkTarget? {
        guard url.scheme == "graftty" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard components.host == "open" else { return nil }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            guard let raw = items.first(where: { $0.name == name })?.value, !raw.isEmpty else { return nil }
            return raw
        }

        if let session = value("session") {
            return .session(session)
        }
        if let repo = value("repo"), let worktree = value("worktree") {
            return .worktree(repo: repo, worktree: WorktreeNameSanitizer.sanitize(worktree))
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GrafttyDeepLinkParseTests`
Expected: PASS (all parse cases).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyProtocol/DeepLink/GrafttyDeepLink.swift Tests/GrafttyProtocolTests/GrafttyDeepLinkTests.swift
git commit -m "feat(URL-1.1): parse graftty://open deep links (session + repo/worktree)"
```

---

## Task 3: iOS snapshot resolver (`GrafttyProtocol`)

**Files:**
- Modify: `Sources/GrafttyProtocol/DeepLink/GrafttyDeepLink.swift`
- Test: `Tests/GrafttyProtocolTests/GrafttyDeepLinkTests.swift`

**Context — `WorktreePanes` shape (read first):** `grep -n "public let\|public var\|case leaf\|case split\|var leaves\|sessionName\|displayBranch\|repoDisplayName" Sources/GrafttyProtocol/WorktreePanes.swift`. You need: `WorktreePanes.path`, `.repoDisplayName`, `.displayBranch`, and a way to enumerate pane leaves carrying `sessionName` (the `.leaf(sessionName:title:attentionText:)` node, reachable via the worktree's `layout`). Use the exact property/accessor names you find — adjust the snippet below to match (e.g. the leaf-collection accessor may be `layout?.leaves`, as used in `IPadRootLayout.swift`).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/GrafttyProtocolTests/GrafttyDeepLinkTests.swift`:

```swift
@Suite("@spec URL-1.2: Given a worktree-panes snapshot, the application shall resolve a deep-link target to a worktree path (and, for a session target, the matching pane session name), or report which part was unknown.")
struct GrafttyDeepLinkSnapshotResolveTests {

    // Build the smallest WorktreePanes fixtures the resolver needs.
    // Replace `makeSnapshot(...)` with constructors matching the actual
    // WorktreePanes / layout initializers discovered in the Context step.
    private func snapshot() -> [WorktreePanes] {
        // Two worktrees in repo "graftty": "url-handler" (sessions
        // graftty-aaaa1111, graftty-bbbb2222) and "main" (graftty-cccc3333).
        // NOTE: construct via the real initializers; see Context above.
        return WorktreePanesFixture.twoWorktreeGrafttyRepo()
    }

    @Test("session resolves to its worktree + session name")
    func sessionResolves() {
        let out = GrafttyDeepLink.resolve(.session("graftty-bbbb2222"), inSnapshot: snapshot())
        #expect(out == .resolved(worktreePath: "/wt/url-handler", sessionName: "graftty-bbbb2222"))
    }

    @Test("worktree form resolves to path with nil session")
    func worktreeResolves() {
        let out = GrafttyDeepLink.resolve(.worktree(repo: "graftty", worktree: "url-handler"), inSnapshot: snapshot())
        #expect(out == .resolved(worktreePath: "/wt/url-handler", sessionName: nil))
    }

    @Test("unknown session reported")
    func unknownSession() {
        let out = GrafttyDeepLink.resolve(.session("graftty-zzzz9999"), inSnapshot: snapshot())
        #expect(out == .notFound(.unknownSession))
    }

    @Test("unknown repo reported")
    func unknownRepo() {
        let out = GrafttyDeepLink.resolve(.worktree(repo: "nope", worktree: "url-handler"), inSnapshot: snapshot())
        #expect(out == .notFound(.unknownRepo))
    }

    @Test("known repo, unknown worktree reported")
    func unknownWorktree() {
        let out = GrafttyDeepLink.resolve(.worktree(repo: "graftty", worktree: "nope"), inSnapshot: snapshot())
        #expect(out == .notFound(.unknownWorktree))
    }
}
```

If `WorktreePanes` has no convenient test initializer, add a small fixture helper in the test file (a private `enum WorktreePanesFixture`) that builds the structs via their real initializers — do **not** add production-only constructors.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GrafttyDeepLinkSnapshotResolveTests`
Expected: FAIL — `resolve(_:inSnapshot:)` and/or `SnapshotDeepLinkOutcome` undefined.

- [ ] **Step 3: Write the implementation**

Append to `Sources/GrafttyProtocol/DeepLink/GrafttyDeepLink.swift`:

```swift
/// @spec URL-1.2
/// Result of resolving a deep link against an iOS worktree-panes
/// snapshot. The focus key on iOS is the pane `sessionName` string
/// (see `IPadAppState.focusedPaneId`).
public enum SnapshotDeepLinkOutcome: Equatable, Sendable {
    case resolved(worktreePath: String, sessionName: String?)
    case notFound(DeepLinkNotFoundReason)
}

extension GrafttyDeepLink {

    /// Resolve a target against an iOS `[WorktreePanes]` snapshot.
    public static func resolve(
        _ target: DeepLinkTarget,
        inSnapshot worktrees: [WorktreePanes]
    ) -> SnapshotDeepLinkOutcome {
        switch target {
        case .session(let name):
            for wt in worktrees where sessionNames(of: wt).contains(name) {
                return .resolved(worktreePath: wt.path, sessionName: name)
            }
            return .notFound(.unknownSession)

        case .worktree(let repo, let worktree):
            let inRepo = worktrees.filter { $0.repoDisplayName == repo }
            guard !inRepo.isEmpty else { return .notFound(.unknownRepo) }
            guard let match = inRepo.first(where: {
                WorktreeNameSanitizer.sanitize($0.displayBranch) == worktree
            }) else {
                return .notFound(.unknownWorktree)
            }
            return .resolved(worktreePath: match.path, sessionName: nil)
        }
    }

    /// All pane session names in a worktree snapshot. Adjust the leaf
    /// traversal to the real `WorktreePanes` layout accessor discovered
    /// in the Context step (e.g. `wt.layout?.leaves.map(\.sessionName)`).
    private static func sessionNames(of wt: WorktreePanes) -> [String] {
        wt.layout?.leaves.map(\.sessionName) ?? []
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GrafttyDeepLinkSnapshotResolveTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyProtocol/DeepLink/GrafttyDeepLink.swift Tests/GrafttyProtocolTests/GrafttyDeepLinkTests.swift
git commit -m "feat(URL-1.2): resolve deep links against an iOS worktree-panes snapshot"
```

---

## Task 4: Mac resolver (`GrafttyKit`)

**Files:**
- Create: `Sources/GrafttyKit/DeepLink/DeepLinkResolver.swift`
- Test: `Tests/GrafttyKitTests/DeepLinkResolverTests.swift`

**Context — read first:**
- `RepoEntry`: `grep -n "public" Sources/GrafttyKit/Model/RepoEntry.swift` — confirm `displayName`, `worktrees`, and its initializer signature.
- `WorktreeEntry`: confirm `path`, `branch`, `paneSessions: [PaneSlotID: PaneSessionID]`, and how to construct one in a test (look at an existing `GrafttyKitTests` that builds a `WorktreeEntry`).
- `ZmxLauncher.sessionName(for: PaneSessionID)` returns `"graftty-" + first-8-hex-lowercase` of the UUID. Use it to compute a session's name.

- [ ] **Step 1: Write the failing tests**

Create `Tests/GrafttyKitTests/DeepLinkResolverTests.swift`:

```swift
import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("@spec URL-1.3: Given the tracked repos, the application shall resolve a deep-link target to a worktree path (and, for a session target, the owning pane slot), or report which part was unknown.")
struct DeepLinkResolverTests {

    // A session whose name we can predict via ZmxLauncher.sessionName.
    private let slot = PaneSlotID()
    private let session = PaneSessionID()

    private func repos() -> [RepoEntry] {
        var wt = WorktreeEntry(/* fill per real initializer: path "/wt/url-handler", branch "url-handler" */)
        wt.recordPaneSession(session, for: slot)
        // Build a second worktree "/wt/main" branch "main" with no sessions.
        // Wrap both in a RepoEntry with displayName "graftty".
        return [ /* RepoEntry(displayName: "graftty", worktrees: [wt, main]) */ ]
    }

    @Test("session resolves to worktree + owning pane slot")
    func sessionResolves() {
        let name = ZmxLauncher.sessionName(for: session)
        let out = DeepLinkResolver.resolve(.session(name), inRepos: repos())
        #expect(out == .resolved(worktreePath: "/wt/url-handler", paneSlot: slot))
    }

    @Test("worktree form resolves to path with nil pane slot")
    func worktreeResolves() {
        let out = DeepLinkResolver.resolve(.worktree(repo: "graftty", worktree: "url-handler"), inRepos: repos())
        #expect(out == .resolved(worktreePath: "/wt/url-handler", paneSlot: nil))
    }

    @Test("unknown session reported")
    func unknownSession() {
        let out = DeepLinkResolver.resolve(.session("graftty-zzzz9999"), inRepos: repos())
        #expect(out == .notFound(.unknownSession))
    }

    @Test("unknown repo reported")
    func unknownRepo() {
        let out = DeepLinkResolver.resolve(.worktree(repo: "nope", worktree: "url-handler"), inRepos: repos())
        #expect(out == .notFound(.unknownRepo))
    }

    @Test("known repo, unknown worktree reported")
    func unknownWorktree() {
        let out = DeepLinkResolver.resolve(.worktree(repo: "graftty", worktree: "nope"), inRepos: repos())
        #expect(out == .notFound(.unknownWorktree))
    }
}
```

Fill the `repos()` fixture using the real `WorktreeEntry` / `RepoEntry` initializers found in the Context step. Mirror how an existing `GrafttyKitTests` file constructs these (search: `grep -rln "WorktreeEntry(" Tests/GrafttyKitTests`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DeepLinkResolverTests`
Expected: FAIL — `DeepLinkResolver` / `MacDeepLinkOutcome` undefined.

- [ ] **Step 3: Write the implementation**

Create `Sources/GrafttyKit/DeepLink/DeepLinkResolver.swift`:

```swift
import Foundation
import GrafttyProtocol

/// @spec URL-1.3
/// Result of resolving a deep link against the macOS app's tracked
/// repos. The focus key on macOS is the `PaneSlotID`
/// (`WorktreeEntry.focusedPaneSlotID`).
public enum MacDeepLinkOutcome: Equatable, Sendable {
    case resolved(worktreePath: String, paneSlot: PaneSlotID?)
    case notFound(DeepLinkNotFoundReason)
}

/// Pure resolution of a `DeepLinkTarget` against `[RepoEntry]`.
public enum DeepLinkResolver {

    public static func resolve(
        _ target: DeepLinkTarget,
        inRepos repos: [RepoEntry]
    ) -> MacDeepLinkOutcome {
        switch target {
        case .session(let name):
            for repo in repos {
                for wt in repo.worktrees {
                    if let slot = wt.paneSessions.first(where: {
                        ZmxLauncher.sessionName(for: $0.value) == name
                    })?.key {
                        return .resolved(worktreePath: wt.path, paneSlot: slot)
                    }
                }
            }
            return .notFound(.unknownSession)

        case .worktree(let repoName, let worktreeName):
            guard let repo = repos.first(where: { $0.displayName == repoName }) else {
                return .notFound(.unknownRepo)
            }
            guard let wt = repo.worktrees.first(where: {
                WorktreeNameSanitizer.sanitize($0.branch) == worktreeName
            }) else {
                return .notFound(.unknownWorktree)
            }
            return .resolved(worktreePath: wt.path, paneSlot: nil)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DeepLinkResolverTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/DeepLink/DeepLinkResolver.swift Tests/GrafttyKitTests/DeepLinkResolverTests.swift
git commit -m "feat(URL-1.3): resolve deep links against tracked repos (macOS)"
```

---

## Task 5: macOS `.onOpenURL` wiring (`Graftty`)

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`

**Context — read first:** `sed -n '363,405p' Sources/Graftty/GrafttyApp.swift` to see the `WindowGroup { MainWindow(...) ... }` content and the existing modifiers (`.onAppear`, `.onChange`). You will add `.onOpenURL` alongside them. Confirm `appState` is the `@State`/binding in scope (it is — used as `$appState`). Confirm pane focus is `repos[i].worktrees[j].focusedPaneSlotID` and selection is `appState.selectedWorktreePath` (both used elsewhere in this file).

This file is large; keep the addition tight and self-contained. There is no `swift test` coverage for SwiftUI scene wiring — the safety net is that the resolver it calls is fully tested (Tasks 3–4), so `handleDeepLink` is a thin, obviously-correct mutation. Verify by building.

- [ ] **Step 1: Add the `.onOpenURL` modifier**

In the `WindowGroup` content, add after the existing `.onChange(of: appState)` modifier block:

```swift
                .onOpenURL { url in
                    handleDeepLink(url)
                }
```

- [ ] **Step 2: Add the handler helper**

Add this method to the same `App` struct (near the other `private` helpers in the scene, e.g. next to `startup()`):

```swift
    /// @spec URL-2.1: When the macOS app opens a `graftty://open` URL
    /// that resolves to a tracked worktree, the application shall select
    /// that worktree, focus the resolved pane when one is present and the
    /// worktree is running, and bring the app to the foreground.
    private func handleDeepLink(_ url: URL) {
        guard let target = GrafttyDeepLink.parse(url) else { return }
        guard case let .resolved(path, paneSlot) = DeepLinkResolver.resolve(target, inRepos: appState.repos) else {
            return
        }
        appState.selectedWorktreePath = path
        if let paneSlot {
            for repoIdx in appState.repos.indices {
                for wtIdx in appState.repos[repoIdx].worktrees.indices
                where appState.repos[repoIdx].worktrees[wtIdx].path == path {
                    let wt = appState.repos[repoIdx].worktrees[wtIdx]
                    if wt.state == .running, wt.paneSessions[paneSlot] != nil {
                        appState.repos[repoIdx].worktrees[wtIdx].focusedPaneSlotID = paneSlot
                    }
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
```

If `appState` is a `Binding`/wrapper rather than directly mutable here, match the mutation style already used in this file (e.g. `appState.wrappedValue.repos[...]` as seen around line 2426). Read the surrounding code and follow the exact pattern.

- [ ] **Step 3: Confirm the import is present**

`grep -n "^import GrafttyKit\|^import GrafttyProtocol" Sources/Graftty/GrafttyApp.swift` — both should already be imported (they are used throughout). `DeepLinkResolver`/`MacDeepLinkOutcome` are in `GrafttyKit`; `GrafttyDeepLink`/`DeepLinkTarget` in `GrafttyProtocol`. No new import expected.

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build 2>&1 | tail -20`
Expected: build succeeds (no errors referencing `handleDeepLink`, `GrafttyDeepLink`, or `DeepLinkResolver`).

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift
git commit -m "feat(URL-2.1): handle graftty://open URLs in the macOS app"
```

---

## Task 6: Register the scheme in both Info.plists

**Files:**
- Modify: `scripts/bundle.sh`
- Modify: `Apps/GrafttyMobile/GrafttyMobile/Info.plist`

**Context:** macOS `Info.plist` is generated by a heredoc in `scripts/bundle.sh` (around the `<key>NSPrincipalClass</key>` block). The iOS one is a static file. Both register a single custom scheme `graftty`.

- [ ] **Step 1: Add `CFBundleURLTypes` to `scripts/bundle.sh`**

In the heredoc dict (e.g. immediately before the `<key>NSPrincipalClass</key>` line), insert:

```xml
    <key>CFBundleURLTypes</key>
    <array>
      <dict>
        <key>CFBundleURLName</key>
        <string>com.graftty.app.worktree</string>
        <key>CFBundleURLSchemes</key>
        <array>
          <string>graftty</string>
        </array>
      </dict>
    </array>
```

Caution: the heredoc is **unquoted** (`$` expands). The block above has no `$` or backticks, so it is safe to paste literally.

- [ ] **Step 2: Verify the heredoc still looks well-formed**

Run: `sed -n '130,185p' scripts/bundle.sh`
Expected: the new `CFBundleURLTypes` array sits inside the top-level `<dict>`, before `</dict></plist>`.

- [ ] **Step 3: Add `CFBundleURLTypes` to the iOS Info.plist**

`cat Apps/GrafttyMobile/GrafttyMobile/Info.plist` to see the root `<dict>`. Add the same `CFBundleURLTypes` array inside that root dict (use `CFBundleURLName` `com.graftty.mobile.worktree`):

```xml
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>com.graftty.mobile.worktree</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>graftty</string>
			</array>
		</dict>
	</array>
```

Match the file's existing indentation (tabs vs spaces).

- [ ] **Step 4: Verify the iOS plist parses**

Run: `plutil -lint Apps/GrafttyMobile/GrafttyMobile/Info.plist`
Expected: `... OK`

- [ ] **Step 5: Commit**

```bash
git add scripts/bundle.sh Apps/GrafttyMobile/GrafttyMobile/Info.plist
git commit -m "feat(URL): register graftty:// URL scheme in macOS and iOS Info.plist"
```

---

## Task 7: Backlog inventory for deferred iOS wiring

**Files:**
- Create: `Tests/GrafttyTests/Specs/UrlTodo.swift` (or wherever other `*Todo.swift` live — see note below)

**Context:** `git ls-files '*Todo.swift'` shows where inventory files live and which test target they belong to. Place `UrlTodo.swift` in that same directory/target so it is compiled (but `.disabled`, so not run).

- [ ] **Step 1: Create the inventory entry**

```swift
import Testing

// Requirement inventory only — `.disabled` short-circuits execution.
// Promote to a real @Test in a *Tests.swift file when implementing.

@Test("""
@spec URL-3.1: When the iOS app opens a graftty://open URL that resolves \
against the connected host's worktree-panes snapshot, the application \
shall select that worktree and focus the resolved pane session.
""", .disabled("not yet implemented — iOS .onOpenURL wiring is a follow-up"))
func url_3_1() async throws { }
```

- [ ] **Step 2: Build the test target to confirm it compiles**

Run: `swift build --target GrafttyTests 2>&1 | tail -5` (or `swift test --filter url_3_1` — expected to be skipped/disabled, not failing).
Expected: compiles; the test does not run (disabled).

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyTests/Specs/UrlTodo.swift
git commit -m "docs(URL-3.1): inventory deferred iOS deep-link wiring requirement"
```

---

## Task 8: Regenerate SPECS.md and full test run

**Files:**
- Modify: `SPECS.md` (generated)

- [ ] **Step 1: Regenerate specs**

Run: `python3 scripts/generate-specs.py`
Expected: exits 0; `SPECS.md` now contains a `Worktree URL Handler` section with `URL-1.1`, `URL-1.2`, `URL-1.3`, `URL-2.1`, and the disabled `URL-3.1`.

- [ ] **Step 2: Verify specs are not stale**

Run: `python3 scripts/generate-specs.py --check && echo CLEAN`
Expected: `CLEAN` (no diff).

- [ ] **Step 3: Run the full deep-link test set**

Run: `swift test --filter DeepLink && swift test --filter GrafttyDeepLink`
Expected: PASS.

- [ ] **Step 4: Full build + test sanity**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -20`
Expected: build succeeds; no new failures vs. baseline (pre-existing unrelated flakes, if any, are out of scope — note them).

- [ ] **Step 5: Commit**

```bash
git add SPECS.md
git commit -m "docs(URL): regenerate SPECS.md with Worktree URL Handler section"
```

---

## Post-implementation (orchestrator, not a subagent task)

- Run `/simplify` over the diff (reuse/dead-code/altitude cleanup) and apply fixes.
- Open a PR (`feat(URL): worktree URL handler — graftty:// scheme (macOS handler + shared resolvers)`), with a body noting: iOS `.onOpenURL` wiring is a tracked follow-up (UIKit-guarded, verify via iOS CI/device), and that `ci.yml` iOS job is the real check for the Info.plist/iOS bits.
- Confirm CI.

---

## Self-Review (completed by plan author)

**Spec coverage vs. design:**
- Custom `graftty://open` scheme → Task 6 (both plists) + Task 2 (parse). ✓
- session= primary key, session-wins → Task 2 (parse tests). ✓
- repo+worktree form, sanitized name → Task 2 + resolvers (Tasks 3–4). ✓
- Worktree + optional pane granularity → resolvers return pane slot / session name; Mac wiring focuses pane (Task 5). ✓
- Mac selection + activate, pane-only-if-running → Task 5. ✓
- iOS snapshot resolver ships + tested; iOS wiring deferred → Tasks 3 + 7 + post-impl note. ✓
- `@spec`/EARS, `URL` prefix, `spec-sections.json`, regenerated `SPECS.md` → Tasks 1, 8. ✓
- Module placement forced by `GrafttyMobileKit → GrafttyProtocol` (not GrafttyKit) → Tasks 2–4 honor it. ✓

**Placeholder scan:** No "TBD/TODO/handle edge cases". The two fixture-construction spots (Tasks 3–4) instruct the engineer to use the *real* initializers discovered in a Context step rather than inventing them — deliberate, because constructor signatures must be read from source, not guessed.

**Type consistency:** `DeepLinkTarget`, `DeepLinkNotFoundReason` (GrafttyProtocol) shared; `SnapshotDeepLinkOutcome` (GrafttyProtocol, `sessionName: String?`) vs `MacDeepLinkOutcome` (GrafttyKit, `paneSlot: PaneSlotID?`) used consistently across resolver + wiring tasks. `GrafttyDeepLink.parse` / `.resolve(_:inSnapshot:)` and `DeepLinkResolver.resolve(_:inRepos:)` names match between definition and call sites (Task 5).

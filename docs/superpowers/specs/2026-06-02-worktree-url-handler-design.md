# Worktree URL Handler — Design

**Date:** 2026-06-02
**Branch:** `url-handler`
**Status:** Approved (design); ready for implementation planning

## Goal

Let a user open a particular Graftty worktree (and optionally a specific
pane within it) by following a link — e.g. from a browser, notes, a
dashboard, or a PR description. The handler must work in **both** the
macOS app and the iOS app.

## Scope (decisions made during brainstorming)

- **Audience:** *self, same machine.* Links resolve locally on the same
  Mac running Graftty (and, analogously, the same iPad running the iOS
  app). No cross-machine portability, no remote-identity scheme.
- **URL type:** a **custom scheme `graftty://`**, registered in each
  app's `Info.plist`. No universal/App Links, no domain, no
  associated-domains entitlement, no web server.
- **Identifier:** two accepted forms (see grammar). A **session** id is
  the primary key because it is the most durable, uniquely-addressable
  unit and it *implies* its worktree and pane. A **repo + worktree**
  form is also accepted for a pane-agnostic "just open this worktree"
  link. When both are present, **session wins**.
- **Granularity:** worktree-level selection, plus optional pane focus
  (free when resolving via session).
- **Link generation is out of scope for v1.** This change implements the
  *handler* only (opening links). No "Copy Link" context menu, no CLI
  `graftty url` command. Links are authored by hand or by external
  tooling for now. (macOS `open "graftty://…"` exercises the handler
  without any new generation code.)
- **iOS `.onOpenURL` wiring is deferred to a follow-up PR.** The shared
  parser and the iOS snapshot resolver ship now (in `GrafttyProtocol`,
  fully covered by `swift test`), and the iOS `Info.plist` registers the
  scheme. But the iOS UI is multi-host and fetches the worktree snapshot
  asynchronously per host across two layouts (iPhone `NavigationStack`
  push-flow vs. iPad `IPadAppState`); there is no single in-memory
  snapshot to resolve against, and the UI is `#if canImport(UIKit)`
  (compiled out on macOS, so unverifiable by `swift test`/`swift build`
  here). Wiring it correctly — and verifying on-device / via iOS CI — is
  a tracked follow-up. This first PR is end-to-end verifiable locally.

## Why a session id is the right key

- Each pane slot maps to a `PaneSessionID` (a UUID), surfaced as the zmx
  session name `graftty-<first-8-hex>` (`ZmxLauncher.sessionName(for:)`).
- Sessions **persist across worktree switches** — they are the most
  stable thing to point a link at, more stable than a worktree's
  on-disk path (which can move).
- A session id **implies its worktree and pane**: scanning every
  worktree's `paneSessions` for the id yields exactly one
  `(worktree, paneSlot)`. So `session=` alone resolves everything — no
  `worktree=`/`repo=`/`pane=` needed alongside it.
- It works on **iOS for free**: the remote host snapshot already ships
  `sessionName` on every pane leaf (`WorktreePanes` `.leaf(sessionName:)`),
  so the iOS app resolves `session=` against state it already holds — no
  filesystem-path dependency.

## URL grammar

```
graftty://open?session=<sessionId>
graftty://open?repo=<repoName>&worktree=<worktreeName>
```

- Scheme: `graftty`. Host/action: `open`. Any other host → ignored.
- `session=<sessionId>`: the zmx session name (`graftty-ab12cd34`) — the
  durable, user-visible session identifier surfaced in snapshots and
  `graftty pane list`. (Raw pane-session UUIDs are intentionally *not*
  accepted: a session name is only the first 8 hex of the UUID, so the
  two can't round-trip; matching compares names. YAGNI.) **Takes
  precedence** if both forms' params are present.
- `repo=<repoName>`: matched against `RepoEntry.displayName`.
- `worktree=<worktreeName>`: matched against
  `WorktreeNameSanitizer.sanitize(branch)` — the same canonical
  worktree "address" string already used by `graftty team msg` and
  `graftty pane <name>` (via `WorktreeNameLookup`).
- Malformed / missing-params URLs parse to `nil` and the handler no-ops.

## Components

The resolution logic is pulled out of the UI into pure, shared functions
so it is testable under `swift test` on macOS and reused verbatim by both
apps. Only the thin `.onOpenURL` glue lives in app-specific scenes.

Module placement is forced by the dependency graph: `GrafttyMobileKit`
depends on `GrafttyProtocol` **but not `GrafttyKit`**. So anything shared
by both apps lives in `GrafttyProtocol`; the Mac-only `[RepoEntry]`
resolver (which needs `GrafttyKit` types) lives in `GrafttyKit`.

| Component | Location | Responsibility |
|---|---|---|
| `GrafttyDeepLink.parse(_ url: URL) -> DeepLinkTarget?` | `GrafttyProtocol` (shared) | Pure parser. Validates `graftty://open`, reads query params, applies session-wins precedence. Returns a `DeepLinkTarget` or `nil`. Needs only `URL` + `WorktreeNameSanitizer` (both in `GrafttyProtocol`). |
| `GrafttyDeepLink.resolve(_:inSnapshot:) -> SnapshotDeepLinkOutcome` | `GrafttyProtocol` (iOS) | Pure resolution against `[WorktreePanes]`. `.session` → finds the worktree with a pane leaf whose `sessionName` matches; `.worktree` → matches `repoDisplayName` + `WorktreeNameSanitizer.sanitize(displayBranch)`. Returns `.resolved(worktreePath, sessionName: String?)` or `.notFound(reason)`. Used by the deferred iOS wiring; testable now under `swift test`. |
| `DeepLinkResolver.resolve(_:inRepos:) -> MacDeepLinkOutcome` | `GrafttyKit` (Mac) | Pure resolution against `[RepoEntry]`. `.session` → scans each worktree's `paneSessions`, comparing `ZmxLauncher.sessionName(for:)` to the target; `.worktree` → matches `RepoEntry.displayName` + `WorktreeNameSanitizer.sanitize(branch)`. Returns `.resolved(worktreePath, paneSlot: PaneSlotID?)` or `.notFound(reason)`. |
| Mac `.onOpenURL { … }` wiring | `Graftty` (macOS `WindowGroup`) | parse → `resolve(_:inRepos:)` → set `selectedWorktreePath`, set the worktree's `focusedPaneSlotID` if a pane resolved and it's running, `NSApp.activate`. |
| iOS `.onOpenURL` wiring | `GrafttyMobileKit` | **Deferred to follow-up PR** (see Scope). Will consume `resolve(_:inSnapshot:)`. |

### Types (data shapes — carry `@spec` doc comments)

```swift
// GrafttyProtocol (shared)
enum DeepLinkTarget: Equatable {
    case session(String)                       // zmx session name, e.g. "graftty-ab12cd34"
    case worktree(repo: String, worktree: String)
}

enum DeepLinkNotFoundReason: Equatable {
    case unknownSession
    case unknownRepo
    case unknownWorktree
}

// GrafttyProtocol (iOS resolver result; focus key is the sessionName string)
enum SnapshotDeepLinkOutcome: Equatable {
    case resolved(worktreePath: String, sessionName: String?)
    case notFound(DeepLinkNotFoundReason)
}

// GrafttyKit (Mac resolver result; focus key is PaneSlotID)
enum MacDeepLinkOutcome: Equatable {
    case resolved(worktreePath: String, paneSlot: PaneSlotID?)
    case notFound(DeepLinkNotFoundReason)
}
```

## Data flow

1. OS receives `graftty://open?session=graftty-ab12cd34`, launches or
   foregrounds the app, and delivers the `URL` to the active scene.
2. The scene's `.onOpenURL` calls `GrafttyDeepLink.parse(url)`.
3. `DeepLinkResolver.resolve(target, in: …)` runs against
   `appState.repos` (Mac) or the connected host's snapshot (iOS).
4. On `.resolved(path, paneSlot)`: set `selectedWorktreePath = path`; if
   `paneSlot` is present **and** the worktree is running, focus that
   pane via the existing focus path; then `NSApp.activate` / bring the
   window forward (Mac) or navigate to the worktree (iOS).
5. On `.notFound`: surface a brief, non-blocking message; leave the
   current selection untouched. No crash, no partial selection.

## Error handling & edge cases

- **Unknown session / repo / worktree** → `.notFound(reason)`; show a
  brief alert/banner; current selection unchanged.
- **Session resolves but worktree not running** (stale/closed) → select
  the worktree anyway; skip pane focus.
- **iOS not connected, or target absent from the current host snapshot**
  → message "worktree not found on the connected host." v1 assumes a
  single connected host (matches "self, same iPad"). Cross-host
  switching is explicitly out of scope.
- **Malformed URL** (wrong host, missing/empty params) → `parse` returns
  `nil`; handler no-ops.
- **Dev builds:** `swift run` is not a registered bundle, so the scheme
  resolves only from the installed `.app`. Known limitation, not a bug.

## Registration

- **macOS:** add a `CFBundleURLTypes` entry (scheme `graftty`) to the
  `Info.plist` heredoc in `scripts/bundle.sh` (bundle id
  `com.graftty.app`).
- **iOS:** add the same `CFBundleURLTypes` entry to
  `Apps/GrafttyMobile/GrafttyMobile/Info.plist` (currently has none).

## Testing & specs

New `@spec` prefix **`URL`** (verified unused). Register it in
`scripts/spec-sections.json` (`section_order` + `sections`, section
title e.g. "Worktree URL Handler") and regenerate `SPECS.md`.

Behavioral specs target the pure layer (covered by `swift test`):

- **Parser** (`GrafttyDeepLink.parse`):
  - parses each valid `open` form into the right `DeepLinkTarget`;
  - normalizes a session id given as `graftty-xxxx` vs as a raw UUID;
  - session-wins precedence when both forms' params are present;
  - rejects a non-`open` host → `nil`;
  - missing/empty required params → `nil`.
- **Resolver** (`DeepLinkResolver.resolve`):
  - `.session` → correct `(worktreePath, paneSlot)`;
  - `.worktree` → correct worktree, `nil` pane slot;
  - unknown session / unknown repo / unknown worktree → the matching
    `.notFound` reason.
- **Type shape:** `@spec` doc comment on `DeepLinkTarget` (and outcome
  enums where a state set is asserted).

Un-implemented backlog requirements go in a new
`Tests/GrafttyTests/Specs/UrlTodo.swift` inventory file as
`@Test(.disabled("not yet implemented"))` entries, per the project spec
convention.

The `.onOpenURL` glue is intentionally minimal so that the iOS wiring —
which `swift test` on macOS cannot exercise (UIKit-guarded) — is just a
few lines over the fully-tested pure resolver; iOS CI is the real check
for that wiring.

## Out of scope (deferred)

- Link **generation** (sidebar "Copy Link", CLI `graftty url`).
- Cross-machine / shareable links (repo+branch portability,
  remote-identity addressing).
- Multi-host switching on iOS.
- Universal/App Links (`https://`) with web fallback.

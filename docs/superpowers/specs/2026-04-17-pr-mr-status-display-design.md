# PR/MR Status Display — Design Specification

Surface GitHub PR and GitLab MR status for each worktree's branch in Graftty's UI. When the repo's origin points at a recognized host and the corresponding CLI (`gh` or `glab`) is available, a compact button in the breadcrumb shows the PR/MR number, title, and CI rollup. Clicking opens the PR/MR in the user's default browser.

This work also rewires git/CLI invocations to be async-native and PATH-agnostic, and adds polling to `WorktreeStatsStore` so divergence counts stay live without requiring the user to manually fetch.

## 1. Goals and Non-Goals

**Goals:**

- Show live PR/MR number + title + CI rollup for each worktree that has one, in the top-right of the breadcrumb bar.
- Clicking the button opens the PR/MR URL in the default browser.
- Polling is adaptive: in-progress CI polls fast, stable states poll slowly, missing data polls rarely.
- All git and CLI interaction is async and off the main thread.
- Divergence stats (`WorktreeStatsStore`) also stay live, with periodic `git fetch` so "N behind origin/main" reflects reality.
- Breadcrumb reads `{repo} / {worktree-name} ({branch})` with full-path tooltip on the worktree-name. Home checkout displays as italic `root` in both breadcrumb and sidebar for consistency.
- Graceful degradation: if the CLI isn't installed, not authenticated, offline, or the host isn't recognized, the button silently doesn't render.

**Non-goals (explicit):**

- Creating PRs or MRs from Graftty.
- Showing reviews, comments, or checks detail.
- Per-worktree status dots in the sidebar (the store is designed to support this later; out of scope for this spec).
- Certifying GitHub Enterprise or self-hosted GitLab (they should work since `gh`/`glab` handle enterprise auth natively, but we don't validate).
- Migrating the codebase to SwiftGit2 / libgit2. Deferred to a separate spec.

## 2. Architecture

Three-layer split, matching existing project convention (pure model in `GrafttyKit`, app-level observable stores, SwiftUI views).

### 2.1 GrafttyKit (pure Swift, no UI)

```
Sources/GrafttyKit/
  CLI/
    CLIRunner.swift               ← new: async Process wrapper, PATH-enriched
    CLIExecutor.swift             ← new: protocol for test injection
  Hosting/
    HostingProvider.swift         ← new: enum .github / .gitlab / .unsupported
    HostingOrigin.swift           ← new: parsed origin (provider, host, owner, repo)
    GitOriginHost.swift           ← new: origin URL parser + repo-local resolver
    PRInfo.swift                  ← new: value type for a PR/MR snapshot
    PRFetcher.swift               ← new: protocol
    GitHubPRFetcher.swift         ← new: shells out to gh
    GitLabPRFetcher.swift         ← new: shells out to glab
  Git/
    GitRunner.swift               ← rewritten as async on top of CLIRunner
    (existing callers migrated to async)
```

### 2.2 Graftty (app, @MainActor observable state)

```
Sources/Graftty/Model/
  PRStatusStore.swift             ← new
  PollingTicker.swift             ← new: shared tick helper
  WorktreeStatsStore.swift        ← existing, gains polling + git-fetch
```

### 2.3 Views

```
Sources/Graftty/Views/
  BreadcrumbBar.swift             ← rewritten
  PRButton.swift                  ← new
  WorktreeRow.swift               ← small edit: italic "root" for home
```

## 3. CLI Infrastructure

### 3.1 `CLIRunner`

Async wrapper around `Process`. Replaces the synchronous `GitRunner` pattern (which callers wrapped in `Task.detached`) with native async/await.

**API:**

```swift
public protocol CLIExecutor: Sendable {
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput
}

public struct CLIOutput: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

public enum CLIError: Error, Equatable {
    case notFound(command: String)
    case nonZeroExit(command: String, exitCode: Int32, stderr: String)
    case launchFailed(underlying: String)
}

public struct CLIRunner: CLIExecutor { ... }
```

- `run` throws on non-zero exit; `capture` returns the `CLIOutput` unconditionally (for commands where exit code is diagnostic — mirrors `GitRunner.capture` today).
- Under the hood: `Process` wrapped in `withCheckedThrowingContinuation`, with `terminationHandler` invoking `resume`. No thread blocks on `waitUntilExit`.
- **No hardcoded paths.** Launches `/usr/bin/env <command> <args...>`, with `PATH` environment variable prepended with common install locations so Finder-launched apps find Homebrew-installed tools.

**PATH enrichment:**

```swift
private static func enrichedEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let extras = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(NSHomeDirectory())/.local/bin"
    ]
    let existing = env["PATH"] ?? ""
    env["PATH"] = (extras + [existing]).filter { !$0.isEmpty }.joined(separator: ":")
    return env
}
```

### 3.2 `GitRunner` migration

`GitRunner` becomes a thin wrapper over `CLIRunner` with `command: "git"`. Existing `GitRunner.run` / `capture` / `captureAll` are rewritten as `async throws` and all call sites migrated:

- `GitRepoDetector`
- `GitWorktreeDiscovery`
- `GitWorktreeStats`
- `GitOriginDefaultBranch`
- `GitWorktreeAdd`
- `WorktreeStatsStore.computeOffMain`
- `MainWindow.addWorktree`

Migration drops the `Task.detached { ... }` boilerplate at call sites — they `await` directly. Tests for each migrated type are updated to inject a fake `CLIExecutor`.

### 3.3 Injection for tests

`CLIRunner` is instantiated at app root and passed down via dependency injection. For tests, a `FakeCLIExecutor` returns canned `CLIOutput` keyed by `(command, args)`.

## 4. Hosting Provider Detection

### 4.1 `HostingProvider`

```swift
public enum HostingProvider: String, Codable, Sendable {
    case github
    case gitlab
    case unsupported
}
```

### 4.2 `HostingOrigin`

```swift
public struct HostingOrigin: Codable, Sendable, Equatable {
    public let provider: HostingProvider
    public let host: String      // "github.com", "gitlab.com", "github.acme.com", ...
    public let owner: String     // "btucker"
    public let repo: String      // "graftty"
}
```

### 4.3 `GitOriginHost`

Resolves a repo's origin URL and parses it into a `HostingOrigin?`.

```swift
public enum GitOriginHost {
    public static func detect(repoPath: String, runner: CLIExecutor) async throws -> HostingOrigin?
    public static func parse(remoteURL: String) -> HostingOrigin?     // pure function
}
```

**`detect`** runs `git remote get-url origin` in `repoPath` and feeds the output to `parse`.

**`parse`** handles:

| Input | Result |
|---|---|
| `git@github.com:btucker/graftty.git` | `.github / github.com / btucker / graftty` |
| `https://github.com/btucker/graftty.git` | same |
| `https://github.com/btucker/graftty` (no `.git`) | same |
| `git@gitlab.com:foo/bar.git` | `.gitlab / gitlab.com / foo / bar` |
| `git@github.acme.com:team/proj.git` | `.github / github.acme.com / team / proj` (heuristic: host contains "github") |
| `git@gitlab.acme.com:team/proj.git` | `.gitlab / gitlab.acme.com / team / proj` |
| `/local/path` or `file://...` | `nil` |
| Unrecognized host | `HostingOrigin` with `provider: .unsupported` (so caller can cache "don't poll") |

**Heuristic for enterprise:** host string contains `"github"` → `.github`; contains `"gitlab"` → `.gitlab`; otherwise `.unsupported`. Good enough in practice; users can override later if needed.

## 5. PR/MR Fetchers

### 5.1 `PRInfo`

```swift
public struct PRInfo: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case open, merged }
    public enum Checks: String, Codable, Sendable {
        case pending       // at least one check in progress, none failing
        case success       // all checks passed
        case failure       // at least one check failed
        case none          // no checks configured / not applicable
    }

    public let number: Int
    public let title: String
    public let url: URL
    public let state: State
    public let checks: Checks
    public let fetchedAt: Date
}
```

Excludes closed-unmerged PRs by contract — fetchers never return them. The rule: prefer open; otherwise most-recent merged; otherwise `nil`.

### 5.2 `PRFetcher` protocol

```swift
public protocol PRFetcher: Sendable {
    func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo?
}
```

### 5.3 `GitHubPRFetcher`

Uses `gh` CLI:

1. `gh pr list --head <branch> --state open --limit 1 --json number,title,url,state,headRefName` — prefer open.
2. If none: `gh pr list --head <branch> --state merged --limit 1 --json number,title,url,state,headRefName,mergedAt`.
3. If a PR is found and `state == open`: `gh pr checks <number> --json name,state,conclusion` — parse rollup into `PRInfo.Checks`.
4. If merged: `checks = .none` (we don't care about CI on already-merged PRs).

Rollup logic for open PRs:
- Any check with `conclusion == "failure"` → `.failure`
- Else any `state == "in_progress"` or `"pending"` → `.pending`
- Else all `conclusion == "success"` → `.success`
- Else (no checks configured) → `.none`

`gh` invocations include `--repo <owner>/<repo>` so we target the right remote explicitly (belt-and-suspenders against implicit remote detection).

### 5.4 `GitLabPRFetcher`

Symmetric using `glab`:

1. `glab mr list --source-branch <branch> --state opened --per-page 1 -F json`
2. If none: `glab mr list --source-branch <branch> --state merged --per-page 1 -F json`
3. For open MRs: `glab ci status --branch <branch> -F json` (or equivalent) → rollup to `.pending | .success | .failure | .none`.

### 5.5 Error handling

Fetchers throw typed errors (`CLIError`, `DecodingError`). The store catches and translates to "remove from infos map" (silent failure).

## 6. Polling

### 6.1 `PollingTicker`

Shared helper class. Each store owns its own instance (different cadences).

```swift
@MainActor
final class PollingTicker {
    init(interval: Duration, pauseWhenInactive: @MainActor @escaping () -> Bool = { true })
    func start(onTick: @MainActor @escaping () async -> Void)
    func stop()
    func pulse()      // wake early (used by "Refresh now")
}
```

Owns a single long-lived `Task`. Calls `onTick` every `interval`, or sooner if `pulse()` is called. On `NSApplication.didResignActiveNotification`, checks the `pauseWhenInactive` predicate; if it returns `true`, pauses until `didBecomeActiveNotification`.

`PRStatusStore` supplies a predicate that returns `false` when any tracked PR is in `checks == .pending`, so in-progress CI keeps polling even while the user is in Slack. `WorktreeStatsStore` uses the default (always pause when inactive).

### 6.2 `PRStatusStore`

```swift
@MainActor @Observable
public final class PRStatusStore {
    public private(set) var infos: [String: PRInfo] = [:]     // keyed by worktree path
    public private(set) var absent: Set<String> = []           // "checked, no PR"

    @ObservationIgnored private var hostByRepo: [String: HostingOrigin?] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var lastFetch: [String: Date] = [:]
    @ObservationIgnored private var failureStreak: [String: Int] = [:]
    @ObservationIgnored private let fetcherFor: (HostingProvider) -> PRFetcher?
    @ObservationIgnored private let cliRunner: CLIExecutor
    @ObservationIgnored private var ticker: PollingTicker?

    public init(cliRunner: CLIExecutor, fetcherFor: @escaping (HostingProvider) -> PRFetcher?)
    public func start(appState: AppState)                      // boots ticker
    public func stop()
    public func refresh(worktreePath: String, repoPath: String, branch: String)  // "refresh now"
}
```

**Cadence** (per worktree, computed at tick time from current state):

| Current state of the worktree's PRInfo | Poll every |
|---|---|
| `checks == .pending` | 25 s |
| open, `checks ∈ {success, failure, none}` | 5 min |
| merged | 15 min |
| absent (we checked, no PR exists) | 15 min |
| unknown (never fetched) | immediately |
| `HostingOrigin.provider == .unsupported` | never |
| `HostingOrigin` unresolved | resolve on tick, then treat as "unknown" |
| worktree in `.stale` state | never |

**Failure back-off:** `failureStreak[path]` increments on fetch error. Cadence multiplier `= 2^min(streak, 5)`, capped at 30 min. Reset to 0 on success.

**Concurrency:** at most 4 fetches run in parallel per tick (simple counter / task group).

**Dedup:** a worktree path already in `inFlight` is skipped on subsequent ticks.

**Rate-limit awareness:** we don't pre-check the rate-limit endpoint; we rely on back-off when a fetch returns a rate-limit error.

### 6.3 `WorktreeStatsStore` polling extension

`WorktreeStatsStore` gains a repo-level polling loop driven by the same `PollingTicker`.

**Per-repo tick:**

1. If failing back-off active, skip.
2. Run `git fetch --no-tags --prune origin <default-branch>` (detached from user's fetch). Timeout at 10 s.
3. On success: for every worktree of this repo (that isn't `.stale`), recompute stats (same code path that exists today).
4. On failure: increment failure streak, apply back-off.

**Cadence:** 5 min stable; exponential back-off on failure up to 30 min; paused on app inactive.

**New public API:**

```swift
public func startPolling(appState: AppState)
public func stopPolling()
```

Called from `MainWindow` alongside `PRStatusStore.start`.

## 7. UI

### 7.1 `BreadcrumbBar`

Rewritten. Displays:

```
{repoName} / {worktreeDisplayName}  ({branch})      [PR button, if any]
```

- `worktreeDisplayName`:
  - If `worktree.path == repo.path` → `"root"` rendered italic.
  - Else `WorktreeEntry.displayName(amongSiblingPaths:)` as-is.
- Tooltip on the worktree-name (via `.help(fullPath)`) shows the full filesystem path.
- Dotted underline on the worktree-name is a visual signal that a tooltip is available.
- Branch name in dim parens.
- `Spacer()` pushes the PR button to the trailing edge. If no `PRInfo` for this worktree, the button is omitted entirely (no empty slot).

### 7.2 `PRButton`

Small pill-shaped control.

**Content:** CI dot + `#<number>` + truncated title (max ~260 pt wide).

**Styling:**

| State | Background | Dot |
|---|---|---|
| Open, checks `.success` | default tint | solid green |
| Open, checks `.failure` | default tint | solid red |
| Open, checks `.pending` | default tint | yellow, pulsing |
| Open, checks `.none` | default tint | gray |
| Merged | purple-tinted | gray (with "✓ merged" label) |

Uses the current `GhosttyTheme` for baseline foreground/background colors where possible so the button matches the surrounding terminal palette.

**Interaction:**

- **Click:** `NSWorkspace.shared.open(pr.url)` → default browser.
- **Right-click context menu:** "Refresh now", "Copy URL".
- **Tooltip:** `"Open #<number> on <host>"`.
- **Accessibility label:** `"Pull request <number>, CI <status>, <title>. Click to open in browser."`

### 7.3 `WorktreeRow` edit

In `branchLabel`, when `isMainCheckout && entry.state != .stale`, render `Text("root").italic()` instead of `Text(displayName)`. All other behavior unchanged. The existing "suppress branch when it equals displayName" rule continues to apply — since `"root" != branchName` for the home checkout, the branch stays visible next to "root", which is desirable (it tells you what the home is checked out to).

`Stale` home checkouts (path gone from disk) keep the existing strikethrough-displayName rendering rather than showing italic "root"; the stale state is the more important signal.

### 7.4 `MainWindow` wiring

`MainWindow` gains `let prStatusStore: PRStatusStore` alongside `statsStore`. Both stores are instantiated at the `GrafttyApp` level and passed into `MainWindow`. `MainWindow` calls `prStatusStore.start(appState:)` and `statsStore.startPolling(appState:)` on first appearance; both are stopped on app quit.

`BreadcrumbBar` receives the selected worktree's `PRInfo?` via lookup against `prStatusStore.infos[worktreePath]`.

## 8. Error Handling

Silent across the board. The PR button is only rendered when `infos[worktreePath] != nil`. All of these map to "no entry in infos":

- `gh` / `glab` not installed (`CLIError.notFound`)
- CLI not authenticated (non-zero exit from `gh pr list`)
- Network offline (CLI error)
- Rate-limited (CLI error)
- Host unrecognized (`HostingOrigin.provider == .unsupported`)
- No PR for this branch (`fetch` returns `nil`)

Errors are logged via `os.Logger` at `.info` level for diagnostics but never surface as UI. Back-off ensures we don't hammer a broken CLI.

Worktree stats polling failures are also silent — the existing `baseRef` / `stats` display gracefully degrades when data is stale or missing.

## 9. Testing

| Layer | Strategy |
|---|---|
| `CLIRunner` | Integration against `/bin/echo` and a shell script fixture; assert PATH enrichment, exit codes, stderr capture, error types. |
| `GitOriginHost.parse` | Pure unit tests against fixture URLs. |
| `GitOriginHost.detect` | `FakeCLIExecutor` returns canned `git remote get-url` output. |
| `GitHubPRFetcher` / `GitLabPRFetcher` | `FakeCLIExecutor` returns JSON fixtures captured from real CLI output (checked into `Tests/GrafttyKitTests/Fixtures/hosting/`). Assert correct CLI arg shape and `PRInfo` decoding. |
| `PRStatusStore` | Inject fake fetcher; drive the ticker manually; assert cadence progression, dedup, back-off, pause-on-inactive, pulse-from-refresh-now. |
| `WorktreeStatsStore` polling | Inject fake `CLIExecutor`; assert fetch then recompute sequencing; failure back-off. |
| Existing `Git*` callers | Tests updated to use `FakeCLIExecutor` rather than relying on a real git binary. |
| `BreadcrumbBar` / `PRButton` / `WorktreeRow` | SwiftUI introspection tests asserting rendered labels and modifiers for each state (italic "root" / dotted underline / dot color / hidden when nil). |
| End-to-end | Manual smoke test against a real repo with `gh` and `glab` installed. |

Fixtures should include at minimum: open PR with passing checks, open PR with pending checks, open PR with failing checks, open PR with no checks, merged PR, empty result (no PR), and a representative `gh` not-authenticated error. Same shape for `glab`.

## 10. Migration Notes

The async `GitRunner` refactor touches every existing git caller. Shipped as a single PR to avoid a half-migrated intermediate state. Each migrated type:

1. Signature changes from `throws` → `async throws`.
2. Call sites drop `Task.detached` wrapping, replace with `await`.
3. Tests switch from real-git dependency to `FakeCLIExecutor`.

`GitRunner` is preserved as an enum but its methods become `async`. Not strictly necessary to keep `GitRunner` at all (callers could talk to `CLIRunner` directly with `command: "git"`), but keeping it gives a git-specific seam that's helpful for future type-specific helpers.

## 11. Out of Scope

Restated for the avoidance of doubt:

- Sidebar per-worktree PR dots.
- PR creation, review, comments, diff, detailed checks view.
- GitHub Enterprise / self-hosted GitLab validation.
- SwiftGit2 / libgit2 migration.
- Multi-remote repos (we only look at `origin`).
- Caching PR state across app launches (ephemeral by design).

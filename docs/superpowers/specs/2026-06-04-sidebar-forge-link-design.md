# Sidebar Forge Link — Design

**Date:** 2026-06-04
**Status:** Approved

## Summary

Project-level sidebar rows get a forge logo (GitHub or GitLab mark) to the left
of the project name. Clicking the logo opens the project's page on that forge
(`https://<host>/<owner>/<repo>`). Repos with no origin remote or an
unsupported provider render exactly as today — no icon, no reserved space.

## Requirements (`PROJECT-2.x` cluster)

- **PROJECT-2.0** — While a repo's origin remote resolves to a supported forge
  (GitHub or GitLab, including self-hosted hosts), the application shall
  display that forge's logo to the left of the project name in the sidebar.
- **PROJECT-2.1** — When the forge logo is clicked, the application shall open
  `https://<host>/<owner>/<repo>` in the default browser.
- **PROJECT-2.2** — If a repo has no origin remote or the origin's provider is
  unsupported, then the application shall render the project row with no forge
  icon.
- **PROJECT-2.3** — While a repo's origin resolves to a supported forge, the
  repo context menu shall include an "Open on GitHub…"/"Open on GitLab…" item
  opening the same URL.

## Decisions

- **Data source:** reuse `PRStatusStore`. It already runs
  `GitOriginHost.detect` per repo, caches results in the private `hostByRepo`
  dictionary, handles transient git failures (PR-4.4), and prunes removed
  repos. We expose an observable read surface rather than duplicating
  detection in a new store or persisting origins on `RepoEntry` (which would
  go stale when remotes change).
- **Icon style:** monochrome, theme-tinted (`theme.sidebarDimIcon`), matching
  the existing "+" add-worktree button. No brand colors.
- **Logo assets:** code-drawn SwiftUI `Path` shapes, not bundled images.
  SF Symbols has no brand marks, and this project has shipped two broken
  releases from resource-bundling mistakes (v0.1.5 `bundle.sh` gap, v0.1.10
  `Bundle.module` trap). Vector geometry in code is tintable by construction
  and has no packaging failure mode.
- **Fallback:** no icon at all for no-origin/unsupported repos. No placeholder
  spacing.

## Components & data flow

1. **`HostingOrigin.webURL`** (GrafttyKit) — computed `URL?` returning
   `https://\(host)/\(owner)/\(repo)`. The single place that builds the forge
   URL; both the icon button and the context-menu item use it.
2. **`PRStatusStore.originByRepo`** (GrafttyKit) — new observable
   `[String: HostingOrigin]`, written whenever the existing private
   `hostByRepo` cache resolves a non-nil host, and pruned alongside it. The
   store remains the single owner of origin detection; `SidebarView` already
   observes the store.
3. **`ForgeLogoMark`** (Graftty app) — SwiftUI view wrapping two code-drawn
   `Shape`s (GitHub octocat mark, GitLab tanuki), template-style, tinted
   `theme.sidebarDimIcon`, ~12–13 pt.
4. **`SidebarView.repoSection`** — leading `Button` in the label `HStack`
   before `Text(repo.displayName)` when the repo's origin resolves to a
   supported provider. `.buttonStyle(.plain)` so the tap doesn't toggle the
   disclosure; `.help("Open <owner>/<repo> on GitHub")` tooltip; action is
   `NSWorkspace.shared.open(url)`. The context menu gains the matching item.
   The "No leading glyph" comment rationale at the repo header is updated —
   a forge mark carries information a folder icon would not.

A small pure helper maps `HostingProvider` → presentation (which mark, menu
title) so PROJECT-2.0/2.2/2.3 are testable without rendering: `.github` →
GitHub mark, `.gitlab` → GitLab mark, `.unsupported`/absent → none.

## Error handling

Nothing new. Detection failures and transient git errors are already handled
by `PRStatusStore` (PR-4.4); the icon is simply absent until an origin
resolves, and absent permanently for no-origin/unsupported repos. The icon
appears after the store's first poll resolves the host (typically well under
a second after launch).

## Testing

Per the repo TDD process (disabled inventory → RED → GREEN), Swift Testing:

- `HostingOrigin.webURL`: github.com origin, self-hosted `gitlab.corp.com`
  origin.
- `PRStatusStore`: using the existing injectable `detectHost` hook — after a
  refresh, `originByRepo` contains the resolved origin; nil-origin repos never
  appear; pruning removes entries for removed repos.
- Provider-presentation helper: mapping for `.github`, `.gitlab`,
  `.unsupported`, and absent origin.
- `scripts/generate-specs.py` regenerated and committed alongside.

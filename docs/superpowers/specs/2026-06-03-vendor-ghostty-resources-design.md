# Vendor Ghostty Runtime Resources — Design

**Date:** 2026-06-03
**Status:** Approved

## Problem

Graftty embeds libghostty (via `libghostty-spm`), but libghostty's companion
runtime files — the per-shell integration scripts (OSC 7 PWD reporting, OSC 133
prompt marks) and the `xterm-ghostty` terminfo entry — ship only inside a full
Ghostty.app bundle. `libghostty-spm` distributes just the compiled
`GhosttyKit.xcframework`.

Today Graftty *borrows* these files from an installed Ghostty.app
(`TerminalManager.pointAtGhosttyResourcesIfAvailable`, CONFIG-2.3) and
*silently degrades* when none is found (CONFIG-2.4). On machines without
Ghostty (or with an anomalous bundle), this silently disables:

- `onShellReady` → the default command is never auto-typed
- OSC 7 PWD tracking and PWD-driven features
- shell-integration attention pings
- `TERM=xterm-ghostty` (falls back to `xterm-256color`)
- (historically) the agent-hooks zsh ZDOTDIR chain — fixed independently by
  ZMX-6.9 (PR #208), which remains as defense-in-depth

The dependency on a *separately installed app* for Graftty's own engine's
runtime files is a historical pragmatism, not a design choice. This design
removes it.

## Decisions (confirmed with Ben, 2026-06-03)

1. **Licensing:** vendor ghostty's scripts verbatim as mere aggregation —
   separate data files, license headers preserved (zsh and bash integrations
   are GPLv3, kitty-derived), attribution/provenance file added. This is
   exactly how Ghostty.app (MIT) itself distributes them.
2. **Precedence:** explicit `GHOSTTY_RESOURCES_DIR` env override →
   bundled copy. The Ghostty.app probing (CONFIG-2.3) is **deleted** —
   behavior no longer varies with whatever Ghostty version is installed.
3. **Sync:** files are checked into the repo, pinned to the ghostty source
   version backing `libghostty-spm` (currently **ghostty v1.2.2** — the
   fork's binary target points at Lakr233's `storage.1.2.2` artifact).
   Updated manually whenever `libghostty-spm` bumps.

## Architecture

### Vendored payload (new, checked in)

```
Sources/GrafttyKit/GhosttyResources/
  ghostty/
    shell-integration/        # ~80K, from ghostty-org/ghostty @ v1.2.2
      bash/ elvish/ fish/ nushell/ zsh/
  terminfo/
    78/xterm-ghostty           # ~4K compiled entry, same source
  PROVENANCE.md                # upstream repo, tag/commit, copy date,
                               # license notes (GPLv3 aggregation), and
                               # the update procedure
```

`ghostty/` and `terminfo/` are siblings, mirroring Ghostty.app's
`Contents/Resources/` layout, so the existing sibling lookup in
`ZmxSpawnConfiguration.availableGhosttyTerminfoDir` works unchanged.

The terminfo entry is compiled per-platform by `tic`; vendor the compiled
`78/xterm-ghostty` from a macOS-compiled source (ghostty v1.2.2's
`ghostty.terminfo` compiled with macOS `tic`, or copied from a v1.2.2
Ghostty.app). If only the source `ghostty.terminfo` is vendored, the existing
`availableGhosttyTerminfoDir` source-entry branch already accepts it.

### Delivery: SPM resources (no bundle.sh changes)

Declare the payload as `.copy("GhosttyResources/ghostty")` and
`.copy("GhosttyResources/terminfo")` resources on the **GrafttyKit** target
(which already declares `.copy("Web/Resources")`). Both directories land at
the bundle root as siblings. Consequences:

- `swift build` adds them to the existing `Graftty_GrafttyKit.bundle`;
  `bundle.sh`'s copy loop is glob-restricted to `*_GrafttyKit.bundle` /
  `*_GrafttyCLI.bundle` and already ships it inside the .app — **zero new
  un-CI'd bundle.sh surface**. (This is why the payload attaches to
  GrafttyKit, not the `Graftty` executable target: a `Graftty_Graftty.bundle`
  would NOT match the existing glob and would require editing bundle.sh.)
- Dev runs (`swift run`, bare binary) resolve the same files via
  `Bundle.module` — dev no longer depends on an installed Ghostty either.
- `GrafttyKitTests` can assert the resources exist via `Bundle.module`,
  giving CI coverage that the payload actually ships (mitigates the known
  bundle.sh-has-no-CI gap for this feature).

Note: GrafttyKit is also built for iOS, so the iOS app carries the ~84K
payload unused. Accepted: SPM cannot easily conditionalize resources per
platform, and the size is negligible.

The resolution helper lives in GrafttyKit (where `Bundle.module` can see the
payload): a `GhosttyRuntimeResources` enum exposing the bundled dir lookup
plus a pure, env-injectable `resolve` function; `TerminalManager` (macOS app
target) calls it before `ghostty_init`.

### Resolution change (`TerminalManager`)

`pointAtGhosttyResourcesIfAvailable()` becomes `pointAtGhosttyResources()`:

1. If `GHOSTTY_RESOURCES_DIR` is set and non-empty in the process env: keep
   it (CONFIG-2.2, unchanged — user override wins).
2. Otherwise `setenv("GHOSTTY_RESOURCES_DIR", <Bundle.module>/ghostty, 1)`.
3. If the bundled directory is missing (corrupt install, future packaging
   regression): log a visible warning (os_log / stderr) — **not** today's
   silent skip — and leave the env unset so downstream guards behave as
   they do now.

The `/Applications/Ghostty.app` and `~/Applications/Ghostty.app` candidates
are deleted. Everything downstream is untouched: `ZmxSpawnConfiguration`,
`WebSession`, `SurfaceHandle`, and specs ZMX-6.3/6.4/6.5/6.9 all key off
`GHOSTTY_RESOURCES_DIR` and keep working with the new value.

The bundled path lives inside the .app (`/Applications/Graftty.app/...`),
which is stable across Sparkle updates, so persisted zmx sessions keep a
valid path.

## Spec changes (EARS, `@spec` convention)

- **CONFIG-2.2** — unchanged (env override wins).
- **CONFIG-2.3** — rewritten: "Otherwise, the application shall set
  `GHOSTTY_RESOURCES_DIR` to the `ghostty` directory bundled in the
  application's own resources (vendored from the ghostty source version
  backing libghostty-spm), so shell integration does not depend on a
  separately installed Ghostty.app."
- **CONFIG-2.4** — rewritten: "If the bundled ghostty resources directory is
  missing, the application shall log a warning identifying the expected
  path and continue with shell-integration features unavailable; spawned
  shells shall still function."
- **CONFIG-2.5** (new): "The application bundle shall include ghostty's
  per-shell integration scripts and the `xterm-ghostty` terminfo entry as
  vendored resources, with upstream license headers preserved and a
  provenance record pinning the upstream version." (CI guard test asserts
  presence of `shell-integration/zsh/.zshenv` and the terminfo entry via
  `Bundle.module`.)

## Testing

1. **Payload guard** (CONFIG-2.5): `Bundle.module`-based test asserts
   `ghostty/shell-integration/zsh/.zshenv` and the terminfo entry exist —
   fails CI if the vendored files are dropped or mis-declared.
2. **Resolution** (CONFIG-2.2/2.3): env override respected; otherwise env
   points into the bundle. (Resolution logic extracted into a pure,
   injectable helper so tests don't depend on process-global `setenv` state.)
3. **Warning path** (CONFIG-2.4): missing-bundle case logs and leaves env
   unset (testable via the extracted helper).
4. **Existing suites**: ZMX-6.3/6.5 tests already cover downstream
   consumption against arbitrary `ghosttyResourcesDir` values — unchanged.
5. Manual verification: fresh pane on a machine without Ghostty.app gets
   OSC 7 (`onShellReady` fires, default command types) and
   `TERM=xterm-ghostty`.

## Error handling

- Missing vendored dir → warning log + graceful degradation (CONFIG-2.4).
- `GHOSTTY_RESOURCES_DIR` set to a bogus path by the user → unchanged
  behavior (user override wins; downstream guards already tolerate it).

## Out of scope

- `WebSession` agent-hooks env propagation (separate known gap; do not fix
  for symmetry).
- Auto-detecting libghostty version drift (PROVENANCE.md documents the
  manual update step alongside the libghostty-spm bump procedure).
- Updating the vendored copy to ghostty 1.3.x (tracks libghostty, not the
  newest Ghostty release).

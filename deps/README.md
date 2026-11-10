# Native dependencies

Graftty builds its two native dependencies itself, from pinned upstream
commits and patch series kept in this repository. Nothing is forked and no
separately published binary is consumed.

| Dependency | Pin | Patches | Built by |
|---|---|---|---|
| libghostty (Ghostty) | `deps/ghostty/UPSTREAM_COMMIT` | `deps/ghostty/patches/` | `deps/ghostty/build.sh` |
| zmx | `scripts/zmx/UPSTREAM_COMMIT` | `scripts/zmx/*.patch` | `scripts/zmx/build.sh` |
| Zig (both) | `deps/zig/VERSION` + `deps/zig/checksums` | `deps/zig/patches/` (iOS std) | downloaded by `scripts/deps zig` |

## Patch series

`deps/ghostty/patches/` follows Electron's convention for carrying patches
against Chromium:

- every patch is `git format-patch` output (author, message and full `index`
  lines), so `git am -3` can merge most upstream moves on its own;
- `deps/ghostty/patches/.patches` lists the order explicitly;
- `scripts/deps checkout ghostty DIR` applies the series to the pinned commit
  as one commit per patch, and `scripts/deps export ghostty DIR` writes DIR's
  commits back to patch files.

`deps/ghostty/package-patches/<package>-*.patch` patch Zig packages that
Ghostty fetches (`zig-pkg/<package>-*`); Zig verifies each fetched package
against its content hash first.

## Building and the cache

`scripts/deps prepare` builds what is missing and links it into the
git-ignored `.deps/` directory, which `Package.swift`, `scripts/bundle.sh` and
the tests read:

```
.deps/GhosttyKit.xcframework   .deps/ghostty.key
.deps/zmx/{zmx,VERSION,CHECKSUMS}   .deps/zmx.key
```

`scripts/swiftpm` and `scripts/bundle.sh` call it automatically. Before
opening the GrafttyMobile Xcode project, run
`scripts/deps prepare --platforms macos,ios` once.

Artifacts live under `~/Library/Caches/Graftty/deps/` (Linux:
`~/.cache/graftty/deps/`), shared by every worktree and keyed by
`scripts/deps key`: a hash of every input that can change the output (pin,
patches, package patches, build script, Zig pin, and `scripts/deps` itself).
Changing any of them builds a new artifact; nothing else does. Builds run
under a lock and publish atomically, so concurrent worktrees wait rather than
build twice. Old keys are never deleted automatically; remove
`~/Library/Caches/Graftty/deps/ghostty/<key>` directories to reclaim space.

## The Ghostty gate

`scripts/deps test ghostty` runs the checks that a pin move or patch edit must
pass: the core paging probes, the production surface probes against the
packaged library (AppKit; UIKit when given a simulator UDID through
`deps/ghostty/tests/run.sh`), Ghostty's `snapshot.snapshot` lib-vt tests, and
the license check. CI's `native-deps` job runs it once per new key.

## Licenses

`Sources/GhosttyKit`, `Sources/GhosttyTerminal`, and the build and probe
scripts here began in [Lakr233/libghostty-spm](https://github.com/Lakr233/libghostty-spm)
(MIT, `deps/ghostty/LICENSE-libghostty-spm`). The shell integration under
`Sources/GhosttyTerminal/Resources/Ghostty/shell-integration` is that
project's MIT rewrite; `deps/ghostty/tests/check-licenses.sh` keeps Ghostty's
GPL-licensed originals out.

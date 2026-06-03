# Vendored Ghostty Runtime Resources — Provenance

| | |
|---|---|
| Upstream | https://github.com/ghostty-org/ghostty |
| Version | 1.2.2 (tag `v1.2.2`) |
| Artifact | https://release.files.ghostty.org/1.2.2/Ghostty.dmg |
| Artifact SHA-256 | `812b8e396654cca2a28421a6a849e278927c88fe3115ea124082f9dfa91ae39e` |
| Extracted | `Ghostty.app/Contents/Resources/ghostty/shell-integration` → `ghostty/shell-integration`; `Ghostty.app/Contents/Resources/terminfo` → `terminfo` (sibling, mirroring Ghostty.app's layout) |
| Copied | 2026-06-03 |

## Why 1.2.2

The payload must match the ghostty source version backing our libghostty:
`btucker/libghostty-spm` (branch `expose-selection-api`) pins its binary
target to Lakr233's `storage.1.2.2` artifact, built from ghostty v1.2.2.

## Update procedure

When `libghostty-spm` moves to a new ghostty version:
1. Download `https://release.files.ghostty.org/<ver>/Ghostty.dmg`.
2. Re-extract both directories exactly as above (see the design doc
   `docs/superpowers/specs/2026-06-03-vendor-ghostty-resources-design.md`).
3. Update this file's version/SHA/date.
4. `swift test` — the CONFIG-2.5 payload-guard test validates the layout.

## Licensing

These files are redistributed verbatim as **mere aggregation** — separate
data files, never linked into Graftty's binaries. The zsh and bash
integrations are GPLv3 (derived from Kitty's); their license headers are
preserved in-file, exactly as Ghostty.app (MIT) distributes them. The
remaining scripts and the terminfo entry carry ghostty's MIT license.

# Ghostty paging experiment results

The September 5 results below cover the terminal core and isolated surfaces.
See [the reproduction instructions](README.md) to run those probes.

## Mobile integration, September 9, 2026

GrafttyMobile can now negotiate screen-first attachment over SSH when built with
the [local paging renderer package](BUILD.md). Builds using the published renderer
and hosts with older running zmx daemons retain the legacy attachment path.

- A real zmx daemon with 100,000 numbered history rows returned a 4,226-byte
  checkpoint in about 0.1 ms. Live output arrived while history was withheld;
  the first requested page was 6,022 bytes. This timing measures host capture,
  not end-to-end mobile opening.
- AppKit and UIKit production probes passed ten scenarios covering complete
  row order, selection and viewport anchors, retained-surface replacement,
  parser modes, resize/reset recovery, invalid pages, and retention limits.
- A mounted mobile terminal restored the current screen, including row 99,999,
  into a container with different dimensions. It imported a page after rotation
  without changing the authoritative terminal grid. The test took about 0.63 s,
  including native renderer initialization and verification.
- The mobile session tests cover checkpoint installation on opening and reopening,
  live input/output with a page withheld, and retained terminal identity.
- Final validation passed 406 mobile tests, 17 SSH/coordinator tests, 132 wrapper
  tests, and 104 daemon tests. Both supported daemon upgrade-compatibility suites
  passed. The full SwiftPM run reported six timing issues in unchanged suites;
  those suites and the paging tests passed serially (31 XCTest and 38 Swift tests).
- A deterministic native test forced pixel dimensions ahead of terminal rows.
  The previous input assertion aborted; the fix preserved the existing selection.
  The isolated test helper is excluded from production archives.

Older pages load when the viewport approaches the oldest loaded content. Only
one page is outstanding. An expired checkpoint preserves the loaded content and
offers an explicit return to the live screen to recover older history. The Mac
application does not yet consume this paging coordinator.

## What the probe verifies

For 1,000, 10,000, and 100,000 uniquely numbered short lines, the probe:

- Restores through READY and checks that unread history remains.
- Resumes an unfinished SGR sequence, then sends 100 live rows before fetching
  any history. The snapshot read offset must remain unchanged.
- Imports one history page and checks that the viewport still follows live output.
- Scrolls to the oldest loaded row, selects its text, and sends another 100 live rows.
- Imports the remaining pages and refreshes Ghostty's render-state cache.
- Checks that selection and visible content still name the same row.
- Checks every original and live row exactly once, in order, with no extra content.
- Loads primary-screen history while the alternate screen is active, then
  checks the primary content after returning.

The C probe also records the legacy decoder's discard behavior. After an
80-to-40-column resize, every pending page returns success with zero applied
rows. Loaded rows remain, and the terminal can still process output. The native
bridge now uses a separate checked entry point, described below. Neither test
implements the checkpoint recovery required by TERM-12.6.

The fixture disables both scrollback retention limits so that all test rows fit.
These settings are for the test only, not proposed client memory budgets.

## Observed results

On September 5, 2026, the patched ReleaseSafe core produced these results:

| Original rows | Full snapshot bytes | Bytes through READY | History pages |
| --- | ---: | ---: | ---: |
| 1,000 | 14,126 | 6,383 | 1 |
| 10,000 | 131,636 | 8,138 | 16 |
| 100,000 | 1,306,838 | 2,639 | 169 |

READY includes the backing page that intersects the active screen, so its
resident history overlap varies. These byte counts come from one simple fixture,
not a bound for arbitrary terminal contents. The 100,000-line run verified all
100,200 original and live rows after import.

The full Debug `zig build test-lib-vt --summary failures` suite also passed
on the pinned source with only `preserve-top-anchor.patch` applied. The focused
regression failed before the fix and passed afterward.

The probe prints elapsed times for full snapshot encoding and READY decoding.
It does not measure network latency or app opening time. It encodes the full
snapshot first, so it does not demonstrate bounded initial host work.

## The patch preserves content at the top

Ghostty represents a viewport at the oldest row with a special `top` marker.
That marker follows the first page in the list. Prepending a page therefore
moves the reader to different content, even though ordinary pinned reading
positions and selections already survive prepends.

`preserve-top-anchor.patch` changes `PageAllocation.prepend` to convert `top`
into a tracked content pin before inserting the page. It does so after all
fallible validation. Rejected pages leave the viewport unchanged. A viewport
following the active screen keeps following live output.

The patch includes a regression test for repeated prepends and the cached
scrollbar offset. It applies to Ghostty revision
`8af6897c0afc63037a8a3efee4162a380e3a4572` only. No dependency pin has changed.

## Native-surface experiment

On September 6, 2026, Xcode Metal Toolchain 17F109 was installed. The newer
renderer then built for macOS and the arm64 iOS Simulator. The UIKit test ran on
an iPhone 17 Pro simulator with iOS 26.5.

Review on September 8 found that the original UIKit probe never sized the
renderer sublayer. Its text assertions passed while drawing skipped the zero-size
layer. Those earlier UIKit results verified terminal state, not frame rendering.
The corrected probe sizes the sublayer during layout, as Graftty's UIKit wrapper
does, and requires a presented IOSurface with dimensions matching the layer.

`surface-probe.m` uses the same test body on both platforms. It creates real
host-managed Ghostty surfaces backed by an `NSView` or `UIView`, calls their draw
API, and checks their text through the surface C API. It covers seven scenarios:

- Restore READY, apply live output, select loaded content, and scroll to its
  oldest row. Import all 169 older pages, then verify the same selection and
  visible row. Verify every original row once, in order, followed by live output.
- Switch to the alternate screen while primary history loads. Return to the
  primary screen and verify all 100,000 original rows and live output.
- Resize from 80 to 40 columns while history is pending. Require recovery
  before consuming a page, keep loaded content, and accept more output.
- Resize from 80 to 40 columns and back to 80 before the next page request.
  Require recovery even though the current width matches the snapshot again.
- Import one page, select loaded content, and scroll to its oldest row before
  resizing. Preserve selection, the visible row, and all remaining page records.
- Change only the terminal height, then import and verify all 100,000 rows.
  After completion, change the width and verify that history stays complete.
- Restore a second snapshot with newline mode and synchronized output already
  enabled. Verify CRLF input conversion before and after mode changes, including
  carriage returns at buffer boundaries. Verify that the normal watchdog clears
  synchronized output without receiving a closing reset, then finish paging.

Each scenario also rejects a truncated READY and a second snapshot installation,
checks repeated page status calls, and destroys its surface and app. The test waits
for the actual terminal grid and scroll position, because surface resize and
scroll actions can be queued to the I/O thread.

The probe also delivers a completed old frame after changing the layer bounds.
It requires rejection without changing the layer's scale. A separate check
preserves the one-pixel iOS tolerance, while Mac still requires exact dimensions.

These checks require frame presentation and terminal readback. They do not
compare glyph pixels, simulate selection gestures, rotate a physical device,
test memory pressure, or verify Graftty's Swift wrapper lifecycle.

## Review fixes restore mode side effects and layout ownership

The original bridge restored terminal mode bits without their I/O-thread state.
An enabled synchronized-output mode had no watchdog and could suppress frame
updates indefinitely. An enabled newline mode left the I/O thread's cached flag
false. Snapshot installation now queues both required mode updates before replaying
the parser continuation and notifies the I/O mailbox.

The host-managed backend also ignored the newline flag on ordinary input writes.
It now converts each carriage return to CRLF when enabled, matching the exec
backend. Conversion uses a fixed 1,024-byte buffer instead of allocating a copy
of the entire paste. The native callback test covers restored, disabled, and
enabled modes, plus input spanning multiple conversion buffers.

The iOS presentation callback previously accepted a mismatched frame and changed
`contentsScale` to make that frame fit. A late frame could therefore overwrite
the host's layout after resize. It now discards larger mismatches and leaves
scale under host control. The deterministic native regression failed against
the original callback, as did the new layer-size and mode-restoration assertions.

The simulator build now targets `apple_m1`, not `apple_a17`, to match the documented
Apple Silicon baseline. The review identified a possible unsupported-instruction
risk on M1, not an observed crash on an M1 host.

On September 8, the corrected probe passed all seven scenarios on AppKit and
the iPhone 17 Pro simulator running iOS 26.5. Those runs required presented frames,
passed the stale-frame and mode regressions, and verified all 100,000 history
rows in the complete-import scenarios. The saved patches applied cleanly to a
fresh pinned source tree and reproduced the tested source.

## Resize invalidation stops before a pending page

The original decoder compares the current width with the width at READY. The
added regression reproduced acceptance of old pages after resizing away from
the original width and back. `resize-history-guard.patch` adds a terminal-local
reflow generation so that the original decoder discards those pages too. The
generation changes before a width resize can mutate rows, including a resize
that later fails during allocation. It is not serialized in the snapshot.

The same patch adds `Decoder.nextAtOriginalWidth`. A changed width or reflow
generation returns `HistoryRequiresRecovery` before consuming a PAGE or changing
the loaded terminal. The bridge exposes this condition as status 2, distinct
from a consumed page, completion, and decoder failure. Repeated calls leave the
pending PAGE unchanged. The caller can still explicitly discard and validate
the old records through the original decoder.

The checked decoder may first consume HISTORY metadata. Each manifest is a
10-byte record header and a 6-byte payload. This lets an empty history finish
normally after resize. The tests check that metadata is consumed only once and
that no incompatible PAGE bytes are consumed. Height-only changes and repeated
requests for the same grid do not invalidate history.

The focused regressions cover widening, narrowing, a width round trip, partial
import, empty history, and completion before FINISH is read. The round-trip and
empty-history tests failed before their fixes and passed afterward. The native
resize assertion also failed against the previous bridge after its first two
non-resize scenarios passed.

On September 6, 2026, the full Debug `zig build test-lib-vt --summary failures`
suite passed with all four experimental patches applied. The ReleaseSafe C probe
also passed at 1,000, 10,000, and 100,000 rows. A fresh source tree with the saved
patches matched the tested source, excluding generated build and package files.

This guard does not recover older history. A production caller still needs a
compatible checkpoint or a reflow-aware importer. It must keep recovery pending
distinct from a fully loaded history and preserve the reader's current content.

## Experimental bridge limits

The shipped renderer uses Ghostty `35e1a0160c4f6797e1bb1ef8e7a2b8c6b114ab58`,
which has no snapshot implementation. Its host-managed I/O patches do not apply
unchanged to zmx's newer Ghostty revision.

`renderer-experiment.patch` ports the host-managed backend, installs the Darwin
static archive, and adds private `graftty_probe_surface_*` test entry points.
They are absent from the public header and are not a proposed production ABI.

The test bridge has these restrictions:

- One installation into a fresh host-managed surface, on the main thread, at
  the snapshot's grid size. Existing search and inspector sessions are rejected.
- A complete trusted snapshot fixture is copied into memory, capped at 8 MiB.
  READY decoding occurs before taking the renderer lock. Each later page is
  decoded from resident bytes under that lock. No network reader is involved.
- The restored terminal replaces the fresh terminal at its existing address.
  A new surface stream handler restores the parser continuation, and terminal
  dirty flags force the renderer to refresh its cached rows.
- Page status distinguishes resize recovery from successful consumption and
  completion. Other discard causes still report a consumed page with zero rows.
  The experiment does not recover that history.
- The fixture's unlimited history budgets and colors are imported. Production
  retention limits, user-theme policy, and untrusted-input hardening remain open.

`ios-renderer-experiment.patch` restores the removed iOS build configuration and
ports Graftty's CoreText and Metal platform patches to the newer revision.
Both native tests use the same snapshot bridge and codec. These artifacts are
not packaged into the shipped XCFramework, and the Swift wrappers still use
their existing dependency revision.

Production integration still requires a supported dependency build, Swift
wrapper integration, retained-surface replacement and cancellation, resize
recovery, demand-driven host export, and the shared attachment protocol. A
smaller READY prefix alone does not remove full snapshot encoding or transport
costs. TERM-12 remains pending.

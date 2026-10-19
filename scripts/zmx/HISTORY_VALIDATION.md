# Bounded history page regression

A detached 80×24 session containing 2,000 lines of
`🧪 history-row-NNNNNN /workspace/project/src/components/HistoryPanel.swift:100`
reproduced the failure against the committed graftty6 daemon. READY succeeded;
ordinal zero returned `PageExceedsBudget` before the client imported history.
Wide cells select the eight-byte snapshot row encoding. A native page can
therefore exceed the 256 KiB encoded PAGE budget even with normal scrollback
settings. Previously the client labeled this host refusal as a memory limit.

The fix sends contiguous suffixes of a native page, bounded by the same encoded
PAGE budget, and keeps the remaining prefix for subsequent requests. Failed
single-row encoding does not advance the cursor. The client distinguishes host
page-size refusal from renderer retention refusal. Memory budgets are unchanged.

## Local evidence

Evidence directory: `/private/tmp/graftty-history-investigation`.

- `zig-red-compat.log`: 109 tests passed; the new dense-row behavioral regression
  failed with `PageExceedsBudget` before slicing was implemented.
- `zig-green.log`: all 110 tests passed after slicing.
- `zig-accounting.log`: all 111 tests passed after adding full-retention coverage.
  The 2,000-line fixture used six slices: host 1,572,864 bytes, client 3,145,728
  bytes. The 15,000-line fixture filled the host retention budget and used 48
  slices: host 9,830,400 bytes, client 19,660,800 bytes. Both fit the unchanged
  50,000,000-byte client budget. Tests also check exact row order, completion,
  retry stability while live output arrives, and non-advancing one-row refusal.
- `wide-red.log`: independent wire reproduction with the committed daemon.
- `native-baseline.log`: the validated native Mac renderer imported ordinary
  ASCII history across three checkpoint generations without refusal.
- `bump-python314.log`: universal graftty7 build and both immutable 0.5-floor
  and committed graftty6 compatibility suites passed, including the dense-page
  wire regression. Universal SHA256:
  `8584a03d1725a49dc6eddaee9e1dd3e8db01f8dfc0c4e84d26e8a6b557b244bf`.
- `harness-review.log`: 32 Python harness tests passed. Swift source parsing and
  `scripts/generate-specs.py --check` passed.

Native tests use the pinned Zig 0.16.0 compiler downloaded from ziglang.org into
that evidence directory, an isolated local cache, and the existing global Zig
cache. The private compiler's libc++ `__random/clamp_to_integral.h` required
`INFINITY` to be replaced with `numeric_limits<_RealT>::infinity()` for the local
SDK. The original header and explanation are preserved beside it. No shared
compiler or project workaround was changed. The universal build uses
`scripts/bump-zmx.sh` with that compiler and Homebrew Python 3.14 on PATH; system
Python 3.9 lacks `termios.tcgetwinsize` required by the compatibility harness.

Local Swift/Xcode execution remains blocked by the parent's confirmed pending
macOS removable-volume permission for the shared caches. No additional external
volume operations or user app/device restarts were attempted after that blocker
was established. Syntax checks are not runtime validation.

## Hosted validation

Dispatch `Native agent integration` with `history=true` on the PR branch. Its
history-only step runs the Swift @spec regression against graftty6 from immutable
commit `16287dce6ae591201092efa52c8f98bf6628cf8e`, requires the intended failure,
restores the candidate binary, then runs `MacPagedTerminalTests` and
`PagedTerminalCoordinatorTests` against the paging renderer. The GREEN step also
supplies the old daemon to TERM-12.45, which requires an accurate host-refusal
state, no automatic retry, and a fresh live shell response after refusal.

The focused provider command is the workflow's normal `run.py` invocation plus
`--history --rows 600`. It uses pinned Codex 0.162.1 and Claude 2.1.296 with local
scripted endpoints. After the final numbered row renders, Mobile attaches;
XCUITest drags must cause older-page loading and reveal older content. Native
scroll bindings then check every numbered row in order. Reconnect and a source
grid change repeat the exhaustive check. Actual touch/rotation screenshots are
retained in `mobile.xcresult`.

The workflow artifact contains RED/GREEN logs, `result.json`, `trace.jsonl`,
`actions.json`, `history-*.json`, native logs, and the xcresult. `result.json`
records tested commit/dirty state, both provider versions, simulator/runtime,
and the actual daemon path and SHA256. A dispatch is not evidence of a passing
run; report its completed outcome and artifact link with the PR.

## Rollout limits

New daemon sessions receive slicing. Existing daemons keep their old exporter
until the user deliberately restarts those sessions; the new client reports
an oversized host page accurately but cannot recover its missing rows by retry.
No active user session is restarted by this change or its validation. Small
transport slices have measurable native allocation overhead; tested default
budgets remain bounded, and genuine local retention limits remain enforced.

## Hosted evidence audit and provider rendering mode

At commit `90d7d09d4def4c502d5e9299ab774dc8f1a5e3db`, run
[39173207673](https://github.com/btucker/graftty/actions/runs/39173207673)
executed one intended RED failure (TERM-12.43) against graftty6 and passed all
18 focused GREEN tests, including TERM-12.43, TERM-12.44 and TERM-12.45.
The separate provider scenario **failed** before any backfill assertion: Claude
2.1.296 rendered the final numbered rows, but Mac and Mobile each had only 37
native rows. The preserved daemon `authoritativeText` also has only 37 rows
and numbered targets 590–599. Codex was not reached. Its original result/trace/xcresult remain in
that run's artifact; this is not passing provider coverage.

The focused history fixture now requests
`CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1` for Claude only. The
[official fullscreen documentation](https://code.claude.com/docs/en/fullscreen)
explains that fresh versions since 2.1.239 can default to fullscreen, which
virtualizes the transcript in the alternate screen, and documents this variable
for classic rendering. Codex retains its default mode. The result records these
choices. Coverage is **classic native terminal scrollback**, not Claude's
fullscreen transcript history. Production settings are unchanged. Before Mobile
attaches, the daemon must contain all 600 numbered rows exactly once in order;
the actual touch gesture must cross an initially unloaded older-row boundary.
Missing structured results, missing provider assertions, zero selected Swift
tests, and missing required regression cases fail the workflow.

### Classic-mode rerun and oracle corrections

At `599ef568c78d348e8da2154c4c3af44e4fc5c2fd`, all 13 normal CI checks passed.
Focused [run 39176059263](https://github.com/btucker/graftty/actions/runs/39176059263)
passed gated Swift RED/GREEN but **failed overall** during Claude's resized
history comparison; Codex was not reached. Its Simulator was
`7B011A6A-8D25-451D-ACEF-72DECB9CF320`, iOS 26.5; providers were Claude 2.1.296
and Codex 0.162.1. The unchanged daemon hash is recorded above.

Artifact audit confirms exact 600-row daemon source, initial Mobile import, and
reconnect import. After resize, Mobile's 900 numbered occurrences exactly match
the daemon's 900 occurrences, including a partial redraw occurrence. Every
original row's full payload remains present. This is source redraw, not imported
duplication. The corrected oracle compares the full ordered occurrence records
against daemon observations before and after loading at the held `end` barrier,
and separately requires all original rows and payloads to survive.

The prior gesture assertion is **not accepted as proof of backfill**: live
spinner growth from 283 to 285 rows could satisfy it while scrolling within the
loaded history. The corrected fixture reads the initial loaded row set without
moving the viewport, then requires a real touch gesture to reveal an older row,
a new page request, and a successful import in the same checkpoint generation.
Read-only DEBUG coordinator diagnostics provide request/import correlation.
Mutation tests reproduce spinner-only, cached-movement, and payload-corruption
false passes in the old oracle; the updated tests also reject dropped, extra,
and reordered rows. Review found and fixed a length-clipping hole using an
extra-wrap RED regression: comparisons now extend to the next row or explicit
model-output end marker, excluding provider footer UI without truncating payload.
Original artifacts remain unchanged.

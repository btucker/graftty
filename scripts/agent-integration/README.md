# Native Claude and Codex integration tests

Run real provider TUIs against a local scripted model endpoint, inside native Mac
and iOS test hosts. The endpoint controls streaming barriers and returns real
provider tool calls. No model API credentials or inference are needed.

## Run locally

Use macOS with Xcode, an installed iOS Simulator runtime, Python 3, and the
snapshot-enabled Ghostty package used by the paging tests. Build the CLI first:

```sh
GRAFTTY_GHOSTTY_PACKAGE_PATH=/absolute/path/to/libghostty-spm \
  scripts/swiftpm build --build-system native --product graftty-cli

python3 -B scripts/agent-integration/run.py \
  --codex /absolute/path/to/unwrapped/codex \
  --claude /absolute/path/to/claude \
  --cli "$HOME/Library/Caches/Graftty/SwiftPM/build/arm64-apple-macosx/debug/graftty-cli" \
  --zmx "$PWD/Resources/zmx-binary/zmx" \
  --ghostty-package /absolute/path/to/libghostty-spm \
  --seed 17 --actions 60
```

The pinned clients are Codex 0.162.1 and Claude Code 2.1.296. Pass the provider
executables, not installed Graftty wrappers. The test installs fresh production
wrappers and plugins into its temporary home. Codex uses Graftty's real managed
app-server setup. Claude uses manual permissions so native tool approval remains
part of the test.

The runner creates and builds a disposable simulator before starting the native
command loop deadlines. Select an installed runtime with
`--runtime com.apple.CoreSimulator.SimRuntime.iOS-26-4`. To reuse a particular
test device, pass `--simulator UUID`; the runner does not delete that device.
`--mac-only` is a diagnostic mode and does not establish mobile coverage.
Use `--ios-cache /path/to/cache` to keep the Xcode build cache on another volume.

To check blank lower rows after returning to a mobile worktree, add
`--worktree-reentry` to the full Mac and mobile command. This scenario mounts
the production `SingleSessionView` with its retained pane container. It switches
away and back three times for each provider, receives output while hidden,
changes ownership while hidden, and shows and hides the software keyboard.
This bounded probe uses short ASCII rows; the comprehensive scenario retains
its separate Unicode and wrapping checks and their recorded failures.
XCUITest taps the fixture's explicit keyboard focus and dismissal controls;
terminal-tap focus behavior is outside this scenario.
It waits for the keyboard geometry and native grid to settle, then gives the
provider five seconds to repaint. The lower physical rows must contain a clean
provider prompt and match the daemon's numbered output. Blank rows, prompt
overprint, stale nonblank payload, and any observed parsing at the wrong source
grid fail the run. Native observations and screenshots retain the action IDs;
each stage saves the corresponding Mac observation and daemon text.
This scenario does not run the generated action sequence or messaging pairings.

Add `--colors` to run a bounded Codex color probe instead of the numbered-row
and messaging sequence. It streams explicit inline code, a link, Python syntax,
and diff additions and deletions through the real managed Codex TUI. Native
observations require chromatic pixels on each named fixture row. A colored link,
emoji, or status label cannot satisfy a missing syntax or diff sample. The probe
checks Mac output, mobile ownership, mobile reconnect, mobile following, and the
return to Mac ownership. `--colors --mac-only` checks Mac output only.

Add `--notifications` for the bounded native notification scenario. It runs both
real providers, lets each production Stop hook request and submit its Attention
recap through the provider's shell tool, then captures the resulting handoff
files. A second prompt produces a distinct real stop. Exact event replays must
leave the delivery count unchanged; the second turn must increment it.

This scenario requires a current CLI supporting `graftty attention directory`.
Before launching providers, the runner verifies that the CLI and native host
use `GRAFTTY_ATTENTION_DIR` under the private run directory. An older CLI or a
path mismatch aborts the run. The private Mac host disables only its maintenance
consumer so the probe can archive actual hook files before acknowledging them.
It uses production stopped-turn recording and notification request construction
with an injected delivery sink. It never posts a desktop system notification.

The iOS test host receives the captured events through the same command channel.
It mounts production `RootView` with isolated host storage and controlled host
fetches. Native Simulator notifications and XCUITest taps exercise warm,
background, and cold opening, delayed fetch completion, later user navigation,
an ambiguous target, and a disconnected host retry. Alternating direct/relay
snapshot representations of one source stop must create one request, while the
next distinct stop creates another. This checks canonical notification identity;
it does not establish authenticated relay transport or APNs delivery.
Successful activation must also mount the selected retained client through
production `SingleSessionView` and `SessionClient.live`, using the fixture's
existing authenticated SSH-over-WebRTC transport. The selected visible native
renderer must share that client's exact session, report a live connection, and
contain its unique provider completion marker in a fresh viewport observation.
The other real provider is the split sibling and emits a different marker;
seeing its marker fails the target check. A screenshot is captured after these
conditions hold. Cold launch retrieves fresh ephemeral credentials and verifies
the original host fingerprint. Controlled host lists remain separate from this
real terminal transport; full pairing UI and coordinator negotiation are outside
this probe. The delayed-user-selection control changes production selection
state to test cancellation, but does not mount the sibling route, so that case
is explicitly reported as route-state-only coverage.
Controlled input-request snapshots reuse captured pane identities and timestamps
to check request deduplication and tap routing. Those snapshots do not establish
provider permission-hook delivery.
For cold and background cases, the fixture schedules the production request's
unchanged identifier and content with a five-second trigger. This lets XCUITest
terminate or background the app before the operating system delivers the alert.
The native tap and resulting route provide delivery evidence; the submission
counter alone confirms only that the system accepted the request.
`--notifications --mac-only` skips all iOS assertions and reports that scope.

Notification artifacts include the original files in `provider-handoff/`,
`provider-stops-{claude,codex}.json`, controlled replay actions in `actions.json`,
native observations and screenshots, provider model requests and tool results in
`trace.jsonl`, and the Simulator `mobile.xcresult`. `result.json` records provider
versions, Simulator UDID, device type, runtime version/build, executed native
commands, CLI/zmx SHA256 hashes, tested commit, tracked diff hash, hashes of
untracked source files, and per-stage stop/request counts. `tested.patch`
preserves the tracked changes.
The controlled effective-scene-phase retry case fixes the production view's
scene environment to active, while recording the system scene phase separately.
It records actual decoded OS response IDs/routes, effective scene
transitions, and stable probe identity. After a reported fetch failure, a second
same-target response must cause a second fetch and render the exact live target.
No effective scene transition or view remount may supply the retry. This does
not claim the OS remained foreground during Notification Center interaction. Use
`--notifications --notification-case active-retry` for that focused case, or the
workflow's `notification_case` input. The default `all` includes it after the
other lifecycle and error cases. A response observer records real delegate
callbacks and does not inject routes.
The notification scenario does not use generated-action replay or shrinking.
On the Native agent integration workflow, select the independent `notifications`
boolean input to run this scenario. Scheduled runs retain the general scenario.

Add `--history --rows 600` to exercise bounded history transfers with both
providers. The fixture repeats emoji and source paths across physical wraps,
then attaches Mobile after the final numbered row renders. Actual touch drags
must reveal older rows and increase loaded history across the initial boundary.
Native scroll bindings then exhaustively load history and check ordered row
markers through native selection. The scenario reconnects, changes the source
grid, and reconnects again. `history-*.json` records paging states and
the selected rows; `mobile.xcresult` retains the actual gesture screenshots.
The native workflow's `history` input runs this focused scenario. `result.json`
also records the commit, working-tree state, provider versions, simulator
runtime, and exact zmx path and SHA256. Existing daemons must be tested
separately because this runner creates fresh isolated sessions.

The isolated home supplies no `TERM`, `COLORTERM`, or color-forcing variables.
Production terminal creation must supply its capabilities. Start observations
record only the host and terminal color-related environment keys. In particular,
SwiftPM can set `NO_COLOR=1` on the native test process, just as a GUI launcher can
on the real app. The terminal-spawn boundary removes that inherited value before
the user's shell starts. A user's shell startup files can still set `NO_COLOR`.
Existing shells retain their original environment until they are replaced or
the user changes it.

## What runs

Four native sessions provide both same-provider and cross-provider delivery:
Claude, Codex, Claude peer, and Codex peer. Each session emits numbered logical
rows, long paths, Unicode, tables, and a completion marker.

The fixed sequence moves each live session from Mac to mobile and back, rotates
the phone, resizes the follower Mac window, and reconnects the mobile terminal
channel while streaming is held at a named barrier. Native observations include
rendered text, logical reading anchor, selection, grid, owner identity, revision,
scrollbar state, and paging state. Handoffs must converge on ownership and grid.
A follower resize must leave the authoritative grid unchanged. The completed
Mac row sequence and complete ASCII row contents must match the daemon history.
The daemon's text exporter can omit components of complex graphemes, so exact
Unicode content comparison needs a separate oracle. Internal ASCII spacing is
checked except at physical wraps, where the text exports cannot distinguish a
separator from a split word. Unicode rows still participate
in row order and handoff checks. Keyboard show/hide runs while mobile owns the
session; a follower tap must leave the keyboard hidden and the Mac owner's grid
unchanged. Output mismatches retain evidence and
fail the run even when the remaining independent checks complete.

All four provider pairings receive normal and urgent messages through the real
Graftty CLI and production delivery services. A nonce must appear in a provider's
actual model context inside a peer-message envelope. The scripted model then
calls the provider's genuine shell tool to run `graftty team reply`. Both the tool
result and the source agent's reply context must arrive. Quoted title-generation
requests cannot satisfy receipts. Production stop hooks also require genuine
Attention recap tool calls.

A seeded sequence adds window sizes, rotations, ownership changes, scrolling,
terminal reconnects, selection, messages, and snapshots. Mobile scrolling uses
actual XCUITest drags and flings. Identical seeds generate identical actions.
Every action must complete in the corresponding native client; blank rendering
and ownership revision regression fail the run. After generated actions and at
sequence completion, the Mac buffer is checked again when numbered fixture rows
remain in the daemon history. `generatedContentChecks` records `notObservable`
when provider TUIs have virtualized those rows after messaging. Those entries
carry no content guarantee; they do not count as passing content checks. A fixed
baseline failure also prevents shrinking an unrelated generated failure.

These test hosts mount production Mac follower and UIKit terminal views and use
real zmx, authenticated SSH over WebRTC, ownership, provider plugins, and message
routing. They do not drive the complete application's navigation, pairing UI,
biometric prompts, or push notification service. Model behavior is scripted.
Transport fault injection for withheld history pages, provider restart/address
expiry, burst delivery, and live API authentication remain separate follow-up
coverage. The existing ownership and paging suites cover many lower-level
transitions; passing this runner does not replace those suites.

## Failures and replay

Every run prints its directory under `/private/tmp/graftty-ai-*`. It contains:

- `result.json` with the scope, assertions, error, and failure phase.
- `trace.jsonl` with correlated commands, native observations, barriers, and model requests.
- `actions.json` with the generated sequence, when that phase starts.
- `*-failure.json` with native text and authoritative daemon history.
- `colors-*.json` with per-row chromatic pixel counts when `--colors` runs.
- Mac IOSurface PNGs captured by `verify` actions.
- `mac.log`, `mobile.log`, `ios-build.log`, and `simulator-boot.log`.
- `mobile.xcresult` with actual UI screenshots and test output.

Replay a sequence by adding `--replay /path/to/actions.json`. Add `--shrink` to
minimize a generated-phase failure. Every shrink trial starts fresh native hosts,
provider homes, and sessions; only the same failure signature counts. Shrinking
can take many complete runs. Fixed setup failures are not shrunk.

Temporary homes contain only dummy credentials. The server binds loopback and
never forwards model requests. Logs contain scripted provider context, so keep
this runner pointed at its generated fixture workspace. Cleanup kills only the
run's private zmx sessions and owned simulator. Artifacts remain for diagnosis.

## Fast checks and CI

```sh
python3 -B -m unittest discover -s scripts/agent-integration -p 'test_*.py'
python3 -B -m unittest discover -s scripts/agent-endpoint-spike -p 'test_*.py'
GRAFTTY_GHOSTTY_PACKAGE_PATH=/absolute/path/to/libghostty-spm \
  scripts/swiftpm test --build-system native --filter AgentIntegrationProtocolTests
python3 scripts/generate-specs.py --check
```

The normal CI job checks protocol fixtures without launching provider CLIs.
`.github/workflows/agent-integration.yml` runs the native suite daily and by manual
dispatch on a Mac runner, pins provider versions, and uploads native evidence.
The endpoint compatibility spike remains in `../agent-endpoint-spike`.
[VALIDATION.json](VALIDATION.json) records the initial native results, including
rendering failures that still need product fixes.

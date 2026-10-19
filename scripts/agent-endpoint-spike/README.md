# Scripted agent endpoint spike

A local scripted endpoint can drive the real Claude Code and Codex clients without
model inference. This makes streaming output, resize timing, and message receipt
repeatable. Use it as the input source for native Graftty integration tests.

The endpoint compatibility proof lives here. The native Mac/mobile runner is
implemented separately in [agent-integration](../agent-integration/README.md).
The design notes below record the original spike.

## Verified results, October 16, 2026

The [saved receipt](RESULTS.json) records passing runs with Codex CLI 0.162.1
and Claude Code 2.1.296. Both print/exec outputs matched all 2,907 characters.
Both interactive sessions recorded the same exact completed output after all
three PTY size changes. Codex used its real remote app-server connection.
Five fixture unit tests pass, and `scripts/generate-specs.py --check` passes.
No Swift source changed, so the SwiftPM suite was not run for this spike.
Raw transcripts and request logs from the final run remain in
`/private/tmp/graftty-endpoint-av611je7` on the machine that ran it.

## What the spike contains

- `fixture.py` serves Anthropic Messages and OpenAI Responses SSE on loopback.
  It generates numbered rows, long paths, Markdown tables, wide characters,
  combining characters, and emoji. It never forwards a request upstream.
- `smoke.py` starts real clients with temporary homes and dummy credentials,
  checks exact noninteractive output, and optionally starts their interactive TUIs.
  Codex's interactive test uses a separate app-server and `--remote`, as Graftty does.
- `test_fixture.py` checks stream reconstruction and completion events.

The TUI probe changes the PTY from 120 columns and 40 rows to 40×24, 90×30,
and back to 120×40 during streaming. It captures terminal bytes and checks that
the newly written native session transcript records the exact completed response.
This is a client compatibility check. It does not verify the final terminal cells,
scrollback contents, viewport position, Graftty ownership, or mobile rendering.

The first Claude TUI attempt failed a literal search for `END-GRAFTTY-FIXTURE`.
Its output contained `END`, a cursor movement, and `GRAFTTY-FIXTURE`. The missing
hyphen could already occupy the intervening cell. Concatenating printable bytes
cannot reconstruct that screen. Even an alphanumeric token was split by a later
redraw. The probe now checks provider completion transcripts instead. Full
integration tests still need the renderer assertions described below.

## Reproduce the proof

Pass the actual client executables, bypassing installed Graftty wrappers for this
compatibility check. The wrapper remains essential in the later integration suite.
Use Python 3 on macOS. The scripts use only its standard library.

```sh
python3 -B -m unittest discover -s scripts/agent-endpoint-spike -p 'test_*.py'
python3 -B scripts/agent-endpoint-spike/smoke.py \
  --codex /absolute/path/to/unwrapped/codex \
  --claude /absolute/path/to/claude \
  --tui
```

The runner prints its private temporary artifact directory. It saves a JSON receipt,
request bodies, stdout, stderr, backend logs, and raw PTY bytes. Every subprocess
has a fresh provider home and working directory. The environment allowlist excludes
caller credentials, provider settings, Graftty pane identity, and hooks. Codex's
configuration selects a dummy provider; Claude gets a dummy API key. The fixture
records no authentication headers. These scripts do not enforce an OS-level egress
policy, so a dedicated test account with external egress blocked is the right home
for a future automated runner. They do not modify the current agent configuration.

To run a controllable endpoint independently:

```sh
python3 -B scripts/agent-endpoint-spike/fixture.py \
  --output /private/tmp/graftty-scripted-model --rows 2000 --delay 0.01 --gated
```

The server prints its ephemeral loopback URL. A driver can wait for the request in
`requests.jsonl`, perform an ownership or viewport action, then POST to `/release`
to start text deltas. The barrier expires after 60 seconds. Release stays set for
subsequent requests. This single barrier proves the mechanism; the full runner
needs named barriers at several points in each scenario.

## Endpoint configuration

Claude uses `ANTHROPIC_BASE_URL=http://127.0.0.1:PORT`, a dummy
`ANTHROPIC_API_KEY`, and an isolated `CLAUDE_CONFIG_DIR`. It requests
`/v1/messages`. Base URL alone does not replace subscription credentials.
See the official [Claude gateway documentation](https://code.claude.com/docs/en/llm-gateway)
and [configuration directory documentation](https://code.claude.com/docs/en/settings).

Codex uses a dedicated provider in the isolated home:

```toml
model = "gpt-5.4"
model_provider = "fixture"

[model_providers.fixture]
name = "fixture"
base_url = "http://127.0.0.1:PORT/v1"
wire_api = "responses"
requires_openai_auth = false
```

The fake server answers `/v1/responses`. The explicit provider avoids dependence
on the current login. See the official [custom provider configuration](https://learn.chatgpt.com/docs/config-file/config-advanced#custom-model-providers).

The wire protocols differ. Sharing scenario text and scheduling is useful;
pretending one protocol serves both clients is not. The fake endpoint currently
supports streamed text and Claude token counting. Tool calls, thinking, errors,
WebSockets, retry behavior, cancellation receipts, and realistic title generation
are future work. Response IDs are fixed in this minimal fixture. Multi-turn tests
must generate unique IDs and correlate requests with session and scenario IDs.
Both clients made auxiliary title-generation requests during the interactive proof,
so request count alone cannot identify a user turn.

## Existing code to extend

| Existing code | Reuse | Limit |
| --- | --- | --- |
| [`OwnershipModelTests`](../../Tests/OwnershipModelTests/README.md) | Seeded ownership operations, stale epoch/revision checks, shrinking | Fake network; its UIKit seam is absent from the current iOS scheme |
| [`BrowserControlInteractionTests.swift`](../../Tests/GrafttyMobileInteractionTests/BrowserControlInteractionTests.swift) | Real mobile scroll, fling, append, rotation, leader/follower gestures and screenshots | Fixture app, not a real paired agent session; follower top-gap check expects a known failure |
| [`production-test-surfaces.sh`](../ghostty-paging/production-test-surfaces.sh) | Native AppKit/UIKit paging, row order, selection anchors, renderer recovery | Isolated renderer windows rather than the whole application |
| [`PagedTerminalCoordinator`](../../Sources/GrafttyRemoteClient/Remote/PagedTerminalCoordinator.swift) | Checkpoint/page identity, generations, one outstanding history request, recovery states | Needs observation in the real client integration run |
| [`CodexAppServerDeliveryService`](../../Sources/GrafttyKit/Teams/CodexAppServerDeliveryService.swift) and [`ClaudePeerDeliveryService`](../../Sources/GrafttyKit/Teams/ClaudePeerDeliveryService.swift) | Production delivery paths and existing fake-client tests | Successful transport acceptance does not prove model-context receipt |
| [`AgentHookInstaller`](../../Sources/GrafttyKit/Teams/AgentHookInstaller.swift) | Real provider lifecycle and launch setup | Codex wrapper selects a managed home and launches the backend separately |

GrafttyMobile currently carries paired traffic over mutually authenticated
SSH-over-WebRTC. A web client resized to phone dimensions does not test that path.
Use the actual mobile client and renderer. The older WebSocket ownership tests
remain useful for their own transport.

## Recommended full test design

Use one isolated Graftty test instance, one iOS Simulator, a temporary repository,
and two tracked test worktrees with one real agent each. Create worktrees through
Graftty's worktree API or CLI. Do not use this worktree's live agent or durable inbox.
Configure the isolated host state with `GRAFTTY_STATE_DIR` and keep the fixture
provider homes, managed Codex home, Claude session registry, sockets, and zmx
sessions inside that test environment. Verify zmx and keychain isolation too;
setting the state-directory variable alone is not evidence of complete isolation.

The test host must generate its provider wrappers from the test environment.
Setting `CODEX_HOME` on an invocation of the current managed wrapper is insufficient:
the wrapper selects its own runtime home. Its backend starts separately from the
TUI, without forwarding the original TUI argument list. Verify the backend's actual
request destination before beginning the scenario. Disabling Graftty hooks would
invalidate lifecycle and messaging coverage. This spike bypasses wrappers only to
prove protocol compatibility.

Drive AppKit and UIKit through native test hosts or XCUITest. Reuse the mobile
interaction test pattern for gestures and accessibility status. The existing mobile
interaction host is already an Xcode UI-test target; extend it to connect to the
isolated real host. Add a corresponding Mac integration target rather than assuming
`GrafttyCommandUITests`, a SwiftPM target, provides whole-app UI automation.

Keep model streaming and transport faults separately controllable. Pausing the
fake model does not pause SSH output, history pages, or ownership notifications.
Each action waits on a named condition such as `first body delta`, `owner accepted`,
`history request pending`, or `message nonce observed`. Deadlines catch hangs;
fixed sleeps must not decide whether an action has completed.

### Find unknown sequences, then shrink them

Many historical bugs are already fixed. Give the next suite a seeded action
generator so it can discover combinations that a fixed scenario list misses.
Generate valid actions based on current state: start a stream, scroll to a logical
anchor, select, take/release control, resize, rotate, change keyboard visibility,
send a message, disconnect, reconnect, and return to live. Check invariants after
each settled action. Persist the random seed, initial state, action/event trace,
provider binary versions, request IDs, ownership revisions, and artifacts.

Reuse the model harness's shrinking approach to remove actions while preserving
a failure. A seed alone is insufficient for a full native run because scheduling
can vary. Record barrier releases and observed events, and replay the minimized
trace with explicit synchronization. Keep separate cases for declared expected
failures, such as the current mobile follower top gap; they must not silently
turn a whole generated run green.

### First rendering scenarios

Run each scenario with Claude and Codex:

| Scenario | Actions | Assertions |
| --- | --- | --- |
| Narrow then wide during output | Stream; resize Mac; narrow; restore width | Main response completes; logical text stays ordered; no stale trailing cells |
| Mac → mobile → Mac | Open phone as follower; explicitly take control; return control to Mac | Authoritative grid follows current owner; follower resize does not resize the PTY; owner/revision converge |
| Read history during handoff | Scroll to numbered row, select text; continue output; hand off both ways | Same logical reading anchor and selection survive where the product contract promises preservation; return-to-live reaches newest row |
| Rotation and keyboard | Portrait → landscape → portrait; show/hide keyboard as owner and follower | Expected grid/insets; no blank bands; follower-only geometry changes do not mutate PTY dimensions |
| History in flight | Withhold one history page; switch owner/width; deliver page; reconnect | Stale generation rejected; recovery completes or exposes the documented recovery state; loaded history remains usable |
| Repeated reopen | Background/foreground phone; disconnect/reconnect; revisit pane repeatedly | Same terminal session; no duplicate history import; bounded retained surfaces; current input target |

Generate both short rows and wrapping rows. Do not compare raw row counts across
width changes because reflow changes physical rows. Label logical paragraphs and
check selected logical text and renderer cells. Retention limits must be explicit
when checking for missing content. Assert active screen, backing scale, pixel size,
cell dimensions, scroll position, selection, history generation, and ownership
revision along with screenshots. Cursor repaint sequences mean raw PTY marker
occurrence counts are not message or scrollback occurrence counts.

### Messaging scenarios

Exercise Claude → Codex, Codex → Claude, Claude → Claude, and Codex → Codex.
Repeat with receivers idle, streaming, waiting for approval, restarting, and while
display ownership moves between Mac and phone.

1. Send a unique nonce using the production `graftty team send --stdin` path.
2. Record the inbox ID and selected exact agent/session identity.
3. Inspect the recipient's subsequent model request for the formatted envelope and nonce.
4. Script a tool call that invokes `graftty team reply` using that inbox ID.
5. Confirm the reply reaches the original sender's model context and the intended
   pending-message state advances, without unrelated messages being consumed.

Step 3 proves provider-context receipt. A CLI success or socket write alone does
not. Step 4 requires adding tool-call events and tool-result continuation to both
protocol adapters. The current prototype emits text only and does not claim a
messaging pass. Do not substitute fake provider sockets for this end-to-end check.

Include normal and urgent sends, ordered bursts, XML-like text and Unicode,
exact-address disappearance, provider-address queuing during restart, and failures
before/after native transport acceptance. Specify delivery guarantees at each
boundary before asserting exactly-once behavior: a retry after uncertain acceptance
can duplicate transport delivery even if the durable inbox contains one row.
A scenario ID is also needed so auxiliary title requests cannot satisfy the
recipient-context assertion accidentally.

## Implementation order and decision

Proceed with this approach. Start with a native Mac/mobile ownership round trip
using the text fixture, then add request-correlated messaging and tool replies.
Extend the existing seeded model checker for broad interleavings; preserve a short
set of real-client native scenarios on a dedicated Mac runner. Add a small scheduled
live-provider smoke test for authentication and protocol drift. It complements the
scripted suite and need not decide PR outcomes.

Before implementing product behavior or test-only seams, promote the relevant
existing `@spec` inventory entry or write the requirement in a real Swift test,
observe RED, implement GREEN, run `scripts/swiftpm test`, and regenerate `SPECS.md`.
This spike changes no production behavior or Swift annotations.

# Team Worktree Sharing — Design

**Date:** 2026-06-05
**Status:** Draft for review
**Branch:** multi-user

## Problem

When a team works on a repo together, nobody can see what anyone else is working
on. Each developer runs graftty with their own worktrees and agent fleets; the
only coordination channels are git pushes and out-of-band chat. Agents duplicate
investigation, collide on the same files, and coordinate only through humans as a
relay. Knowledge produced in terminal sessions (errors hit, fixes found)
evaporates into scrollback.

**Anchor goal:** every human on a team can see what every other human (and their
agents) is working on — and every agent can do the same — without anyone
granting standing access to their machine or account.

## Non-goals (deferred)

- Containerized worktrees / OS-level privilege isolation (only needed for
  unattended or untrusted access; the consent model below makes it unnecessary
  for v1).
- Session migration to servers ("eject to server" / pause-resume containers).
- Standing access grants ("always allow ben to view") — revisit only if lease
  renewal proves annoying in practice.
- Public/anonymous sharing with people outside the team (no repo access).

## Design overview

Three trust rungs, expressed as one UI gesture:

```
ambient   sidebar presence — teammates' worktrees appear in the worktree list
          (consent = being on the team; metadata only, never pane content)
   │ click
request   "view auth-refactor?"  ──► owner prompt ──► time-boxed lease
   │                                                   👁 indicator while active
request   "control pane 2?"      ──► owner prompt ──► short lease, revocable
          "search history?"      ──► owner prompt ──► long lease, query audit
```

There is **no stored permission policy**. Every access beyond ambient presence
is a live, human-granted, time-boxed lease. Humans and agents use the same
request pipeline; the human owner always holds the consent gate.

## Components

### 1. Team presence in the sidebar

Teammates' worktrees appear **interleaved with local worktrees** in the repo's
worktree list (unified-by-branch layout). The branch is the primary object; a
row's identity is `(owner, branch)`.

- Remote rows carry an owner badge and ambient styling (dimmed/hollow marker —
  per existing convention, no saturated status colors). Local rows keep today's
  appearance and interactivity.
- Remote row content: branch, owner, agent state (running/idle), current task
  summary, last-activity freshness.
- Same branch checked out by two people → one row per `(owner, branch)`,
  adjacent in the list (never merged).
- Remote presence data lives in a sibling type to `WorktreeEntry` carrying
  presence fields instead of pane state, rendered by the same sidebar list.

**Transport: git refs on the shared remote.** Each member's graftty pushes a
small presence document to `refs/graftty/presence/<user>` (push on change +
heartbeat) and fetches teammates' refs periodically (~1 min freshness).
Repo write access *is* team membership — no separate roster, no new
infrastructure. Stale presence (no heartbeat past TTL) renders as offline and
eventually drops from the list.

### 2. The request/consent/grant primitive

One pipeline, N request types:

```
request(type, target, reason, requester-identity)
  → owner prompt (notification + in-app)
  → grant: time-boxed lease (per-type default duration)
  → active indicator on owner's screen + audit log
  → expiry or explicit revocation
```

- Requests queue when the owner is away ("ben asked to view auth-refactor ·
  12m ago"); they expire if unanswered.
- Grants are leases, never standing policy: scoped to
  `(requester, worktree, type)`, auto-expiring, revocable with one click.
- Agents send requests through the same rails. The prompt identifies the
  requesting agent and its stated reason; the owner's consent is always the
  gate. No separate agent-permission model exists.
- Every active lease is visible to the owner (e.g. "👁 sarah is watching") and
  every action under a lease is logged.

### 3. Launch request types

| type | grants | lease default | notes |
|---|---|---|---|
| `view` | live read-only stream of a worktree's panes | session-length (e.g. 1h) | input bytes dropped **host-side**, never client-side; 👁 indicator in pane |
| `control` | interactive input to a specific pane | short (e.g. 15–30 min) | owner sees every keystroke land; one pane, not the worktree |
| `search-history` | queries against a worktree's history index | long (e.g. 24h) | responses are redacted snippets, never the index; per-query audit log |

Lease defaults differ per type because usage patterns differ: control is
human-paced (one request, one session); history is agent-paced (a dozen queries
in five minutes — per-query prompts would train the owner to mash "allow").

Clicking a teammate's worktree row opens it **like a local worktree** — same
pane layout, live terminal rendering — gated by a `view` request on first open.

### 4. History pipeline

Capture is a per-session pipeline, not parallel indexes:

```
raw PTY stream (per session, append-only)        ← capture substrate
  ├─► OSC-133 records (cmd, output, exit, cwd)   ← shell panes, high signal
  ├─► ANSI-stripped, deduped full text            ← TUI/agent panes, fallback
  └─◄ linked: agent transcript JSONLs             ← joined on (session, time)
```

- Raw is the source of truth; records and full-text are re-derivable
  projections (segmenter/redactor improvements can re-index old history).
- **Redaction happens at index time**, not query time — secret-pattern
  scrubbing means secrets never enter the searchable corpus.
- Agent panes are full-screen TUIs and emit no OSC-133 marks; the stripped
  full-text projection is what captures agent activity. TUI redraw dedup is
  required or every hit is dozens of copies of the same frame.
- Terminal records link to agent transcripts via `TeamPresenceRecord`'s
  existing `(runtime, pid, paneSessionName)` mapping + timestamps.
- Terminal history and agent transcripts are separate corpora with separate
  sharing: a `search-history` lease covers terminal records; transcript access
  is a future, separate request type.
- Index is per-worktree (scoping unit for leases). Local search
  (`graftty history search`) ships first and needs no leases.
- Remote queries execute on the owner's machine; only redacted snippet results
  cross the wire. No bulk index transfer.

### 5. Transport & identity (WebRTC)

Live view/control streams and history queries ride **WebRTC data channels**,
building on the existing M1.x stack (peer connection M1.1 ✅, signaling M1.2,
Noise handshake M1.3, channel framing M1.4):

- **Signaling rides the git remote**, like presence:
  `refs/graftty/signal/<requester>--<owner>` carries the SDP offer; the owner's
  presence poll picks it up and writes the answer back the same way. Seconds of
  setup latency is acceptable for session establishment. No signaling server.
- **Identity distribution rides the git remote too**: each member publishes
  their public identity key at `refs/graftty/identity/<user>`. Repo access =
  team membership = key distribution (TOFU-via-repo).
- **Noise handshake (M1.3) over the data channel** pins the connection to those
  identity keys and provides E2E encryption — a TURN relay (if NAT traversal
  requires one) sees only ciphertext.
- Tailscale, where present, is an optimization (direct connectivity, existing
  `WEB-8.*` plumbing), not a requirement.
- The pane streaming protocol reuses the existing WebSocket-attach semantics
  (`zmx attach` child piping PTY output) reframed over a data channel; the
  read-only enforcement (dropping input) lives in the host-side attach layer.

## Data flow (view request, end to end)

1. Sarah's sidebar shows ben/auth-refactor (presence ref, fetched ~1 min ago).
2. Sarah clicks the row → graftty writes a `view` request into the signaling
   ref and shows "requested — waiting for ben".
3. Ben's graftty (presence poll) surfaces the prompt: "sarah requests to view
   auth-refactor · Allow 1h?" → Ben accepts.
4. SDP answer + ICE via signaling refs → WebRTC data channel up → Noise
   handshake pins both identity keys.
5. Ben's graftty spawns read-only `zmx attach` children for the worktree's
   panes and streams output over the channel. Input from Sarah's side is
   dropped host-side. Ben's panes show 👁.
6. Lease expires after 1h (or Ben revokes) → channel closes → Sarah's view
   becomes a static "lease ended" snapshot.

## Error handling

- **Owner offline / unreachable:** request queues in the signaling ref with
  TTL; requester sees "waiting"; expired requests are garbage-collected.
- **Presence staleness:** heartbeat TTL → row dims to offline → drops after
  longer TTL. Clock skew tolerated by using ref-push times, not local clocks.
- **Connection loss mid-lease:** lease survives brief reconnects (same
  signaling path re-establishes); the 👁 indicator only clears on lease end.
- **Ref conflicts / force-push races:** presence and signaling refs are
  per-user namespaced; writers only touch their own refs. Signaling exchanges
  are append-and-acknowledge documents keyed by request ID.
- **Redaction failure modes:** redactor is conservative (over-redact); raw
  capture is never shared, so a redactor bug's blast radius is the snippet set
  of granted queries.

## Security model

- **Ambient tier exposes metadata only** (branch, agent state, task summary).
  Pane content never syncs to the git remote.
- **No standing grants.** All access is leased, visible, audited, revocable.
- **Read-only is enforced host-side.** A malicious client cannot inject input
  under a `view` lease.
- **`control` is pair-programming-grade trust:** short lease, owner present and
  watching keystrokes land, instant revocation. The threat actor here is "a
  teammate with repo write access" — who could already land malicious code via
  a PR. Unattended/untrusted access is explicitly out of scope (that's the
  deferred container work).
- **Secrets:** history is redacted at index time; live view carries a visible
  watching indicator so the owner knows not to `cat .env`. Residual risk
  (secret on screen during a granted view) is accepted for v1 and noted in
  docs.
- **E2E encryption** via Noise; identity keys distributed through the repo the
  team already trusts.

## Testing

Per project convention, every behavior lands as an `@spec` (EARS) requirement —
new ID prefixes suggested: `PRESENCE-*` (sidebar/git-ref sync), `REQ-*`
(request/consent/grant primitive), `HIST-*` (capture/index/search),
`SHARE-*` (view/control streaming). Key spec-shaped behaviors:

- Presence: push-on-change + heartbeat; TTL staleness rendering; one row per
  `(owner, branch)`; remote rows are non-interactive beyond the request flow.
- Requests: queue-while-away; expiry; lease durations per type; revocation
  closes channels; audit entries per action.
- View: input dropped host-side (test: bytes sent under a view lease never
  reach the PTY); indicator lifecycle.
- History: OSC-133 segmentation; TUI dedup; redaction at index time (test:
  known secret patterns absent from index); remote queries return snippets
  only.
- Signaling: offer/answer round-trip via refs; request GC; identity key
  pinning (test: handshake fails against a substituted key).

## Phasing

1. **P1 — Presence:** git-ref presence sync + unified sidebar. Standalone
   value; no request pipeline yet. (Remote rows show metadata; click shows a
   read-only detail of synced data.)
2. **P2 — Request primitive + view:** signaling over refs, WebRTC channel,
   Noise pinning, consent UI, leases/audit, read-only pane streaming.
3. **P3 — Control:** input under short leases; keystroke visibility;
   revocation hardening.
4. **P4 — History local:** capture pipeline, indexes, redaction,
   `graftty history search` for the local team. No network surface.
5. **P5 — History federated:** `search-history` request type over the same
   rails; per-query audit.

Each phase ships independently and the order front-loads the highest
value-to-risk ratio (P1 has zero new attack surface; P4 is local-only).

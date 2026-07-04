# WebRTC landing program — deferred follow-ups

Consolidated at W6 from the per-milestone reviews (W1–W5). These are the items
that were **adjudicated out of scope** during the program — none block the
real-device gate ([`WebRTCRemoteAccessSmokeChecklist.md`](../WebRTCRemoteAccessSmokeChecklist.md)).
Fixed-in-a-later-wave items are listed too, marked ✅, so the audit trail is
honest about what was carried and what got closed.

## Open

### FU-1 — LoopbackPeer 5-copy dedup (test infra)
The iOS SSH loopback suites each carry their own copy of the `LoopbackPeer`
harness (≈5 copies). Deduping means a shared test target that links the native
WebRTC SDK and a matching `.pbxproj` change — the setup cost currently outweighs
the win. **Effort:** M. **Risk if left:** copies drift; a wire-format change
must be applied 5×.

### FU-2 — SSH `window-change` bypasses the 10 000-column grid cap (parity nit)
The `/ws` path clamps requested terminal dimensions to a 10 000-column grid cap;
the SSH `window-change` handler does not clamp equivalently. Not exploitable in
practice (real devices never request such a grid), but the two transports should
agree. **Effort:** S. **Fix:** clamp in the SSH `window-change` handler to match
the `/ws` path.

### FU-3 — Pairing coordinator `beginPairing` reentrancy / teardown race (W1)
A millisecond-window race between overlapping `beginPairing` calls and listener
teardown; self-heals at the expiry tick. No observed user impact. **Effort:** S.
**Fix:** serialize `beginPairing` against teardown (or add a generation guard
mirroring the one added to `WebRTCHostAgent` in W5).

### FU-4 — `PairingHTTPServer` generation-identity on instance reuse (W1)
A reused `PairingHTTPServer` instance doesn't carry a per-start generation, so a
late callback from a prior start could in principle act on a newer start. Not
exploitable today (lifecycle is serialized by the W1 start/stop fix, commit
`217f9fd`), but the identity should be explicit. **Effort:** S.

### FU-5 — Duplicate-fingerprint re-pair UX (W1)
Re-pairing a device whose fingerprint is already trusted works but can surface a
cryptic failed state instead of a clean "already paired / re-pairing" affordance.
Also de-vacuous the `beginPairingClearsLastError` test (it currently can't fail
for the right reason). **Effort:** S. **Owner note:** confirm the exact symptom
during smoke-checklist §1.

### FU-6 — Background-invalidate re-auth latency is a product decision (W3)
`IPAD-5.1` unconditionally tears down the whole `RemoteHostConnection` on
background, so every app switch pays a full re-negotiate + second SSH userauth on
foreground. Whether that's acceptable or should be relaxed (keep the connection
warm across a short background) is a **product call informed by the real-device
feel test** — smoke-checklist §4. File the relax-`IPAD-5.1` ticket *after*
measuring. **Effort:** M (if relaxed).

### FU-7 — Preview-pool bg→fg coverage + channel-count E2E (W3)
The preview-pool background→foreground transition is covered by inference, not a
dedicated test, and the `≤ 8` concurrent-terminal-channel cap
(`IPAD-4.1`) lacks an end-to-end assertion. Plan risk item that stayed
unverified. **Effort:** M. **Fix:** dedicated bg→fg test + a channel-count E2E.

### FU-8 — Stale `invalidatedWhileInFlight` one-shot false-positive (W3)
A nanosecond-window false-positive on the `invalidatedWhileInFlight` one-shot
flag; self-healing (the next negotiation clears it). **Effort:** S. **Fix:** clear
the flag alongside the in-flight slot rather than one tick later.

### FU-9 — Historical planning docs narrate a non-existent `triggerUserInitiatedClose` (docs)
Dated design/planning docs still describe a `triggerUserInitiatedClose` entry
point and a "R6 deletes `/ws`" direction that the program reversed (we kept
`/ws`). The authoritative tables were annotated during W5; the narrative prose in
the older docs was left as dated record. **Effort:** S, optional. **Fix:** add a
"superseded — see program plan" banner, don't rewrite history.

## Resolved during the program (carried, then closed)

- ✅ **`WebRTCHostAgent.sshInstallStarted` never reset on `close()`** → reconnect
  opened a dead DataChannel with no SSH. Fixed in **W5** (`bd63fea`); un-latented
  W4's `REMOTE-2.1`/`REMOTE-3.2` reconnect paths. *Verify on real hardware:*
  smoke-checklist §5.
- ✅ **Reconnect close-alias race** — resetting the latch made
  `SSHConnectionRegistry`'s `register()` replace-path reachable on the single
  shared agent, where `await previous.close()` aliased the current `self` and
  could tear down the live reconnected connection. Fixed in **W5** (`89a847b`)
  with a per-connection generation guard; W4 revocation
  (`REMOTE-3.1`/`REMOTE-3.3`) verified intact through the real production closure.
- ✅ **Triple-duplicated `.stdErr` control-frame codec** — unified into
  `GrafttyProtocol.StdErrControlFraming` in **W5**; host, mobile, and tests now
  agree on the `<u32 BE len><UTF-8 JSON>` wire format by construction.
- ✅ **`IPAD-2.4` backlog spec cited the deleted `TerminalChannelPool`** — reworded
  in **W5** (`3b748e5`) to the SSH `TerminalSessionClient` model; `SPECS.md`
  regenerated.
- ✅ **Dead `ChannelRouter` / `ChannelFrame` M1.4 scaffolding** — deleted in **W5**
  (−1093 lines); superseded by the R4/R5/W2 SSH channels.

## Named non-goals (not follow-ups — deliberate scope)

- **Multi-connection host agent.** The host serves one WebRTC connection at a
  time; a second device gets `HostError.busy` and falls back to `/ws`
  (smoke-checklist §6). Concurrent SSH multiplexing was never in program scope.
- **Retiring `/ws`.** Reversed early in the program by user direction — `/ws` is
  kept as the browser path and the fallback, sharing the ownership /
  terminal-engine core with the SSH transport (the "small compatibility layer"
  goal).

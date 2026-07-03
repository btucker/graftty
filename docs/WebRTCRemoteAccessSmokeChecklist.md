# WebRTC / SSH-over-WebRTC Remote-Access Smoke Checklist

Manual acceptance gate for the WebRTC landing program (W1–W6). The automated
suites run entirely over an in-process **loopback mirror** — no real
`RTCPeerConnection`, no real network, no real Apple SSH userauth. Everything in
this file is what the mirror *cannot* prove and must be confirmed on real
hardware before the program is considered landed.

Run this end-to-end whenever the WebRTC transport, the pairing ceremony, the
SSH channel layer, or the display-ownership core changes.

## Hardware / setup

- [ ] **Mac host** running a debug/release build of Graftty with at least one
      worktree that has a live pane.
- [ ] **iPhone** (compact layout) with the mobile app installed.
- [ ] **iPad** (regular layout) with the mobile app installed.
- [ ] A second browser on the **same LAN** for the `/ws` regression leg.
- [ ] All three devices on the **same Wi-Fi / LAN** (the pairing ceremony is
      LAN-only plaintext HTTP authenticated by the QR-pinned fingerprint).
- [ ] Console.app or the host log open, filtered to Graftty, so you can confirm
      *which transport* a session actually rode (SSH-over-WebRTC vs `/ws`
      fallback) rather than inferring it from the UI.

---

## 1. LAN pairing ceremony (W1 — `REMOTE-1.x`)

The mirror never scans a QR code or serves the plaintext pairing HTTP listener.

- [ ] Mac Settings → show the pairing QR. iPhone scans it, the verification code
      matches on both screens, tap Confirm → device appears under **Paired
      devices**.
- [ ] Repeat from the iPad. Both devices persist as `TrustedPeer`s across an app
      relaunch on the host.
- [ ] **Deny path:** start pairing, mismatched code / tap Cancel on the phone →
      host shows no new peer and the listener stops.
- [ ] **Expiry path:** show the QR, wait past the pairing window without
      scanning → the listener tears down on its own (bounded by the ~5 min
      expiry tick). Confirm no lingering listening socket.
- [ ] **onDisappear teardown (W1 note):** switch the Mac Settings tab away from
      pairing mid-ceremony → the listener stops promptly (worst case bounded by
      the 5 min expiry). Watch the log for the stop.
- [ ] **Re-pair a known fingerprint:** pair, remove, pair the *same* device
      again → succeeds cleanly (this is the duplicate-fingerprint UX flagged as
      a follow-up; note if the failure state is cryptic).

## 2. SSH-over-WebRTC terminal attach (W2 — `IPAD-2.4`, `REMOTE-4.x`)

Confirm the session rides **SSH over the DataChannel**, not the `/ws` fallback.

- [ ] iPhone opens a paired worktree → a pane attaches. **In the host log,
      confirm the attach registered as an SSH session channel**, not a `/ws`
      upgrade.
- [ ] Type in the pane → bytes echo back with no perceptible lag on-LAN.
- [ ] **Resize actually resizes:** rotate the device / change split ratio →
      the remote PTY reflows (this exercises the real-PTY `SIGWINCH` path W2
      unified; the mirror can't prove a real winsize change).
- [ ] **Shell-integration env (W2 unification):** the SSH-created session gets
      the same `TERM` / `ZDOTDIR` / shell-integration environment as a `/ws`
      session — confirm the prompt, theme, and title-reporting behave identically
      to the browser terminal (no automated coverage exists for this on the real
      engine over SSH).

## 3. Display ownership / take-control across transports (W2 — `REMOTE-5.2`, `REMOTE-9.x`)

The ownership core is shared between `/ws` and SSH; only real devices exercise
two *different* transports arbitrating the same session.

- [ ] Mac owns a pane. iPad attaches as a **follower** (read-only view, no cursor
      ownership).
- [ ] iPad **takes control** → ownership flips; the Mac becomes the follower and
      the take-control indicator updates on both.
- [ ] Put a **browser `/ws` client** and an **SSH mobile client** on the *same*
      session. Take control from one → the other sees the ownership change
      (cross-transport arbitration through the shared
      `SessionDisplayOwnershipStore`).

## 4. App-switch reconnect feel (W3 — `IPAD-5.1` / `IPAD-5.2`)

**This leg drives a product decision** — see follow-up on background-invalidate
re-auth latency.

- [ ] Attach a session on the iPad, then background the app (home / app switcher)
      and foreground it → the app re-negotiates and re-attaches. **Time it.** Is
      the re-auth + re-negotiation latency acceptable, or does it feel like a
      stall on every app switch? Record the number — it decides whether
      `IPAD-5.1`'s unconditional teardown-on-background should be relaxed.
- [ ] **`.inactive` must NOT tear down (W3 fix):** pull Control Center / the
      notification shade partway (app goes `.inactive`, not `.background`) → the
      session must **stay attached**. Fully backgrounding is the only trigger.

## 5. Reconnect self-heal on real network loss (W3 — `REMOTE-2.1` / `REMOTE-3.2`)

The mirror proves the *logic*; only real Wi-Fi proves the timing.

- [ ] Attach a session, then **sleep the Mac** (or drop the device off Wi-Fi and
      back on) mid-session → the client backs off and re-negotiates when the host
      returns, landing back in a live pane (this is the reconnect path W5
      un-latented via the `sshInstallStarted` reset — verify a *second* SSH
      install actually happens on reconnect, not a dead DataChannel).
- [ ] **Sleeping-host fallback:** with the host asleep past the signaling
      timeout, the client falls back to `/ws` (or surfaces a clean "host
      unavailable") within the ~10 s signaling window + cooldown, without
      spinning.

## 6. Second-device fallback to `/ws` (W3/W4 — `HostError.busy`, single-connection non-goal)

The host agent is **single-connection by design**; a second SSH client must fall
back, not fail.

- [ ] Device A attached over SSH-over-WebRTC. Device B (the other phone/iPad)
      connects to the *same* host → B receives `HostError.busy` (503) and
      **gracefully falls back to `/ws`** (confirm the busy warning in the log and
      that B lands in a working terminal via `/ws`).
- [ ] Detach A → B can subsequently upgrade/re-negotiate to SSH on its next
      attach (host agent frees up).

## 7. Revoke-while-attached drops the live session (W4 — `REMOTE-3.1` / `REMOTE-3.3`)

- [ ] Pair a device and attach a live SSH session. On the Mac, **Remove** that
      device from Settings → the live session **drops immediately** (not at the
      next reconnect). Confirm the peer is gone and a re-attach requires
      re-pairing.
- [ ] **Double-tap guard (W4):** rapidly tap Remove twice → no crash, no
      duplicate revoke, the row disappears once.

## 8. Browser `/ws` regression (W2/W5 — `REMOTE-5.1` / `REMOTE-5.2`)

`/ws` was **kept**, routed through the shared ownership core — prove it didn't
regress.

- [ ] Open the web terminal in a browser → auth gate challenges, then a live
      terminal.
- [ ] Ownership + take-control work from the browser exactly as before the
      program (the browser is now a client of the same shared core).

## 9. Real-host ↔ real-client codec parity (W5 — `StdErrControlFraming`)

The loopback suites cross-check the `<u32 BE len><UTF-8 JSON>` control-frame
wire format against a **mirror**, not a real peer.

- [ ] Exercising §3 (take-control) and §7 (revoke) over a *real* connection
      implicitly proves the shared `GrafttyProtocol.StdErrControlFraming` codec
      round-trips host↔client with no drift — confirm control envelopes
      (ownership changes, revoke notices) are delivered and acted on, not
      silently dropped or mis-framed.

---

## Sign-off

- [ ] All sections pass on **iPhone + Mac**.
- [ ] All sections pass on **iPad + Mac**.
- [ ] `/ws` browser regression (§8) clean.
- [ ] App-switch latency (§4) recorded and judged acceptable — or a follow-up
      filed to relax `IPAD-5.1`.

Deferred engineering follow-ups (not blockers for this gate) are tracked in
[`docs/superpowers/webrtc-wrapup-followups.md`](superpowers/webrtc-wrapup-followups.md).

# zmx Web Access — Manual Smoke Checklist

Run before each release that touches the web access feature (§15).

---

### Step 1 — Basic couch-terminal flow

Enable web access in Settings. Open a pane in Espalier. Right-click its row →
"Copy web URL". The URL will be of the form `http://<tailscale-ip>:8799/session/<name>`.
Open it in Safari on your phone (same tailnet). Pane renders. Type on phone →
echo on Mac. Type on Mac → echo on phone. Resize phone's browser width → shell
`stty size` reflects the new cols.

### Step 1.5 — Native text selection (new for wterm)

In Safari on the phone, long-press a word of terminal output. A **native**
iOS text-selection handle should appear (not a canvas-rendered
pseudo-selection). Copy the selected text; paste into another app; confirm
the bytes match what was on screen. Validates the core UX reason for
adopting wterm.

### Step 2 — Off-tailnet reachability

From a Mac outside the tailnet, paste the same URL → connection timeout
(tailnet routing prevents reachability).

### Step 3 — Non-owner 403

From a second tailnet peer logged in as a different user, paste the URL →
Safari shows `403 Forbidden`.

### Step 4 — Disable web access

In Settings, disable web access. Safari on phone → connection refused.

### Step 5 — Tailscale unavailable

Quit Tailscale from the menu bar. Relaunch Espalier (web access still
enabled). Settings pane shows "Tailscale unavailable"; no port is bound
(verify with `lsof -i :8799`).

### Step 6 — Detach without killing pane

Close the browser tab while a long-running command is in progress
(`sleep 30`). Verify on Mac: command continues to run; native pane is
unaffected. Reopen browser via `/session/<name>` — output is still
streaming.

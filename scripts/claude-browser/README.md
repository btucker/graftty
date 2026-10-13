# Claude MCP browser handoff regression

Claude Code 2.1.296 already sends MCP OAuth URLs through Graftty's managed
`open` command on macOS. No Claude wrapper, native binary patch, or new opt-in
is needed when the session inherited the managed PATH, `GRAFTTY_SOCK`, and
`ZMX_SESSION`, and has no explicit browser override. The installed managed
`open` in the tested agent session met these conditions.

The native opener uses the attached client's browser setting when present,
then `BROWSER`, then `open`. An explicit `BROWSER` remains the user's choice.
A session whose inherited PATH predates Graftty's managed `open` needs a new
session or an explicit launch environment. This regression does not change
running sessions or the system default browser.

## Run

Requires macOS, Python 3.10+, Google Chrome in `/Applications`, and the native
Claude executable. It was exercised with Claude Code **2.1.296**. TUI labels
and credential backend details are version dependent.

```sh
python3 scripts/claude-browser/test-oauth.py /Users/btucker/.local/bin/claude success
python3 scripts/claude-browser/test-oauth.py /Users/btucker/.local/bin/claude wrong-state
python3 scripts/claude-browser/test-oauth.py /Users/btucker/.local/bin/claude denied
python3 scripts/claude-browser/test-oauth.py /Users/btucker/.local/bin/claude success --reauth
python3 scripts/claude-browser/test-oauth.py /Users/btucker/.local/bin/claude wrong-state --reauth
python3 scripts/claude-browser/test-oauth.py /Users/btucker/.local/bin/claude denied --reauth
python3 scripts/claude-browser/test-oauth.py /Users/btucker/.local/bin/claude success --custom-browser
python3 scripts/claude-browser/test-oauth.py /Users/btucker/.local/bin/claude success --no-browser
```

`--tui` tests the initial `/mcp` authentication menu. `--reauth` authenticates
successfully through that menu, reopens `/mcp`, selects **Re-authenticate**,
and runs the requested callback case in the same native TUI session.

Each successful attempt checks the original authorization URL against Claude's
terminal link and Chrome's request, then checks state presence, S256 PKCE,
client ID, redirect URI, native token exchange, token persistence in the fake
keychain, and native completion text. Each exchange issues a distinct token;
TUI attempts must also reconnect to MCP using the newly issued token. Re-authentication also requires new
state and PKCE values. The test checks that handoff alone has not completed
OAuth before launching Chrome.

A wrong-state callback must render Claude's invalid-state browser page,
exchange no token, save no token, and report no success. Claude keeps that
attempt waiting for a valid callback. Consent denial must produce an
authentication failure without saving or exchanging a token. During failed
re-authentication, Claude 2.1.296 can retain the prior cached `Auth: authenticated`
label alongside `OAuth error: access_denied`. The fixture checks the new
completion message and stored tokens, so that stale label cannot count as success.

The explicit-browser case verifies `BROWSER` takes precedence over managed
`open`. The `--no-browser` case verifies Claude prints the URL without calling
an opener; the fixture then navigates that URL to complete the native flow.
The official [Claude MCP documentation](https://code.claude.com/docs/en/mcp#authenticate-with-remote-mcp-servers)
describes the interactive authentication and CLI login paths.

## Verified results

All eight commands above passed on 2026-10-12 with native Claude 2.1.296.
The three `--reauth` runs each included a successful initial TUI login before
the requested re-authentication outcome. Python syntax validation and
`python3 scripts/generate-specs.py --check` also passed. No Swift source or
spec changed, so this work did not rebuild SwiftPM or consume its shared cache.

## Isolation and evidence

The fixture creates a private directory under `/private/tmp`, passes an
allowlist of environment variables, and uses fresh `HOME`, `CLAUDE_CONFIG_DIR`,
and `CLAUDE_SECURESTORAGE_CONFIG_DIR` directories. It never copies user settings
or tokens. A PATH `security` stub stores synthetic credentials only in that
fixture directory. It accepts only Claude service names with the temporary
config directory's hash suffix and never calls the system keychain utility.

The Claude process also runs under `sandbox-exec`, which blocks external
network connections, the real `security` and `open` executables, and the
caller's Claude credential and keychain paths. Its API URL and MCP server both
point to the fixture's loopback HTTP server. Chrome uses a dedicated headless
profile, disables background networking, and uses its mock keychain.

The small `openWrapperScript` Swift literal is rendered directly from
`AgentHookInstaller.swift`; only its Graftty executable is replaced by an
argument recorder. The renderer refuses unknown Swift escapes or
interpolations. Existing `PORTS-5.36` covers the production wrapper's routing
and native fallback behavior. No production behavior or spec was changed.

The printed evidence directory contains `receipt.json`, `terminal.raw`,
`requests.json`, browser output, and fake keychain calls. It contains only
fixture credentials and URLs. Child processes are stopped and the Chrome
profile is removed when the test exits.

## What this proves

These runs exercise the installed native Claude CLI and actual `/mcp`
Re-authenticate UI through the existing Graftty `open` wrapper, followed by a
real browser callback and native OAuth completion. The downstream Graftty CLI
is an argument recorder. This does **not** test a live offer enqueue, viewer
selection, remote Chrome controls, or Local Safari callback forwarding. Those
remain the browser integration's tests. In particular, a Local Safari viewer
must get the callback back to the host listener; opening its `localhost` URL
on another device alone cannot complete this flow.

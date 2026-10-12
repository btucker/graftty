# Route Codex MCP login to a phone

Build the optional browser-hook TUI when Codex's `/mcp login` opens the Mac browser through native APIs. This requires macOS, Git, Python 3, and Rust toolchain 1.95.0.

1. Install a Graftty build containing `PORTS-5.41` and `PORTS-5.42`.
2. Build the pinned Codex 0.162.1 TUI into Graftty's managed directory:

```sh
scripts/codex-browser/build.sh /tmp/graftty-codex-browser-cache \
	"$HOME/Library/Application Support/Graftty/agent-hooks/codex-browser"
```

3. Exit the affected Codex TUI and resume its exact thread through Graftty's `codex` wrapper.
4. Connect the phone, take ownership of the pane, and run `/mcp login cloudflare`. The helper offers the authorization URL to the owning phone. A build with the dedicated Chrome authorization integration opens the original URL in that pane's host Chrome profile and presents its viewer on the phone. Chrome follows the loopback callback on the Mac; the URL and OAuth state are not rewritten.

The build records source commit, patch fingerprint, binary hash, and dependency lock hash in `BUILD.json`. It changes the common TUI browser helper. Graftty continues to run the installed native Codex app-server, which owns OAuth state, cancellation, token exchange, credential storage, and completion notifications.

The wrapper selects the managed TUI only for its own pane sessions and only when its version matches the installed native Codex. Explicit `--remote` commands, administration commands, and launches outside a pane retain the original TUI. After an upstream Codex update, a version mismatch prints a warning and uses the original TUI. Update the source pin and verify the hook before building for another version.

The configured helper receives the original URL as one argument and enqueues a Graftty offer. A successful handoff does not indicate OAuth success. A failed handoff produces a TUI error and does not open the Mac browser. Handoff work runs off the TUI event loop with an eight-second timeout. Quitting during a stalled handoff can wait for that timeout.

To disable the hook for future sessions, remove the managed `codex-browser/codex` executable. Existing Codex processes retain their current executable until restarted.

## Verify the OAuth path without using an account

Run the optional smoke test with the patched TUI and the original native Codex binary. Google Chrome must be installed at its standard macOS location.

```sh
python3 scripts/codex-browser/test-oauth.py /path/to/patched/codex /path/to/native/codex success
python3 scripts/codex-browser/test-oauth.py /path/to/patched/codex /path/to/native/codex wrong-state
python3 scripts/codex-browser/test-oauth.py /path/to/patched/codex /path/to/native/codex denied
```

Each invocation creates a private temporary Codex home, a local mock OAuth/MCP server, and a dedicated headless Chrome profile. It types `/mcp login fixture` into the patched TUI, captures the original authorization URL through the helper, and navigates Chrome to that URL. The successful case checks the real app-server token exchange, PKCE verifier, redirect URI, and the TUI's actual login-completion message. Wrong-state and denied-consent cases use separate attempts and require an error with no token exchange.

The fixture preserves its logs and receipt in the printed temporary directory and removes its Chrome profile. It does not use live provider credentials, restart existing agents, or prove the WebRTC viewer/physical phone path. Those require a separate integrated test. A running stock Codex TUI cannot acquire the hook in place; it must be resumed under the managed launcher after activation.

## Dedicated Chrome prototype limits

Each dedicated worktree profile retains at most 128 sign-in launch receipts, including uncertain dispatches. Receipts are private profile data and survive viewer disconnects and host app restarts. The prototype refuses new sign-in offers at that limit instead of evicting history and risking repeated OAuth navigation. Existing tab browsing and explicit URL launches remain available.

If Chrome may have received a launch but its result is unknown, select the existing sign-in tab in the viewer. Retrying that offer never creates another tab. Leaving the viewer or reconnecting preserves host tabs and the original host-local callback.

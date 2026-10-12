# Route Codex MCP login to a phone

Build the optional browser-hook TUI when Codex's `/mcp login` opens the Mac browser through native APIs. This requires macOS, Git, Python 3, and Rust toolchain 1.95.0.

1. Install a Graftty build containing `PORTS-5.41` and `PORTS-5.42`.
2. Build the pinned Codex 0.162.1 TUI into Graftty's managed directory:

```sh
scripts/codex-browser/build.sh /tmp/graftty-codex-browser-cache \
	"$HOME/Library/Application Support/Graftty/agent-hooks/codex-browser"
```

3. Exit the affected Codex TUI and resume its exact thread through Graftty's `codex` wrapper.
4. Connect the phone, take ownership of the pane, and run `/mcp login cloudflare`. The authorization page opens on the phone. Its loopback callback returns through the existing WebRTC tunnel.

The build records source commit, patch fingerprint, binary hash, and dependency lock hash in `BUILD.json`. It changes the common TUI browser helper. Graftty continues to run the installed native Codex app-server, which owns OAuth state, cancellation, token exchange, credential storage, and completion notifications.

The wrapper selects the managed TUI only for its own pane sessions and only when its version matches the installed native Codex. Explicit `--remote` commands, administration commands, and launches outside a pane retain the original TUI. After an upstream Codex update, a version mismatch prints a warning and uses the original TUI. Update the source pin and verify the hook before building for another version.

The configured helper receives the original URL as one argument and enqueues a Graftty offer. A successful handoff does not indicate OAuth success. A failed handoff produces a TUI error and does not open the Mac browser. Handoff work runs off the TUI event loop with an eight-second timeout. Quitting during a stalled handoff can wait for that timeout.

To disable the hook for future sessions, remove the managed `codex-browser/codex` executable. Existing Codex processes retain their current executable until restarted.

// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("WEB — pending specs")
struct WebTodo {
    @Test("""
@spec WEB-1.1: When web access is enabled, the application shall bind a local HTTPS server to each Tailscale IPv4 and IPv6 address reported by the Tailscale LocalAPI, on the user-configured port (default 8799). The application shall not bind to `127.0.0.1`.
""", .disabled("not yet implemented"))
    func web_1_1() async throws { }

    @Test("""
@spec WEB-1.2: The application shall not bind to `0.0.0.0`.
""", .disabled("not yet implemented"))
    func web_1_2() async throws { }

    @Test("""
@spec WEB-1.3: If no Tailscale addresses are available, the application shall not bind the server and shall surface a "Tailscale unavailable" status in the Settings pane.
""", .disabled("not yet implemented"))
    func web_1_3() async throws { }

    @Test("""
@spec WEB-1.4: The feature shall be off by default.
""", .disabled("not yet implemented"))
    func web_1_4() async throws { }

    @Test("""
@spec WEB-1.6: When resolving the Tailscale LocalAPI, the application shall try Unix domain socket endpoints first (OSS / sandboxed App Store installs) and, if none are reachable, shall fall back to the macsys DMG's TCP endpoint by reading the port from `/Library/Tailscale/ipnport` (file or symlink) and the auth token from `/Library/Tailscale/sameuserproof-<port>`.
""", .disabled("not yet implemented"))
    func web_1_6() async throws { }

    @Test("""
@spec WEB-1.8: The diagnostic "Listening on …" row in the Settings pane shall bracket IPv6 hosts per RFC 3986 authority syntax (e.g., `[fd7a:115c::5]:8799`). Copyable URLs (Settings Base URL, sidebar "Copy web URL") no longer contain IP literals — they use the MagicDNS FQDN (WEB-8.1) — so this bracketing rule applies only to the diagnostic list. `WebURLComposer.authority(host:port:)` owns the bracket logic.
""", .disabled("not yet implemented"))
    func web_1_8() async throws { }

    @Test("""
@spec WEB-1.9: When `WebURLComposer.url(session:host:port:)` percent-encodes the session name for interpolation into the URL path, it shall use `CharacterSet.urlPathAllowed` rather than `urlQueryAllowed`. The latter leaves reserved path/query/fragment separators (`?`, `#`) unescaped, so a session name containing `?` would cause the browser to parse the URL as path-and-query and the client router would see only the prefix. Graftty's own session names per `ZMX-2.1` never include such characters, but socket clients producing custom session names would otherwise silently break.
""", .disabled("not yet implemented"))
    func web_1_9() async throws { }

    @Test("""
@spec WEB-1.11: When the server fails to bind because the configured port is already in use (EADDRINUSE), the application shall surface the status as `.portUnavailable` — rendered as "Port in use" in the Settings pane — rather than the raw NIO error string (`"bind(descriptor:ptr:bytes:): Address already in use) (errno: 48)"`). Recognition is locale-stable: classify by the bridged `NSPOSIXErrorDomain` + `EADDRINUSE` errno code, with the NIO string-match kept as a secondary path. Both `WebServer.start` and `WebServerController` use a single shared `WebServer.isAddressInUse(_:)` classifier so they cannot drift on recognising the same error.
""", .disabled("not yet implemented"))
    func web_1_11() async throws { }

    @Test("""
@spec WEB-1.12: While the server is listening, the Settings pane shall render a **Base URL** row distinct from the diagnostic "Listening on" row. The Base URL is the HTTPS URL composed from the machine's MagicDNS FQDN (WEB-8.1) and the listening port — the URL a user copies to open the web client. It renders as a clickable `Link` opening the default browser, plus a copy button (`doc.on.doc`, accessible label "Copy URL") that writes to `NSPasteboard.general`. The "Listening on" row below is informational (which sockets are actually up) and must not be conflated with the Base URL. Plain selectable text is not sufficient for the Base URL — users were expected to triple-click, copy, then switch apps and paste (four steps for one ask).
""", .disabled("not yet implemented"))
    func web_1_12() async throws { }

    @Test("""
@spec WEB-1.13: While the server is listening, the Settings pane shall render a 160 pt QR code inline beneath the Base URL row, encoding the Base URL so that an iOS client can scan it on first run to add a saved host. Alongside the QR, the pane shall render a one-sentence usage hint ("Scan with Graftty") so a reader who has never onboarded a phone before knows what the code is for. Hiding it behind a disclosure is rejected on discoverability grounds: a user who has Web Access on has almost certainly enabled it to onboard a phone, and the QR is the payoff for that action. When the server is not listening, the Base URL row (and therefore the QR) is not rendered at all, per the existing status-gated layout.
""", .disabled("not yet implemented"))
    func web_1_13() async throws { }

    @Test("""
@spec WEB-2.1: The application shall resolve each incoming peer IP via Tailscale LocalAPI `whois` before serving any content at any path.
""", .disabled("not yet implemented"))
    func web_2_1() async throws { }

    @Test("""
@spec WEB-2.2: The application shall accept a connection only when the resolved `UserProfile.LoginName` equals the current Mac's Tailscale `LoginName`.
""", .disabled("not yet implemented"))
    func web_2_2() async throws { }

    @Test("""
@spec WEB-2.3: When `whois` fails or the resolved LoginName differs, the application shall respond with HTTP `403 Forbidden`.
""", .disabled("not yet implemented"))
    func web_2_3() async throws { }

    @Test("""
@spec WEB-2.4: When Tailscale is not running, the application shall refuse all incoming connections (the server is not bound; connections are refused at TCP).
""", .disabled("not yet implemented"))
    func web_2_4() async throws { }

    @Test("""
@spec WEB-2.5: _(Removed; superseded by WEB-1.1.)_ The prior loopback-bypass carve-out existed because `WEB-1.1` bound `127.0.0.1`; with that bind gone, local connections now arrive as Tailscale peers via the MagicDNS hostname (WEB-8.1) and are accepted under the normal `WEB-2.2` same-user check.
""", .disabled("not yet implemented"))
    func web_2_5() async throws { }

    @Test("""
@spec WEB-3.1: The application shall serve a single static page at `/` (and `/index.html`) that bootstraps the bundled web client.
""", .disabled("not yet implemented"))
    func web_3_1() async throws { }

    @Test("""
@spec WEB-3.2: When a client requests any path that does not match a bundled
""", .disabled("not yet implemented"))
    func web_3_2() async throws { }

    @Test("""
@spec WEB-3.3: The application shall upgrade `/ws?session=<name>` to WebSocket after the authorization check passes.
""", .disabled("not yet implemented"))
    func web_3_3() async throws { }

    @Test("""
@spec WEB-3.4: WebSocket binary frames shall carry raw PTY bytes in both directions.
""", .disabled("not yet implemented"))
    func web_3_4() async throws { }

    @Test("""
@spec WEB-3.5: WebSocket text frames shall carry JSON control envelopes. The only Phase 2 envelope shape shall be `{"type":"resize","cols":<uint16>,"rows":<uint16>}`.
""", .disabled("not yet implemented"))
    func web_3_5() async throws { }

    @Test("""
@spec WEB-3.6: When the application responds to an HTTP request with `Connection: close`, it shall transmit exactly the number of body bytes declared in its `Content-Length` header to the client before closing the TCP connection, so clients never observe a truncated response (`ERR_CONTENT_LENGTH_MISMATCH`). This requirement applies even on links (e.g., Tailscale `utun`, MTU ~1280) whose kernel TCP send buffer cannot absorb the full response in a single non-blocking write.
""", .disabled("not yet implemented"))
    func web_3_6() async throws { }

    @Test("""
@spec WEB-4.1: When the user enables web access in Settings, the application shall probe Tailscale, bind, and transition status to `.listening(...)` or an error status.
""", .disabled("not yet implemented"))
    func web_4_1() async throws { }

    @Test("""
@spec WEB-4.2: When the user disables web access, the application shall close all listening sockets and terminate all in-flight `zmx attach` children spawned for the web.
""", .disabled("not yet implemented"))
    func web_4_2() async throws { }

    @Test("""
@spec WEB-4.3: When the application quits, the application shall stop the server (same tear-down as 15.4.2) as part of normal shutdown.
""", .disabled("not yet implemented"))
    func web_4_3() async throws { }

    @Test("""
@spec WEB-4.4: For each incoming WebSocket, the application shall spawn one child `zmx attach <session>` whose PTY it owns (per §13 naming and ZMX_DIR rules from Phase 1).
""", .disabled("not yet implemented"))
    func web_4_4() async throws { }

    @Test("""
@spec WEB-4.5: When a WebSocket closes, the application shall send SIGTERM to the associated `zmx attach` child, leaving the zmx daemon alive.
""", .disabled("not yet implemented"))
    func web_4_5() async throws { }

    @Test("""
@spec WEB-4.6: When the application forks a `zmx attach` child for a web WebSocket, the child shall close every inherited file descriptor above 2 before `execve`. Rationale: without this, parent-opened sockets (notably the `WebServer` listen socket) without `FD_CLOEXEC` leak into the zmx child and survive the parent. After Graftty quits, the listen port stays bound to an orphan zmx process and the next Graftty launch cannot rebind.
""", .disabled("not yet implemented"))
    func web_4_6() async throws { }

    @Test("""
@spec WEB-4.7: When the application transitions the forked child into `zmx attach`, the final `execve` shall be performed via `posix_spawn` with `POSIX_SPAWN_SETEXEC | POSIX_SPAWN_SETSIGMASK` and an empty initial signal mask. `fork(2)` preserves the parent's sigmask and plain `execve(2)` carries it across — and the Swift runtime (GCD/Dispatch) blocks a family of signals on its service threads, so a child inheriting that mask starts with SIGWINCH blocked. `zmx attach` installs a SIGWINCH handler to forward PTY resize events to the daemon; if SIGWINCH is blocked the handler never fires, the kernel sets the signal pending, and WebSocket-sent resize events silently vanish until an unrelated signal or explicit unblock drains them. The spawn-level mask reset is the kernel-boundary fix that guarantees the exec'd image starts with every signal unblocked.
""", .disabled("not yet implemented"))
    func web_4_7() async throws { }

    @Test("""
@spec WEB-5.1: The bundled client shall render a single terminal (ghostty-web, a WASM build of libghostty — the same VT parser as the native app pane) that attaches to the session indicated by the `/session/<name>` URL path. If a client arrives at the root path `/` with a `?session=<name>` query parameter, the client shall redirect to `/session/<name>` (backward compatibility). Sharing a parser with the native pane is what keeps escape-sequence behavior (cursor movement, SGR state, OSC 8 hyperlinks, scrollback) identical across clients.
""", .disabled("not yet implemented"))
    func web_5_1() async throws { }

    @Test("""
@spec WEB-5.2: The client shall send terminal data events as binary WebSocket frames.
""", .disabled("not yet implemented"))
    func web_5_2() async throws { }

    @Test("""
@spec WEB-5.3: The client shall send resize events as JSON control envelopes in text frames, including an initial resize sent on WebSocket open so the server-side PTY is sized to the client's actual viewport rather than the `zmx attach` default.
""", .disabled("not yet implemented"))
    func web_5_3() async throws { }

    @Test("""
@spec WEB-5.4: When a client requests `GET /sessions`, the application shall respond with a JSON array of the currently-running sessions, one entry per live pane across all running worktrees, with fields `name` (the zmx session name derived per `ZMX-2.1`), `worktreePath`, `repoDisplayName`, and `worktreeDisplayName`. The bundled client's root page (`/`) shall fetch this endpoint and render a clickable picker grouped by `repoDisplayName`, so a user who visits the server's root URL without a session query gets a functional entry point rather than a bare "no session" placeholder. Access to `/sessions` shall be gated by the same Tailscale-whois authorization as every other path (`WEB-2.1` / `WEB-2.2`).
""", .disabled("not yet implemented"))
    func web_5_4() async throws { }

    @Test("""
@spec WEB-5.5: The client shall size the terminal grid to fill the host element using the renderer's font metrics (`cols = floor(host.clientWidth / metrics.width)`, `rows = floor(host.clientHeight / metrics.height)`) and shall not reserve any horizontal pixels for a native scrollbar, so the canvas occupies the full viewport width and the PTY column count matches the visible grid. Rationale: ghostty-web's bundled `FitAddon` unconditionally subtracts 15 px from available width for a DOM scrollbar (`proposeDimensions()` in `ghostty-web.js`), but Ghostty renders its scrollback scrollbar as a canvas overlay — using `FitAddon` leaves a ~15 px gap on the right edge and narrows wrapping (e.g., 148 cols instead of 150 on a 1200 px viewport with 8 px cells).
""", .disabled("not yet implemented"))
    func web_5_5() async throws { }

    @Test("""
@spec WEB-5.7: On mobile browsers the client shall (a) translate a single-finger vertical drag on the terminal host into `term.scrollLines(-deltaLines)` so scrollback is reachable without a hardware wheel (ghostty-web's built-in scrolling is wheel-only and mobile browsers do not synthesize wheel events from single-finger drag); and (b) size the terminal host to `window.visualViewport.{width,height}` (fallback `window.innerWidth/Height`), updating on `visualViewport` `resize` and `scroll` events, so when the software keyboard opens the host shrinks to the remaining visible area and the existing ResizeObserver refits `(cols, rows)` — keeping the cursor row above the keyboard rather than occluded beneath it. Taps shorter than one character-cell of movement shall still reach the terminal's own focus handler (which shows the mobile keyboard); multi-touch gestures (pinch, two-finger pan) shall pass through untouched. The terminal host shall declare `touch-action: none` and `overscroll-behavior: none` so the browser doesn't interpret the drag as page-scroll/pan/zoom or rubber-band the viewport before our handler sees the event.
""", .disabled("not yet implemented"))
    func web_5_7() async throws { }

    @Test("""
@spec WEB-5.8: While the user is viewing scrollback on the normal screen (i.e., `term.viewportY > 0`), incoming PTY output shall not move the viewport: the client shall capture `viewportY` and scrollback length immediately before each `term.write()` call and, after the write, re-apply `viewportY` shifted by the number of lines that scrolled into scrollback so the viewport stays pinned to the same absolute content rather than the same offset-from-bottom. While the alternate screen is active on either side of the write, the viewport shall be left at the library-default bottom position. Rationale: ghostty-web's `Terminal.writeInternal` unconditionally calls `scrollToBottom()` whenever `viewportY !== 0` at write time, so without this wrapper the viewport snaps to the newest output on every WebSocket data frame — making wheel/touch scrollback unusable on any session that is actively producing output. Pinning to absolute content (not offset) is what lets the user read older lines while the shell continues to print.
""", .disabled("not yet implemented"))
    func web_5_8() async throws { }

    @Test("""
@spec WEB-6.1: The web server shall bind HTTPS only, using a cert+key pair fetched from Tailscale LocalAPI for the machine's MagicDNS name (WEB-8.2). The application shall not bind any HTTP listener; clients with old `http://` bookmarks will fail to connect until they update the URL.
""", .disabled("not yet implemented"))
    func web_6_1() async throws { }

    @Test("""
@spec WEB-6.2: Phase 2 shall not implement multi-pane layout, mouse events, OSC 52 clipboard sync, or reboot survival. (A minimal session-list picker is provided by `WEB-5.4`; worktree creation is provided by `WEB-7`.)
""", .disabled("not yet implemented"))
    func web_6_2() async throws { }

    @Test("""
@spec WEB-6.3: Phase 2 shall not implement rate limiting, URL tokens, or cookies; authorization shall be via Tailscale WhoIs only.
""", .disabled("not yet implemented"))
    func web_6_3() async throws { }

    @Test("""
@spec WEB-7.1: When a client requests `GET /repos`, the application shall respond with a JSON array of the currently-tracked repositories (one entry per top-level `RepoEntry` in `AppState.repos`) with fields `path` (opaque absolute path round-tripped on `POST /worktrees`) and `displayName` (matching the native sidebar's top-level label). Access is gated by the same Tailscale-whois authorization (`WEB-2.1` / `WEB-2.2`).
""", .disabled("not yet implemented"))
    func web_7_1() async throws { }

    @Test("""
@spec WEB-7.2: When a client sends `POST /worktrees` with a JSON body `{repoPath, worktreeName, branchName}`, the application shall create a new worktree under `<repoPath>/.worktrees/<worktreeName>` on a fresh branch named `<branchName>`, starting from the repo's resolved default branch (same `GitOriginDefaultBranch` resolution the native sheet uses); discover the new worktree into `AppState.repos` so it appears in the sidebar immediately; spawn its first ghostty surface via the same `TerminalManager.createSurfaces` path the native sheet uses; and respond with `200` and `{sessionName, worktreePath}`. The `sessionName` is the `ZMX-2.1`-derived name of the first leaf, suitable for use as `/session/<sessionName>`.
""", .disabled("not yet implemented"))
    func web_7_2() async throws { }

    @Test("""
@spec WEB-7.3: The application shall reject `POST /worktrees` requests with invalid JSON, missing fields, or whitespace-only `worktreeName`/`branchName` with `400 Bad Request` and a JSON `{error: "<message>"}` body. `GET /worktrees` and other verbs shall return `405 Method Not Allowed`. Request bodies exceeding 64 KiB shall return `413 Payload Too Large` before any creator is invoked.
""", .disabled("not yet implemented"))
    func web_7_3() async throws { }

    @Test("""
@spec WEB-7.4: When `git worktree add` fails (branch already exists, path already in use, fatal ref-format rejection, etc.), the application shall respond `409 Conflict` with the captured stderr as `{error: "<stderr>"}`. When post-git discovery or surface creation fails, the application shall respond `500 Internal Server Error` with the underlying message. The web-created worktree shall not leave the Mac's `AppState` holding a half-materialized entry: either the entry appears in `.running` state with a surface, or not at all.
""", .disabled("not yet implemented"))
    func web_7_4() async throws { }

    @Test("""
@spec WEB-7.5: The native Mac window's `selectedWorktreePath` shall not change as a side effect of a web-initiated `POST /worktrees`. Rationale: remote-creating a worktree from an iPad should not yank the local user's Mac window focus away from whatever they are currently doing. The new worktree still appears in the sidebar (via `WEB-7.2`'s discovery step) and a running pane is visible there.
""", .disabled("not yet implemented"))
    func web_7_5() async throws { }

    @Test("""
@spec WEB-7.6: The bundled web client shall expose an "Add worktree" entry point on its root page that routes to `/new`. `/new` shall render a form containing (a) a repository picker populated from `GET /repos` (hidden when only one repo is tracked), (b) a worktree-name field, (c) a branch-name field defaulting to mirror the worktree-name field until the user types a differing branch name. Both name fields shall sanitize input live to the same allowed set as the native sheet (`A-Z a-z 0-9 . _ - /`, consecutive disallowed chars collapsing to a single `-`) and shall trim whitespace plus leading/trailing `-` / `.` at submit time. On successful `POST /worktrees` the client shall navigate to `/session/<sessionName>`; on failure it shall display the server's `error` message inline next to the form.
""", .disabled("not yet implemented"))
    func web_7_6() async throws { }

    @Test("""
@spec WEB-7.7: When `AppState.repos` is empty (no repositories tracked yet), the `/new` route shall render an empty-state message directing the user to open a repository in the native Graftty app first, with a back-link to `/`. The web client shall not implement repository-adding (the Mac-side file dialog + security-scoped bookmark mint has no web equivalent in Phase 2).
""", .disabled("not yet implemented"))
    func web_7_7() async throws { }

    @Test("""
@spec WEB-8.1: When binding the HTTPS server, the application shall read `Self.DNSName` from Tailscale LocalAPI `/status`, strip the trailing dot, and use the resulting FQDN as the TLS SNI name and as the hostname in every composed Base URL / session URL. If `DNSName` is absent or empty, the application shall enter `.magicDNSDisabled` status and not bind. Settings shall render a "MagicDNS must be enabled on your tailnet" message plus a link to `https://login.tailscale.com/admin/dns`.
""", .disabled("not yet implemented"))
    func web_8_1() async throws { }

    @Test("""
@spec WEB-8.3: While the server is listening, the application shall re-fetch the cert every 24 hours. If the returned PEM bytes differ from the currently-serving material, the application shall construct a new `NIOSSLContext` and atomically swap the reference read by the per-channel `ChannelInitializer` via `WebTLSContextProvider.swap(_:)`. The application shall not close the listening socket and shall not disturb in-flight connections — existing WebSocket streams keep their prior context for their lifetime.
""", .disabled("not yet implemented"))
    func web_8_3() async throws { }

    @Test("""
@spec WEB-8.4: For `.magicDNSDisabled` and `.httpsCertsNotEnabled`, the Settings pane shall render a human-readable explanation plus a SwiftUI `Link` to the relevant Tailscale admin page (`https://login.tailscale.com/admin/dns`). For `.certFetchFailed`, it shall render the underlying message plus a note that Graftty retries automatically.
""", .disabled("not yet implemented"))
    func web_8_4() async throws { }
}

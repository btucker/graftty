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
@spec WEB-1.8: The diagnostic "Listening on …" row in the Settings pane shall bracket IPv6 hosts per RFC 3986 authority syntax (e.g., `[fd7a:115c::5]:8799`). Copyable URLs (Settings Base URL, sidebar "Copy web URL") no longer contain IP literals — they use the MagicDNS FQDN (WEB-8.1) — so this bracketing rule applies only to the diagnostic list. `WebURLComposer.authority(host:port:)` owns the bracket logic.
""", .disabled("not yet implemented"))
    func web_1_8() async throws { }

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
@spec WEB-7.2: When a client sends `POST /worktrees` with a JSON body `{repoPath, worktreeName, branchName}`, the application shall create a new worktree under `<repoPath>/.worktrees/<worktreeName>` on a fresh branch named `<branchName>`, starting from the repo's resolved default branch (same `GitOriginDefaultBranch` resolution the native sheet uses); discover the new worktree into `AppState.repos` so it appears in the sidebar immediately; spawn its first ghostty surface via the same `TerminalManager.createSurfaces` path the native sheet uses; and respond with `200` and `{sessionName, worktreePath}`. The `sessionName` is the `ZMX-2.1`-derived name of the first leaf, suitable for use as `/session/<sessionName>`.
""", .disabled("not yet implemented"))
    func web_7_2() async throws { }

    @Test("""
@spec WEB-7.4: When `git worktree add` fails (branch already exists, path already in use, fatal ref-format rejection, etc.), the application shall respond `409 Conflict` with the captured stderr as `{error: "<stderr>"}`. When post-git discovery or surface creation fails, the application shall respond `500 Internal Server Error` with the underlying message. The web-created worktree shall not leave the Mac's `AppState` holding a half-materialized entry: either the entry appears in `.running` state with a surface, or not at all.
""", .disabled("not yet implemented"))
    func web_7_4() async throws { }

    @Test("""
@spec WEB-7.5: The native Mac window's `selectedWorktreePath` shall not change as a side effect of a web-initiated `POST /worktrees`. Rationale: remote-creating a worktree from an iPad should not yank the local user's Mac window focus away from whatever they are currently doing. The new worktree still appears in the sidebar (via `WEB-7.2`'s discovery step) and a running pane is visible there.
""", .disabled("not yet implemented"))
    func web_7_5() async throws { }

    @Test("""
@spec WEB-8.1: When binding the HTTPS server, the application shall read `Self.DNSName` from Tailscale LocalAPI `/status`, strip the trailing dot, and use the resulting FQDN as the TLS SNI name and as the hostname in every composed Base URL / session URL. If `DNSName` is absent or empty, the application shall enter `.magicDNSDisabled` status and not bind. Settings shall render a "MagicDNS must be enabled on your tailnet" message plus a link to `https://login.tailscale.com/admin/dns`.
""", .disabled("not yet implemented"))
    func web_8_1() async throws { }

    @Test("""
@spec WEB-8.4: For `.magicDNSDisabled` and `.httpsCertsNotEnabled`, the Settings pane shall render a human-readable explanation plus a SwiftUI `Link` to the relevant Tailscale admin page (`https://login.tailscale.com/admin/dns`). For `.certFetchFailed`, it shall render the underlying message plus a note that Graftty retries automatically.
""", .disabled("not yet implemented"))
    func web_8_4() async throws { }

    @Test("""
@spec WEB-8.6: While the cert pair fetch is in flight on "Enable web access", the application shall hold a `.provisioningCert` status, render a `ProgressView` plus "Provisioning certificate from Tailscale…" message in the Settings pane, and shall not block the MainActor for the duration of the fetch. On completion the status shall transition to `.listening` (success), `.httpsCertsNotEnabled` (tailnet-disabled), or `.certFetchFailed(<message>)` (any other error) without leaving the pane stuck on `.provisioningCert`.
""", .disabled("not yet implemented"))
    func web_8_6() async throws { }
}

# SSH Tunnel Access Design

## Summary

Graftty should keep supporting Tailscale, but it should not require Tailscale for users who already have SSH access to their Mac. Add an SSH tunnel access mode that lets the Mac app serve the existing web/mobile protocol on loopback only, while trusted clients reach it through SSH forwarding.

V1 has two client paths:

- **Graftty Mobile** manages the SSH connection itself. It generates an app-owned SSH key, asks the user to install the public key on the Mac, starts a local loopback proxy on iOS, and points the existing mobile HTTP/WebSocket clients at that local proxy.
- **Another Mac** uses a manual SSH local forward, then opens the forwarded local URL in a browser. Native Graftty-on-Mac remote browsing is explicitly out of scope for V1.

The existing `/worktrees/panes`, `/repos`, `/worktrees`, `/ghostty-config`, static web UI, and `/ws` protocol remain unchanged above the transport.

## Goals

- Allow Graftty Mobile to connect without Tailscale when the user already has SSH reachability to the serving Mac.
- Keep the serving Mac's Graftty web server off public and LAN interfaces in SSH mode.
- Preserve the existing web/mobile HTTP and WebSocket protocol.
- Support Mac-to-Mac access through a documented manual SSH tunnel and browser.
- Make SSH host-key pinning explicit and hard to bypass accidentally.
- Avoid importing arbitrary user SSH keys, password auth, or making Graftty a general SSH manager in V1.

## Non-Goals

- No built-in SSH server in Graftty.
- No automatic editing of `~/.ssh/authorized_keys`.
- No password authentication in V1.
- No imported private keys in V1.
- No native desktop Graftty remote-client mode in V1.
- No internet relay or NAT traversal service.
- No attempt to keep an iOS tunnel alive indefinitely in the background.

## Existing Context

Today the Mac-side `WebServerController` starts a HTTPS server for web/mobile access by:

- discovering Tailscale status through `TailscaleLocalAPI`;
- requiring MagicDNS and Tailscale HTTPS certificates;
- binding to Tailscale IPs;
- gating requests with Tailscale `WhoIs`;
- serving the current static web UI and JSON/WebSocket APIs.

Graftty Mobile already stores saved hosts by base URL and uses `URLSession` / `URLSessionWebSocketTask` against the existing endpoints. That makes SSH tunnel access mostly a transport change if the mobile app can produce a runtime local base URL.

## Architecture

Add a Mac-side web access mode:

```swift
enum WebAccessMode {
    case tailscale
    case sshTunnel
}
```

Tailscale mode keeps the current behavior:

```text
bind: Tailscale IPs
scheme: HTTPS
auth: Tailscale WhoIs owner check
URL: https://<magicdns-name>:<port>/
```

SSH tunnel mode changes the serving behavior:

```text
bind: 127.0.0.1 only
scheme: HTTP
auth: loopback-only
URL: http://127.0.0.1:<port>/
intended access: SSH local forwarding or SSH direct-tcpip
```

The serving Mac does not know whether the client is iOS or another Mac. It only exposes a loopback-only Graftty endpoint.

Graftty Mobile adds an SSH-backed host transport:

```swift
enum HostTransport {
    case directHTTP(baseURL: URL)
    case sshTunnel(SSHHostConfig)
}

struct SSHHostConfig: Codable, Sendable, Hashable {
    var sshHost: String
    var sshPort: Int
    var sshUsername: String
    var remoteGrafttyHost: String // V1 default: 127.0.0.1
    var remoteGrafttyPort: Int    // V1 default: 8799
}
```

When the user opens an SSH host, Graftty Mobile resolves it into a temporary runtime connection:

```swift
struct ResolvedHostConnection {
    let displayLabel: String
    let runtimeBaseURL: URL
    let close: @Sendable () async -> Void
}
```

For SSH hosts, `runtimeBaseURL` is a local ephemeral URL such as:

```text
http://127.0.0.1:49152/
```

Existing fetchers and WebSocket clients continue to receive a normal base URL.

## Mobile SSH Tunnel Flow

The iOS app owns the SSH tunnel for SSH-backed hosts:

```text
iPhone / iPad
  Graftty Mobile
    SSH connection to user@mac:22
      local app listener: 127.0.0.1:<ephemeral>
        accepted TCP connection
          SSH direct-tcpip channel to 127.0.0.1:8799 on Mac
            Graftty WebServer
              zmx attach
```

Connection sequence:

1. User selects an SSH host.
2. Mobile app shows a connecting state.
3. App opens SSH to `sshUsername@sshHost:sshPort`.
4. App verifies the server host key against the saved pin, or asks the user to trust it on first connect.
5. App authenticates with the generated app key.
6. App binds `127.0.0.1:0` and records the chosen local port.
7. App forwards each accepted local socket over an SSH `direct-tcpip` channel to `remoteGrafttyHost:remoteGrafttyPort`.
8. App navigates into the existing worktree/session UI using the runtime local base URL.

The tunnel should be scoped above the worktree and session screens. Individual screens should not create independent SSH connections.

## Mobile Key Generation And Onboarding

Graftty Mobile generates one app-owned SSH keypair the first time the user creates an SSH host. The private key is stored in the iOS Keychain and is not exportable through app UI. The public key is shareable.

Flow:

1. User taps `Add Host` -> `SSH`.
2. If no Graftty Mobile SSH key exists, the app generates one.
3. The app shows the public key with a Share button.
4. The user sends the public key to the Mac, for example with AirDrop.
5. The app shows setup instructions for the Mac.
6. The user enters SSH host, port, username, and Graftty port.
7. The app connects, pins the SSH host key, starts the local tunnel, and loads the existing mobile UI.

Suggested basic Mac setup instructions:

```sh
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cat ~/Downloads/graftty-mobile.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

If the user copied the public key manually:

```sh
mkdir -p ~/.ssh
chmod 700 ~/.ssh
echo '<public key>' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

The onboarding copy should be honest that this key grants SSH access to the selected account, not just Graftty access.

An advanced restricted-key form can be documented after verification against supported macOS OpenSSH versions:

```text
restrict,port-forwarding,permitopen="127.0.0.1:8799" ssh-ed25519 AAAA...
```

Do not make the restricted form the default until it is tested on current supported macOS versions.

## Host Key Trust

Host-key verification is required.

First connect:

- show hostname;
- show key type;
- show SHA256 fingerprint;
- ask the user to trust this Mac.

Later connects:

- require the host key to match the saved pin.

Changed host key:

- block the connection;
- show a changed-host-key error;
- allow replacing the pin only from an explicit host settings action.

The app should not provide a one-tap "continue anyway" from the connection error sheet.

## Mac-Side Server Behavior

`WebServerController` should choose behavior based on `WebAccessMode`.

Tailscale mode:

- auto-detect Tailscale LocalAPI;
- require MagicDNS name;
- fetch Tailscale HTTPS certs;
- bind Tailscale IPs;
- install TLS;
- gate with Tailscale `WhoIs`.

SSH tunnel mode:

- skip Tailscale LocalAPI entirely;
- skip certificate fetch/renewal;
- bind only `127.0.0.1`;
- serve HTTP;
- allow only loopback peer IPs in `AuthPolicy`.

The auth policy should still check loopback even though the bind address already narrows exposure:

```swift
WebServer.AuthPolicy { peerIP in
    peerIP == "127.0.0.1" || peerIP == "::1"
}
```

For V1, bind only IPv4 loopback (`127.0.0.1`). The auth policy may accept `::1` defensively, but the server should not need an IPv6 listen socket unless a concrete client requires it.

The `WebServer` currently always installs `NIOSSLServerHandler`. It needs a transport security option:

```swift
enum WebTransportSecurity {
    case tls(WebTLSContextProvider)
    case plainHTTPLoopbackOnly
}
```

The plain HTTP case should only be constructible or startable with loopback bind addresses. This protects against accidental future wiring that serves plain HTTP on a LAN or Tailscale interface.

## Mac Settings UX

Settings should make the mode explicit:

```text
Enable web access: on/off
Mode: Tailscale / SSH Tunnel
Port: 8799
```

Tailscale mode footer:

```text
Serves HTTPS only. Binds to Tailscale IPs. Allows only your Tailscale identity.
```

SSH tunnel mode footer:

```text
Serves HTTP on 127.0.0.1 only. Use it with Graftty Mobile's SSH connection or your own SSH tunnel. Do not expose this port directly.
```

When SSH tunnel mode is listening, the Settings pane should show:

```text
Listening on 127.0.0.1:8799
```

It should also show onboarding help:

For Graftty Mobile:

```text
In Graftty Mobile, add an SSH host and install its generated public key on this Mac.
```

For another Mac:

```sh
ssh -L 8799:127.0.0.1:8799 user@this-mac
open http://127.0.0.1:8799/
```

If the client Mac already uses local port `8799`:

```sh
ssh -L 18099:127.0.0.1:8799 user@this-mac
open http://127.0.0.1:18099/
```

The QR code shown for Tailscale onboarding should not be reused for SSH mode. In SSH mode, either hide it or replace it with SSH-specific instructions.

## Mac-To-Mac V1

Mac-to-Mac support in V1 is manual SSH forwarding plus browser access.

Serving Mac:

- runs Graftty web access in SSH tunnel mode;
- listens on `127.0.0.1:<port>`.

Client Mac:

```sh
ssh -L 8799:127.0.0.1:8799 user@serving-mac
open http://127.0.0.1:8799/
```

This intentionally does not add native remote-host browsing to the desktop Graftty app. That can be reconsidered later if browser-over-tunnel is not enough.

## Lifecycle And Reconnects

Graftty Mobile should treat the SSH tunnel as part of the selected host's connection state.

Entering an SSH host:

- connect SSH;
- start the local listener;
- resolve a runtime base URL;
- navigate into the worktree picker.

Leaving the host scope:

- close terminal WebSockets;
- stop the local listener;
- close the SSH connection.

Foreground/background:

- do not attempt to keep a long-running background tunnel alive;
- on foreground, assume the tunnel may be dead;
- reconnect before issuing new requests.

Reconnect behavior:

- if an API request fails because the tunnel is down, reconnect once before surfacing an error;
- if a terminal WebSocket closes while visible, reconnect SSH first, then reconnect the WebSocket against the new runtime local port;
- if SSH authentication or host-key validation fails, do not retry silently.

## Error Handling

Mobile user-facing errors should distinguish:

- could not reach SSH host;
- SSH authentication failed;
- SSH host key changed;
- remote Graftty server is not listening on `127.0.0.1:<port>`;
- tunnel disconnected;
- local proxy port could not be opened;
- Graftty server returned an unsupported response.

Mac-side status should distinguish:

- stopped;
- listening in Tailscale mode;
- listening in SSH tunnel mode;
- port unavailable;
- invalid port;
- Tailscale unavailable, MagicDNS disabled, or HTTPS cert failures in Tailscale mode only.

SSH tunnel mode should never show Tailscale-specific errors.

## Testing

Mac-side unit tests:

- `WebAccessSettings` persists mode and port.
- `WebServerController` chooses Tailscale LocalAPI/TLS/WhoIs in Tailscale mode.
- `WebServerController` chooses `127.0.0.1`, plain HTTP, and loopback auth in SSH mode.
- Plain HTTP transport refuses non-loopback bind addresses.
- SSH mode status copy does not report Tailscale-specific errors.

Mac-side integration tests:

- plain loopback server serves `/`, `/worktrees/panes`, `/repos`, `/ghostty-config`;
- plain loopback server upgrades `/ws`;
- non-loopback auth is denied through an injected peer-IP/auth test seam.

Mobile unit tests:

- SSH host config is saved separately from the generated private key.
- generated private key store writes to Keychain abstraction, not host JSON;
- public key export/share payload is stable;
- host-key pinning accepts first trust, accepts matching later keys, and blocks changed keys;
- SSH host resolution produces a temporary local base URL and does not persist it.

Mobile integration tests with fakes:

- `SSHTunnelSession` accepts a local connection and bridges bytes through a fake direct-tcpip channel;
- API fetchers work unchanged when given the tunnel runtime base URL;
- WebSocket client reconnects after tunnel restart.

Manual verification:

- Mac-to-Mac `ssh -L` opens the web UI in a browser.
- Graftty Mobile can add an SSH host, connect, list worktrees, open a pane, type into the terminal, background/foreground, and reconnect.

## Open Questions

- Which SSH library should be used for iOS? `swift-nio-ssh` fits the existing SwiftNIO stack and supports direct TCP forwarding, but it is a low-level library rather than a turnkey SSH client.
- Which key algorithm should Graftty Mobile generate first: Ed25519 if library/platform support is straightforward, otherwise ECDSA P-256 or RSA as a fallback?
- Should restricted `authorized_keys` setup become the recommended default after macOS compatibility is verified?
- Should SSH tunnel mode eventually support native Mac-to-Mac remote browsing, or is manual browser forwarding enough?


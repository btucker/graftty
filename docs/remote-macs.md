# Remote Macs

Graftty can connect two Macs so you can use one Mac's existing worktrees
and persistent terminal sessions from the other. Pairing starts on the
local network; after that, the same key-authenticated connection works
over either LAN or Tailscale. This is terminal access, not screen sharing.
Both Macs run the normal Graftty app; no separate server or system SSH
setup is required.

## Pair two Macs

Graftty advertises its dedicated local remote-access service with Bonjour
while it is running. To add another Mac:

1. Open Graftty on both Macs and allow Local Network access when macOS asks.
2. On the Mac you want to work from, click the **Manage Remote Hosts**
   button (the computer icon at the bottom of the sidebar), then
   **Add Remote Mac…**.
3. Select the discovered Mac. If Bonjour/mDNS is unavailable on the
   network, enter its LAN listener URL instead.
4. Click **Pair** and compare the verification code shown on both Macs.
   Accept the request on the host Mac and confirm it on the client only
   when the codes match.

The client saves the paired Mac by its stable device ID, full public key,
and signed LAN/Tailscale routes—not by one changeable hostname or IP address.
Only paired Macs are saved in the **Remote Hosts** list; nearby, unpaired
Bonjour results remain inside the Add Remote Mac sheet.

Click **Connect** beside a saved Mac to connect on demand. Once connected, its
worktrees and panes appear in the sidebar. Selecting a remote pane opens an
interactive terminal attached to that pane's persistent `zmx` session.
Graftty keeps one client connection per saved Mac and carries terminal,
pane-list, and pane-control traffic through an encrypted WebRTC DataChannel
with mutually authenticated SSH inside it. When several saved routes are
available, Graftty probes them concurrently and uses the first route that
proves possession of the paired host key.

To request a reconnect from any directory, run:

```sh
graftty remote reconnect "Studio Mac"
```

Use the exact saved name from the **Remote Hosts** list or a device ID.
Graftty must be running locally. The command confirms that the request was
accepted; check the **Remote Hosts** list for connection status. If a name matches multiple
Macs, the error lists their device IDs. Macs that need pairing must be paired
again in the app.

From a shell on the host Mac, ask a connected viewing Mac to reconnect:

```sh
graftty remote reconnect-client "Laptop"
```

Use the viewing Mac's paired name or device ID. A targeting error lists
connected clients. Both Macs need this command's support, and the control
channel must still work. If the connection is completely broken, run
`graftty remote reconnect` on the viewing Mac instead. Neither command resends
team messages.

## Trust, revocation, and recovery

Bonjour discovery is only an address hint—it does not establish trust.
Pairing exchanges public identity keys, requires approval on the host, and
uses the matching verification code to prevent an untrusted LAN peer from
silently adding itself. The dedicated paired-access listener runs on port
8800 over LAN and Tailscale and exposes only pairing and signaling routes.
Every signaling challenge, WebRTC offer, and answer is signed with the keys
established during pairing; captured challenges are short-lived and
single-use.

Every later connection verifies the host's SSH key against the fingerprint
pinned during pairing. If the key does not match, Graftty fails closed and
marks the saved Mac **Pairing required** in the **Remote Hosts** list. A later
Bonjour announcement does not clear that warning. Use **Pair…** to pair
again only after confirming why the host identity changed—for example,
after the other Mac's Graftty identity data was intentionally reset.

The host can revoke a paired client under **Settings → Web Access → Device
Pairing**. Removing it also closes that client's active SSH connection.
The current host accepts one active incoming remote connection at a time;
another client receives a retryable “host busy” failure without displacing
the active connection.

If a Mac does not appear during initial pairing, confirm that both apps are
running on the same LAN, Local Network permission is enabled for Graftty,
and the network allows Bonjour/mDNS. Corporate and guest networks often
block peer discovery or device-to-device traffic; use the manual LAN URL
when one is available. For later remote connections, both devices must be
online in the same tailnet and the host must still be reachable on port
8800.

# Concurrent inbound connections from paired devices

An iPhone could not load worktrees while another Mac held an inbound connection. Both offers reached the same `AppServices.hostAgent`, whose busy guard permits one connection lifecycle. Disconnecting the other Mac restored iPhone access.

## Approved design

Keep `WebRTCHostAgent` as the unit of one connection. Add `WebRTCHostAgentPool`, an actor mapping each authenticated `RemoteDeviceID` to its own agent. Default capacity is eight devices. The app supplies an async factory that constructs and configures each agent lazily after startup.

Before admission, discard idle, closed, or failed lifecycles. An existing device forwards to its own agent, preserving the ordinary-offer busy guard and signed same-device replacement. A different device receives an independent agent unless the pool is full. Capacity exhaustion returns the existing retryable `HostError.busy` and signaling `hostBusy` response. An unsuccessful first offer releases its entry.

Reserve entries before awaiting the factory. Pending creation and offers count toward capacity. Pruning must recheck entry identity and pending work after reading actor state, and must never discard a lifecycle during signed replacement. A stale offer completion must not evict a newer lifecycle. These checks prevent Swift actor reentrancy from bypassing the limit or orphaning a connection.

Expose `agent(for:)`, `connectedDeviceIDs`, and `closeAll()`. The device list represents connections retained by the pool, including pending offers. Closing the pool drains creation and offer work, closes every retained connection, and clears the entries. New offers are busy until closing completes. Discarded lifecycles are closed to release any remaining resources.

Move the app's agent construction and channel-handler wiring into the pool factory. Keep explicit captures and MainActor access for app state. Preserve authenticated signaling verification, cached answers, signed replacement authority, and releaseOffer on failed admission. Identity loading still happens before the listener starts, so identity errors leave paired access unavailable.

SSHConnectionRegistry, ActiveRemotePeerRegistry, RemoteTeamRouter, SessionDisplayOwnershipStore, and RemoteAttachmentRegistry remain shared and keyed per device or connection. Each agent retains its own expected signaling identity for SSH authentication. No mobile or Mac-to-Mac client behavior changes.

Retain lazy per-agent RTCPeerConnectionFactory construction. This preserves native-WebRTC-free initialization and tests; sharing a factory would require changing its ownership and initialization contract. SSL initialization remains process-wide and runs once.

## Specs and verification

Reword REMOTE-11.1, REMOTE-11.10, REMOTE-11.11, and REMOTE-11.13 for per-device connections. Add REMOTE-11.18 through REMOTE-11.22 for concurrent devices, capacity, lifecycle pruning, closing every connection, and concurrent admission accounting.

Use WebRTC-free fixtures and the agent's admission/state seams to verify pool behavior, including same-device reconnects, failed allocation, pending creation, competing offers, and shutdown during creation. Update the opt-in LAN loopback test to pass offers through the pool. Leave the mobile coordinator comment unchanged because its busy guard description remains valid per device.

Run the RED pool tests before adding the implementation, then the full suite through `scripts/swiftpm test`. Regenerate SPECS.md using `scripts/generate-specs.py`, check it with `--check`, and run the repository's xhigh code review with fixes before opening a PR against main.

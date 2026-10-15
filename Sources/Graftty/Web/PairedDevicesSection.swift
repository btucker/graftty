import SwiftUI
import GrafttyKit
import GrafttyHostAgent
import GrafttyProtocol

// MARK: - RemoteDeviceKind + display

extension RemoteDeviceKind {
    /// Human-readable label shown in pairing / paired-device UI.
    var displayLabel: String {
        switch self {
        case .mac: return "Mac"
        case .linux: return "Linux"
        case .iphone: return "iPhone"
        case .ipad: return "iPad"
        }
    }
}

// MARK: - PairedDevicesSection

/// Device Pairing settings-pane section. Pairing is initiated from the
/// client so Settings only explains that flow and manages established trust.
struct PairedDevicesSection: View {
    @ObservedObject var pairingCoordinator: RemoteMacHostPairingCoordinator
    let trustedPeerStore: TrustedPeerStore
    /// Same instance `WebRTCHostAgent` registers its live SSH connection
    /// into (REMOTE-3.1). `remove(_:)` revokes here right after a
    /// successful `trustedPeerStore.remove` so the peer's live session
    /// drops immediately instead of surviving until its next userauth
    /// attempt fails.
    let sshConnectionRegistry: SSHConnectionRegistry

    @State private var peers: [TrustedPeer] = []
    @State private var listError: String?

    /// Guards against a double-tap on a single row's Remove button firing
    /// two overlapping `performRemove` calls: `remove(_:)` spawns a `Task`
    /// with an `await revoke` suspension, and `TrustedPeerStore.remove` is
    /// not idempotent (a second call for the same id throws `.notFound`),
    /// which without this guard surfaces as a false "Could not remove"
    /// error flash on the second tap.
    @State private var removingPeerIDs: Set<RemoteDeviceID> = []

    var body: some View {
        Section {
            Text("On your iPhone, iPad, or another Mac, tap + and select this Mac under Nearby Macs.")
                .font(.caption)
                .foregroundStyle(.secondary)
            errorText(pairingCoordinator.startupError)
            errorText(listError)
            if peers.isEmpty {
                Text("No paired devices yet.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(peers) { peer in
                    peerRow(peer)
                }
            }
        } header: {
            Text("Device Pairing")
        }
        .onAppear { refreshPeers() }
    }

    /// Shared rendering for the section's inline error rows (coordinator
    /// failures, peer-list load/remove failures). `nil` renders nothing.
    @ViewBuilder private func errorText(_ message: String?) -> some View {
        if let message {
            Text(message).foregroundStyle(.red).font(.caption)
        }
    }

    @ViewBuilder private func peerRow(_ peer: TrustedPeer) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                Text("\(peer.kind.displayLabel) · \(peer.fingerprint.display)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Picker("Port forwarding", selection: Binding(
                    get: { peer.capabilities.portTunnel },
                    set: { updatePortPermission(peer, permission: $0) }
                )) {
                    Text("Ask through host").tag(PairedDeviceCapabilities.PortTunnel.askEachTime)
                    Text("Allow localhost").tag(PairedDeviceCapabilities.PortTunnel.allowedLoopback)
                    Text("Disabled").tag(PairedDeviceCapabilities.PortTunnel.disabled)
                }
                .disabled(removingPeerIDs.contains(peer.id))
                .help("Changing this permission disconnects the device. Reconnect to use the new setting.")
                Text("Paired \(Self.relativeFormatter.localizedString(for: peer.pairedAt, relativeTo: Date()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove") { remove(peer) }
                .buttonStyle(.borderless)
                .disabled(removingPeerIDs.contains(peer.id))
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func updatePortPermission(_ peer: TrustedPeer, permission: PairedDeviceCapabilities.PortTunnel) {
        guard !removingPeerIDs.contains(peer.id) else { return }
        removingPeerIDs.insert(peer.id)
        Task {
            if let error = await Self.performPortPermissionUpdate(peerID: peer.id, permission: permission,
                store: trustedPeerStore, revoke: { await sshConnectionRegistry.revoke(deviceID: $0) }) {
                listError = "Could not change port forwarding: \(error.localizedDescription)"
            } else { refreshPeers() }
            removingPeerIDs.remove(peer.id)
        }
    }

    static func performPortPermissionUpdate(peerID: RemoteDeviceID,
        permission: PairedDeviceCapabilities.PortTunnel, store: TrustedPeerStore,
        revoke: (RemoteDeviceID) async -> Void) async -> Swift.Error? {
        do {
            guard var current = try store.get(id: peerID) else { throw TrustedPeerStore.Error.notFound }
            current.capabilities.portTunnel = permission
            try store.update(current)
        } catch { return error }
        await revoke(peerID)
        return nil
    }

    private func remove(_ peer: TrustedPeer) {
        guard !removingPeerIDs.contains(peer.id) else { return }
        removingPeerIDs.insert(peer.id)
        Task {
            let error = await Self.performRemove(
                peerID: peer.id,
                store: trustedPeerStore,
                revoke: { await sshConnectionRegistry.revoke(deviceID: $0) }
            )
            if let error {
                listError = "Could not remove device: \(error)"
            } else {
                // Drop the removed peer locally first: `refreshPeers()`
                // re-reads `trustedPeerStore.list()` below, but if that
                // read throws (corrupt/racing file), its `catch` only sets
                // `listError` and leaves `peers` untouched — without this,
                // the just-removed-and-revoked device would keep rendering
                // as live. Removing it here means the UI reflects the
                // successful removal regardless of whether the reload
                // succeeds; `refreshPeers()` then reconciles the rest of
                // the list on success.
                peers.removeAll { $0.id == peer.id }
                refreshPeers()
            }
            removingPeerIDs.remove(peer.id)
        }
    }

    /// Extracted from `remove(_:)` for testability (SwiftUI view actions
    /// aren't directly unit-testable). Removes `peerID` from `store`
    /// first; `revoke` only runs on a SUCCESSFUL removal — a peer that
    /// fails to leave the trust store is still considered paired, so its
    /// live connection must not be killed. Returns the store error (if
    /// any) rather than throwing so the caller can render it inline.
    static func performRemove(
        peerID: RemoteDeviceID,
        store: TrustedPeerStore,
        revoke: (RemoteDeviceID) async -> Void
    ) async -> Swift.Error? {
        do {
            try store.remove(id: peerID)
        } catch {
            return error
        }
        await revoke(peerID)
        return nil
    }

    private func refreshPeers() {
        do {
            peers = try trustedPeerStore.list()
            listError = nil
        } catch {
            listError = "Could not load paired devices: \(error)"
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}

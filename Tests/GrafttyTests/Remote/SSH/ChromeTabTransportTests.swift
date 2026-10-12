import CryptoKit
import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import Testing

private actor ChromeTransportRecorder {
    var peerIDs: [String] = []
    var disconnected = false
    func received(_ peer: RemoteDeviceID) { peerIDs.append(peer.value) }
    func closed() { disconnected = true }
}

@Suite(.serialized)
struct ChromeTabTransportTests {
    enum UnusedTerminal: Error { case unused }

    @Test("@spec CHROME-3.1: When a paired peer opens the Chrome subsystem, the application shall await host acceptance, enforce its management capability, pass its authenticated identity, and carry bounded JPEG responses over framed SSH.", .timeLimit(.minutes(1)), arguments: [true, false])
    func authenticatedSubsystem(allowed: Bool) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("chrome-ssh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerID = RemoteDeviceID(value: "authenticated-device")
        let store = TrustedPeerStore(directory: directory)
        try store.add(TrustedPeer(id: peerID, kind: .iphone,
            publicKey: try RemoteIdentityPublicKey(rawRepresentation: clientKey.publicKey.rawRepresentation), displayName: "Phone",
            capabilities: PairedDeviceCapabilities(terminalControl: .allowed, portTunnel: .disabled, screenView: .disabled, screenControl: .disabled,
                worktreeManagement: allowed ? .allowed : .disabled), pairedAt: Date(), lastSeenAt: nil))
        let recorder = ChromeTransportRecorder()
        let state = ChromeTabState(tabs: (0..<32).map { .init(id: String($0), title: String(repeating: "x", count: 256), url: "https://example.com/" + String(repeating: "x", count: 2028)) },
            selectedTabID: "0", frame: .init(tabID: "0", jpeg: Data(repeating: 0xff, count: ChromeTabFrame.maximumJPEGBytes), sequence: 1))
        #expect(try ChromeTabResponse(state: state).encoded().count < ChromeTabRequest.maximumResponseBytes)
        let server = DirectSSHHostServer(hostKey: hostKey, trustedPeerStore: store, streamFactory: { _ in throw UnusedTerminal.unused },
            panesStateSubscribe: { onChange in await onChange(.snapshot([])); return .init(cancel: {}) }, paneControlMutator: { _ in .ok },
            chromeTabMutator: { _, peer, _ in await recorder.received(peer); return .init(state: state) },
            chromeTabOnDisconnect: { _ in await recorder.closed() }, displayOwnershipStore: SessionDisplayOwnershipStore())
        let client = DirectSSHHostConnection(clientKey: clientKey,
            expectedHostFingerprint: RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: hostKey.publicKey.rawRepresentation)))
        let port = try await server.start(host: "127.0.0.1", port: 0)
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            let chrome = try await client.makeChromeTabClient()
            if allowed {
                try await chrome.open()
                let response = try await chrome.send(.init(target: "pane", action: .list))
                #expect(response.state == state)
                #expect(await recorder.peerIDs == [peerID.value])
                chrome.close()
                let deadline = ContinuousClock.now + .seconds(2)
                while await !recorder.disconnected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                #expect(await recorder.disconnected)
            } else {
                await #expect(throws: ChromeTabChannelClient.ClientError.unsupported) { try await chrome.open() }
                #expect(await recorder.peerIDs.isEmpty)
            }
        } catch { await client.close(); await server.close(); throw error }
        await client.close(); await server.close()
    }
}

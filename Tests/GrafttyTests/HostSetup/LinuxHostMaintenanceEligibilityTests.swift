import Foundation
import Testing
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
@testable import Graftty

@MainActor
struct LinuxHostMaintenanceEligibilityTests {
    @Test("@spec REMOTE-22.26: While a trusted Linux host is connected, the application shall offer Update Host; direct SSH transport alone shall not identify a host as Linux.")
    func connectedTrustedLinuxOnly() throws {
        let key = try RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 2, count: 32))
        let remote = RemoteMac(id: .init(value: "host"), label: "Host", fingerprint: .init(of: key), transport: .directSSH, directEndpoint: try .init(host: "host"))
        func pin(_ kind: RemoteDeviceKind) -> PinnedHost {
            .init(id: remote.id, kind: kind, publicKey: key, displayName: "Host", pinnedAt: Date(), pairingURL: URL(string: "ssh://host:8801")!)
        }
        #expect(RemoteMacsModel.canMaintain(remote, state: .connected, pinned: pin(.linux)))
        #expect(!RemoteMacsModel.canMaintain(remote, state: .offline, pinned: pin(.linux)))
        #expect(!RemoteMacsModel.canMaintain(remote, state: .connected, pinned: pin(.mac)))
        #expect(!RemoteMacsModel.canMaintain(remote, state: .connected, pinned: nil))
    }
}

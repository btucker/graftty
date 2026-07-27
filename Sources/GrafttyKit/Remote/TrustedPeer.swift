import Foundation
import GrafttyProtocol

// MARK: - PairedDeviceCapabilities

/// The set of permissions granted to a trusted remote peer.
public struct PairedDeviceCapabilities: Codable, Sendable, Equatable, Hashable {
    public enum TerminalControl: String, Codable, Sendable, Equatable {
        case allowed
        case disabled
    }

    public enum PortTunnel: String, Codable, Sendable, Equatable {
        case disabled
        case askEachTime = "ask_each_time"
        case allowedLoopback = "allowed_loopback"
    }

    public enum ScreenView: String, Codable, Sendable, Equatable {
        case disabled
        case askEachTime = "ask_each_time"
        case allowed
    }

    public enum ScreenControl: String, Codable, Sendable, Equatable {
        case disabled
        case askEachTime = "ask_each_time"
        case allowed
    }

    public enum WorktreeManagement: String, Codable, Sendable, Equatable {
        case allowed
        case disabled
    }

    public var terminalControl: TerminalControl
    public var portTunnel: PortTunnel
    public var screenView: ScreenView
    public var screenControl: ScreenControl
    public var worktreeManagement: WorktreeManagement

    public init(
        terminalControl: TerminalControl,
        portTunnel: PortTunnel,
        screenView: ScreenView,
        screenControl: ScreenControl,
        worktreeManagement: WorktreeManagement? = nil
    ) {
        self.terminalControl = terminalControl
        self.portTunnel = portTunnel
        self.screenView = screenView
        self.screenControl = screenControl
        self.worktreeManagement = worktreeManagement
            ?? (terminalControl == .allowed ? .allowed : .disabled)
    }

    /// The default capability set granted immediately after a successful pairing.
    public static var defaultsAfterPairing: PairedDeviceCapabilities {
        PairedDeviceCapabilities(
            terminalControl: .allowed,
            portTunnel: .askEachTime,
            screenView: .disabled,
            screenControl: .disabled,
            worktreeManagement: .allowed
        )
    }

    private enum CodingKeys: String, CodingKey {
        case terminalControl, portTunnel, screenView, screenControl,
             worktreeManagement
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminalControl = try c.decode(TerminalControl.self, forKey: .terminalControl)
        portTunnel = try c.decode(PortTunnel.self, forKey: .portTunnel)
        screenView = try c.decode(ScreenView.self, forKey: .screenView)
        screenControl = try c.decode(ScreenControl.self, forKey: .screenControl)
        // Existing paired peers already possess shell-level terminal control,
        // so preserving management access is the least-surprising migration.
        worktreeManagement = try c.decodeIfPresent(
            WorktreeManagement.self,
            forKey: .worktreeManagement
        ) ?? (terminalControl == .allowed ? .allowed : .disabled)
    }
}

// MARK: - TrustedPeer

/// A remote device that has completed the pairing ceremony and is trusted by this host.
public struct TrustedPeer: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: RemoteDeviceID
    public let kind: RemoteDeviceKind
    public let publicKey: RemoteIdentityPublicKey
    public var displayName: String
    public var capabilities: PairedDeviceCapabilities
    public let pairedAt: Date
    public var lastSeenAt: Date?

    /// The SHA-256 fingerprint derived from the peer's public key.
    public var fingerprint: RemoteIdentityFingerprint {
        RemoteIdentityFingerprint(of: publicKey)
    }

    public init(
        id: RemoteDeviceID,
        kind: RemoteDeviceKind,
        publicKey: RemoteIdentityPublicKey,
        displayName: String,
        capabilities: PairedDeviceCapabilities,
        pairedAt: Date,
        lastSeenAt: Date?
    ) {
        self.id = id
        self.kind = kind
        self.publicKey = publicKey
        self.displayName = displayName
        self.capabilities = capabilities
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}

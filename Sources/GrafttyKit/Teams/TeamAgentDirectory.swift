import CryptoKit
import Foundation

/// @spec AGENT-6.2
/// Canonical Graftty identity for one top-level provider session. Native
/// discovery derives the suffix from the provider's opaque session identity;
/// transports that must register before that identity exists may supply an
/// equivalent launch-scoped nonce. Mutable provider display names never route.
public struct TeamAgentIdentity: RawRepresentable, Hashable, Codable, Sendable {
    public let runtime: TeamHookRuntime
    public let suffix: String

    public var rawValue: String { "\(runtime.rawValue)-\(suffix)" }

    public init(runtime: TeamHookRuntime, nativeSessionID: String) {
        self.runtime = runtime
        let digest = SHA256.hash(data: Data(nativeSessionID.utf8))
        self.suffix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public init?(rawValue: String) {
        guard let separator = rawValue.firstIndex(of: "-") else { return nil }
        let runtimeText = String(rawValue[..<separator])
        let suffixStart = rawValue.index(after: separator)
        let suffix = String(rawValue[suffixStart...])
        guard let runtime = TeamHookRuntime(rawValue: runtimeText),
              suffix.count == 12,
              suffix.allSatisfy({ character in
                  ("0"..."9").contains(String(character))
                      || ("a"..."f").contains(String(character))
              }) else {
            return nil
        }
        self.runtime = runtime
        self.suffix = suffix
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let identity = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid team agent identity: \(rawValue)"
            )
        }
        self = identity
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct TeamAgentDescriptor: Equatable, Sendable {
    public let id: TeamAgentIdentity
    public let teamID: String
    public let worktreePath: String
    public let runtime: TeamHookRuntime
    public let identitySource: String
    public let displayName: String?
    public let paneSessionName: String?
    public let registeredAt: Date
    public let isReachable: Bool
    public let transport: TeamAgentTransport?

    public func address(worktreeAddress: String) -> String {
        "\(worktreeAddress)#\(id.rawValue)"
    }
}

public enum TeamAgentDirectoryError: Error, Equatable, CustomStringConvertible {
    case explicitAgentNotFound(String)
    case explicitAgentUnavailable(String)

    public var description: String {
        switch self {
        case .explicitAgentNotFound(let id):
            return "team agent not found: \(id)"
        case .explicitAgentUnavailable(let id):
            return "team agent is no longer reachable: \(id)"
        }
    }
}

/// @spec AGENT-6.3
/// Snapshot resolver for top-level agents. A caller supplies reachability so
/// app code can combine process, pane, and native-transport checks without
/// putting UI state into this value type.
public struct TeamAgentDirectory: Sendable {
    public let agents: [TeamAgentDescriptor]

    public init(
        records: [TeamPresenceRecord],
        isReachable: (TeamPresenceRecord) -> Bool
    ) {
        self.agents = records.compactMap { record in
            guard record.isSubagent != true else { return nil }
            let source = Self.identitySource(for: record)
            return TeamAgentDescriptor(
                id: Self.identity(for: record),
                teamID: record.teamID,
                worktreePath: record.worktree,
                runtime: record.runtime,
                identitySource: source,
                displayName: record.nativeDisplayName,
                paneSessionName: record.paneSessionName,
                registeredAt: record.registeredAt,
                isReachable: isReachable(record),
                transport: record.transport
            )
        }.sorted(by: Self.isOrderedBefore)
    }

    /// The single canonical-identity derivation for a presence record; every
    /// consumer (directory, ownership resolver, delivery services) must agree
    /// on it or agent-pinned rows become unroutable.
    public static func identity(for record: TeamPresenceRecord) -> TeamAgentIdentity {
        record.agentID.flatMap(TeamAgentIdentity.init(rawValue:))
            ?? TeamAgentIdentity(
                runtime: record.runtime,
                nativeSessionID: identitySource(for: record)
            )
    }

    static func identitySource(for record: TeamPresenceRecord) -> String {
        record.runtimeSessionID
            ?? record.agentID
            ?? [
                record.paneSessionName ?? "no-pane",
                String(record.pid),
                record.processStartTimeMicroseconds.map(String.init) ?? "no-start",
            ].joined(separator: ":")
    }

    /// Resolves nil to the earliest reachable agent across runtimes. An
    /// explicit ID never falls through to another agent or a worktree queue.
    public func resolve(
        worktreePath: String,
        explicitAgentID: String?
    ) throws -> TeamAgentDescriptor? {
        try resolve(
            worktreePath: worktreePath,
            runtime: nil,
            explicitAgentID: explicitAgentID
        )
    }

    /// A runtime-qualified address defaults only within that provider. Exact
    /// IDs remain global and fail closed; they are never silently replaced by
    /// another agent of the requested runtime.
    public func resolve(
        worktreePath: String,
        runtime: TeamHookRuntime?,
        explicitAgentID: String?
    ) throws -> TeamAgentDescriptor? {
        let worktreeCandidates = agents.filter { $0.worktreePath == worktreePath }
        guard let explicitAgentID else {
            let candidates = worktreeCandidates.filter { candidate in
                runtime == nil || candidate.runtime == runtime
            }
            return candidates.first(where: \.isReachable)
        }
        let exactCandidates = worktreeCandidates.filter { candidate in
            candidate.id.rawValue == explicitAgentID
                && (runtime == nil || candidate.runtime == runtime)
        }
        guard !exactCandidates.isEmpty else {
            throw TeamAgentDirectoryError.explicitAgentNotFound(explicitAgentID)
        }
        guard let exact = exactCandidates.first(where: \.isReachable) else {
            throw TeamAgentDirectoryError.explicitAgentUnavailable(explicitAgentID)
        }
        return exact
    }

    private static func isOrderedBefore(
        _ lhs: TeamAgentDescriptor,
        _ rhs: TeamAgentDescriptor
    ) -> Bool {
        if lhs.registeredAt != rhs.registeredAt {
            return lhs.registeredAt < rhs.registeredAt
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}

/// Resolves the canonical identity belonging to one provider hook invocation.
/// A native session ID is authoritative when present; pane fallback exists
/// only for older hook payloads that do not carry a session identity.
public enum TeamAgentSessionIdentityResolver {
    public static func agentID(
        records: [TeamPresenceRecord],
        teamID: String,
        worktree: String,
        runtime: TeamHookRuntime,
        sessionID: String?,
        paneSessionName: String?
    ) -> String? {
        let candidates = records.filter { record in
            record.teamID == teamID
                && record.worktree == worktree
                && record.runtime == runtime
        }
        if let sessionID {
            return candidates.first(where: { $0.runtimeSessionID == sessionID })?.agentID
        }
        guard let paneSessionName else { return nil }
        let identities = Set(candidates.compactMap { record in
            record.paneSessionName == paneSessionName ? record.agentID : nil
        })
        guard identities.count == 1 else { return nil }
        return identities.first
    }
}

public enum TeamAgentReachability {
    public static func isReachable(_ record: TeamPresenceRecord) -> Bool {
        guard record.pid > 0,
              TeamPresenceMonitor.kernelIsAlive(record.pid) else {
            return false
        }
        if let expectedStart = record.processStartTimeMicroseconds,
           ProcessIdentityReader.startTimeMicroseconds(ofPID: record.pid) != expectedStart {
            return false
        }
        guard let transport = record.transport else { return true }
        let socketPath: String
        switch transport {
        case .claude(let path, _):
            socketPath = path
        case .codex(_, let path, _, _):
            socketPath = path
        }
        return ClaudePeerSessionRegistry.isSocket(atPath: socketPath)
    }
}

/// Resolves the author of a CLI-authored team message. Wrapper-launched
/// sessions provide an explicit identity; plugin-only sessions recover the
/// same identity from the live presence bound to their terminal pane. An
/// ambiguous lookup returns nil so callers use the worktree-default address
/// instead of attributing a message to the wrong agent.
public enum TeamCallerAgentIdentityResolver {
    public static func resolve(
        explicitAgentID: String?,
        worktree: String,
        paneSessionName: String?,
        records: [TeamPresenceRecord],
        isReachable: (TeamPresenceRecord) -> Bool
    ) -> String? {
        if let explicit = explicitAgentID.flatMap(TeamAgentIdentity.init(rawValue:)) {
            return explicit.rawValue
        }

        let identities = Set(records.compactMap { record -> TeamAgentIdentity? in
            guard record.worktree == worktree,
                  record.paneSessionName == paneSessionName,
                  record.isSubagent != true,
                  isReachable(record) else {
                return nil
            }
            return TeamAgentDirectory.identity(for: record)
        })
        guard identities.count == 1 else { return nil }
        return identities.first?.rawValue
    }
}

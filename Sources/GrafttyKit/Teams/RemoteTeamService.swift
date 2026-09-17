import Foundation
import GrafttyProtocol

public enum RemoteTeamRequest: Codable, Sendable, Equatable {
    case worktree(RemoteWorktreeRequest)
    /// The viewing Mac arms reconnect for this authenticated channel's close.
    case prepareReconnect
    case list
    case send(
        senderWorktree: String,
        senderAgentID: String?,
        recipientWorktree: String,
        recipientSuffix: String?,
        text: String,
        priority: TeamInboxPriority
    )
}

public enum RemoteTeamResponse: Codable, Sendable, Equatable {
    case worktreeCreate(WorktreeCreateStatus)
    case members([TeamListMember])
    case ok
    case error(String)
}

public enum RemoteTeamError: Error, Equatable, CustomStringConvertible {
    case invalidAddress
    case invalidSender
    case emptyMessage

    public var description: String {
        switch self {
        case .invalidAddress: return "invalid remote team address"
        case .invalidSender: return "invalid remote team sender"
        case .emptyMessage: return "team message must not be empty"
        }
    }
}

/// Device IDs are routing identities from the authenticated connection registry.
/// Display names are never substituted for them. Escape path delimiters before
/// adding the optional agent suffix so a literal `#claude` stays part of a path.
/// @spec TEAM-14.1
/// When a team address names a remote Mac, the application shall preserve its device ID, absolute worktree path, and optional runtime or canonical agent suffix without path-character collisions.
public struct RemoteTeamAddress: Sendable, Equatable {
    public static let prefix = "graftty-mac://"
    public let deviceID: RemoteDeviceID
    public let worktreePath: String
    public let suffix: String?

    public init(deviceID: RemoteDeviceID, worktreePath: String, suffix: String? = nil) throws {
        guard !deviceID.value.isEmpty,
              !deviceID.value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              Self.isAbsolutePath(worktreePath),
              Self.isValidSuffix(suffix) else {
            throw RemoteTeamError.invalidAddress
        }
        self.deviceID = deviceID
        self.worktreePath = worktreePath
        self.suffix = suffix
    }

    public init?(rawValue: String) {
        guard rawValue.hasPrefix(Self.prefix) else { return nil }
        let remainder = rawValue.dropFirst(Self.prefix.count)
        guard let slash = remainder.firstIndex(of: "/"),
              let device = String(remainder[..<slash]).removingPercentEncoding else { return nil }
        let pathAndSuffix = remainder[slash...].split(separator: "#", omittingEmptySubsequences: false)
        guard pathAndSuffix.count <= 2,
              let path = String(pathAndSuffix[0]).removingPercentEncoding else { return nil }
        let suffix = pathAndSuffix.count == 2 ? String(pathAndSuffix[1]) : nil
        guard let address = try? Self(deviceID: RemoteDeviceID(value: device), worktreePath: path, suffix: suffix) else { return nil }
        self = address
    }

    public var rawValue: String {
        let identityCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let pathCharacters = identityCharacters.union(CharacterSet(charactersIn: "/"))
        let device = deviceID.value.addingPercentEncoding(withAllowedCharacters: identityCharacters)!
        let path = worktreePath.addingPercentEncoding(withAllowedCharacters: pathCharacters)!
        return Self.prefix + device + path + (suffix.map { "#" + $0 } ?? "")
    }

    static func isAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func isValidSuffix(_ suffix: String?) -> Bool {
        guard let suffix else { return true }
        return TeamHookRuntime(rawValue: suffix) != nil || TeamAgentIdentity(rawValue: suffix) != nil
    }
}

/// Handles team requests only after the transport authenticates its peer.
/// The payload deliberately contains no sender device ID.
public final class RemoteTeamService {
    private let inbox: TeamInbox
    private let agentRecords: @Sendable () -> [TeamPresenceRecord]
    private let agentReachability: @Sendable (TeamPresenceRecord) -> Bool

    public init(
        inbox: TeamInbox,
        agentRecords: @escaping @Sendable () -> [TeamPresenceRecord] = { [] },
        agentReachability: @escaping @Sendable (TeamPresenceRecord) -> Bool = { _ in false }
    ) {
        self.inbox = inbox
        self.agentRecords = agentRecords
        self.agentReachability = agentReachability
    }

    public func handle(
        _ request: RemoteTeamRequest,
        from deviceID: RemoteDeviceID,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) -> RemoteTeamResponse {
        do {
            guard teamsEnabled else { throw TeamInboxRequestError.teamModeDisabled }
            switch request {
            case .worktree:
                return .error("Remote worktree creation is not available")
            case .prepareReconnect:
                return .error("Reconnect requests must target the viewing Mac's connection")
            case .list:
                return .members(members(repos: repos))
            case .send(let senderWorktree, let senderAgentID, let recipientWorktree, let recipientSuffix, let text, let priority):
                try receive(
                    senderWorktree: senderWorktree,
                    senderAgentID: senderAgentID,
                    recipientWorktree: recipientWorktree,
                    recipientSuffix: recipientSuffix,
                    text: text,
                    priority: priority,
                    from: deviceID,
                    repos: repos,
                    teamsEnabled: teamsEnabled
                )
                return .ok
            }
        } catch {
            return .error(String(describing: error))
        }
    }

    @discardableResult
    public func receive(
        senderWorktree: String,
        senderAgentID: String?,
        recipientWorktree: String,
        recipientSuffix: String?,
        text: String,
        priority: TeamInboxPriority,
        from deviceID: RemoteDeviceID,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) throws -> TeamInboxDelivery {
        guard teamsEnabled else { throw TeamInboxRequestError.teamModeDisabled }
        guard RemoteTeamAddress.isAbsolutePath(senderWorktree),
              senderAgentID == nil || senderAgentID.flatMap(TeamAgentIdentity.init(rawValue:)) != nil else {
            throw RemoteTeamError.invalidSender
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteTeamError.emptyMessage
        }
        guard RemoteTeamAddress.isAbsolutePath(recipientWorktree),
              RemoteTeamAddress.isValidSuffix(recipientSuffix) else {
            throw RemoteTeamError.invalidAddress
        }
        guard let repo = repos.first(where: { $0.worktrees.contains(where: { $0.path == recipientWorktree }) }),
              let worktree = repo.worktrees.first(where: { $0.path == recipientWorktree }) else {
            throw TeamInboxRequestError.recipientNotFound(name: recipientWorktree, available: [])
        }
        let teamID = TeamLookup.id(forRepoPath: repo.path)
        let identity = recipientSuffix.flatMap(TeamAgentIdentity.init(rawValue:))
        let selected: TeamAgentDescriptor?
        if let identity {
            selected = try TeamAgentDirectory(
                records: agentRecords().filter { $0.teamID == teamID },
                isReachable: agentReachability
            ).resolve(worktreePath: recipientWorktree, explicitAgentID: identity.rawValue)
        } else {
            selected = nil
        }
        let sender = senderAgentID.flatMap(TeamAgentIdentity.init(rawValue:))
        let senderAddress = try RemoteTeamAddress(deviceID: deviceID, worktreePath: senderWorktree)
        let recipient = TeamMember(
            name: WorktreeNameSanitizer.sanitize(worktree.branch),
            worktreePath: worktree.path,
            branch: worktree.branch,
            isMainWorktree: worktree.path == repo.path,
            isRunning: worktree.state == .running,
            hasOnDiskWorktree: worktree.state.hasOnDiskWorktree
        )
        let message = try inbox.appendMessage(
            teamID: teamID,
            teamName: repo.displayName,
            repoPath: repo.path,
            from: TeamInboxEndpoint(
                member: deviceID.value + "/" + URL(fileURLWithPath: senderWorktree).lastPathComponent,
                worktree: senderAddress.rawValue,
                runtime: sender?.runtime.rawValue,
                agentID: sender?.rawValue
            ),
            to: TeamInboxEndpoint(
                member: recipient.name,
                worktree: recipient.worktreePath,
                runtime: selected?.runtime.rawValue ?? recipientSuffix.flatMap(TeamHookRuntime.init(rawValue:))?.rawValue,
                agentID: selected?.id.rawValue
            ),
            priority: priority,
            body: text
        )
        return TeamInboxDelivery(recipient: recipient, message: message)
    }

    private func members(repos: [RepoEntry]) -> [TeamListMember] {
        let directory = TeamAgentDirectory(records: agentRecords(), isReachable: agentReachability)
        let agentsByWorktree = Dictionary(grouping: directory.agents, by: \.worktreePath)
        return repos.flatMap { repo in
            repo.worktrees.map { worktree in
                TeamListMember(
                    name: repo.displayName + "/" + WorktreeNameSanitizer.sanitize(worktree.branch),
                    branch: worktree.branch,
                    worktreePath: worktree.path,
                    isMainWorktree: worktree.path == repo.path,
                    isRunning: worktree.state == .running,
                    agents: (agentsByWorktree[worktree.path] ?? []).filter { $0.teamID == TeamLookup.id(forRepoPath: repo.path) }.map { agent in
                        TeamListAgent(
                            id: agent.id.rawValue,
                            address: agent.address(worktreeAddress: worktree.path),
                            runtime: agent.runtime,
                            displayName: agent.displayName,
                            isReachable: agent.isReachable,
                            paneSessionName: agent.paneSessionName
                        )
                    }
                )
            }
        }
    }
}

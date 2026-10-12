import Foundation
import GrafttyProtocol

public enum AgentCompletionCatalog {
    public static func contextualized(_ candidates: [AgentCompletionCandidate],
                                      worktreePath: String?, repos: [RepoEntry]) -> [AgentCompletionCandidate] {
        let project = repos.first { repo in repo.worktrees.contains { $0.path == worktreePath } }?.path
        return candidates.map { candidate in
            AgentCompletionCandidate(address: candidate.address, projectPath: candidate.projectPath,
                projectName: candidate.projectName, worktreePath: candidate.worktreePath,
                worktreeName: candidate.worktreeName, hostName: candidate.hostName, runtime: candidate.runtime,
                isCurrentProject: project != nil && candidate.projectPath == project)
        }
    }
    public static func local(repos: [RepoEntry], records: [TeamPresenceRecord],
                             isReachable: (TeamPresenceRecord) -> Bool,
                             hostName: String = "This Mac") -> [AgentCompletionCandidate] {
        let directory = TeamAgentDirectory(records: records, isReachable: isReachable)
        let agents = Dictionary(grouping: directory.agents.filter(\.isReachable), by: \.worktreePath)
        var seen = Set<String>()
        return repos.flatMap { repo in
            repo.worktrees.flatMap { worktree in
                (agents[worktree.path] ?? []).compactMap { agent -> AgentCompletionCandidate? in
                    guard agent.teamID == TeamLookup.id(forRepoPath: repo.path) else { return nil }
                    let address = worktree.path + "#" + agent.runtime.rawValue
                    guard seen.insert(address).inserted else { return nil }
                    return AgentCompletionCandidate(address: address, projectPath: repo.path,
                        projectName: repo.displayName, worktreePath: worktree.path,
                        worktreeName: worktree.path == repo.path ? "main" : worktree.branch,
                        hostName: hostName, runtime: agent.runtime.rawValue)
                }
            }
        }
    }

    /// Remote members already carry addresses qualified by the authenticated
    /// connection. Older hosts omit project metadata; their main-worktree row
    /// still provides a project grouping without substituting labels in routes.
    public static func remote(members: [TeamListMember]) -> [AgentCompletionCandidate] {
        var seen = Set<String>()
        return members.flatMap { member in
            let components = member.name.split(separator: "/").map(String.init)
            let group = components.dropLast().joined(separator: "/")
            let main = members.first { $0.isMainWorktree && $0.name.split(separator: "/").dropLast().joined(separator: "/") == group }
            let projectPath = member.projectPath ?? main?.worktreePath ?? member.worktreePath
            return member.agents.compactMap { agent -> AgentCompletionCandidate? in
                guard agent.isReachable,
                      let qualified = RemoteTeamAddress(rawValue: agent.address),
                      let stable = try? RemoteTeamAddress(deviceID: qualified.deviceID,
                          worktreePath: qualified.worktreePath, suffix: agent.runtime.rawValue),
                      seen.insert(stable.rawValue).inserted else { return nil }
                return AgentCompletionCandidate(address: stable.rawValue, projectPath: projectPath,
                    projectName: member.projectName ?? components.dropFirst().dropLast().joined(separator: "/"),
                    worktreePath: member.worktreePath, worktreeName: member.isMainWorktree ? "main" : member.branch,
                    hostName: components.first ?? "Remote Mac", runtime: agent.runtime.rawValue)
            }
        }
    }
}

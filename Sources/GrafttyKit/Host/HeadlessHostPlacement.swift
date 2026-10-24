import Foundation
import GrafttyProtocol

public extension HeadlessHostRuntime {
    var drain: HostDrainRecord? { placements.drain }

    @discardableResult
    func beginDrain(_ notice: HostInterruptionNotice) throws -> HostDrainRecord {
        defer { hostResources?.acceptingPlacements = false }
        return try placements.beginDrain(notice)
    }

    func place(_ request: HostPlacementRequest, owner: RemoteMacConnectionSummary.ID) async -> WorktreeManagementResponse {
        do {
            switch request {
            case .status(let id):
                guard let record = try placements.status(operationID: id, owner: owner) else {
                    throw HostRuntimeError.notFound("Placement not found")
                }
                return .placement(record)
            case .create(let id, let intent), .createInDevContainer(let id, let intent), .createWithAgentSkills(let id, let intent), .createWithMCP(let id, let intent):
                let containerRequest: Bool
                let skillRequest: Bool
                let mcpRequest: Bool
                if case .createWithMCP = request { mcpRequest = true } else { mcpRequest = false }
                switch request {
                case .createWithAgentSkills, .createWithMCP: containerRequest = true; skillRequest = true
                case .createInDevContainer: containerRequest = true; skillRequest = false
                default: containerRequest = false; skillRequest = false
                }
                guard containerRequest == (intent.devContainer != nil), skillRequest == (intent.devContainer?.skills != nil),
                      mcpRequest == (intent.devContainer?.mcpGrants != nil) else {
                    throw HostRuntimeError.invalid("Container placement requires the explicit container request type")
                }
                if let grants = intent.devContainer?.mcpGrants {
                    try MCPProfileMount.validate(grants, worktree: intent.worktreePath)
                    guard mcpProfiles != nil else { throw HostRuntimeError.invalid("Managed MCP profile service is unavailable") }
                }
                // Check ownership and immutable arguments before any filesystem or Git work.
                if try placements.status(operationID: id, owner: owner) != nil {
                    return .placement(try placements.admit(operationID: id, owner: owner, intent: intent, sample: nil))
                }
                guard !isShuttingDown else { throw HostRuntimeError.busy("Host is shutting down") }
                guard state.repos.contains(where: { $0.path == intent.repositoryID }) else {
                    throw HostRuntimeError.notFound("Repository must be registered on this host before placement")
                }
                if let error = WorktreeCreationInput.validationError(worktreeName: intent.worktreeName, branchName: intent.branchName) {
                    throw HostRuntimeError.invalid(error)
                }
                guard !FileManager.default.fileExists(atPath: intent.worktreePath), state.worktree(forPath: intent.worktreePath) == nil else {
                    throw HostRuntimeError.invalid("Worktree destination already exists")
                }
                let skills: [RemoteSkillSnapshot]
                if let selections = intent.devContainer?.skills {
                    skills = try await skillTransfers.load(selections, owner: owner, repositoryID: intent.repositoryID)
                } else { skills = [] }
                if containerRequest {
                    let help = try await GitRunner.captureAll(args: ["worktree", "add", "-h"], at: intent.repositoryID, timeout: .seconds(5))
                    guard (help.stdout + help.stderr).contains("relative-paths") else {
                        throw HostRuntimeError.invalid("Host Git must support --relative-paths for Dev Container placement")
                    }
                    try await devContainers.checkRelativeWorktreeSupport(at: intent.repositoryID)
                    // Compatibility checks suspend. A concurrent retry may have admitted this operation meanwhile.
                    if try placements.status(operationID: id, owner: owner) != nil {
                        return .placement(try placements.admit(operationID: id, owner: owner, intent: intent, sample: nil))
                    }
                }
                // Probe the nearest existing parent, including nested .worktrees mounts.
                // createWorktree repeats symlink and destination checks before Git runs.
                let diskPath = try placementDiskPath(for: intent)
                var sample = hostResources
                sample?.diskPath = diskPath
                sample?.diskAvailableBytes = HostResourceSampler.availableDiskBytes(at: diskPath)
                sample?.pendingWorktreeOperations = busyPaths.count
                try Task.checkCancellation()
                guard !isShuttingDown else { throw HostRuntimeError.busy("Host is shutting down") }
                let admitted = try placements.admit(operationID: id, owner: owner, intent: intent, sample: sample, filesystemPath: diskPath)
                // An unstructured task belongs to the host, not the RPC channel.
                // Persist admission and retain the task without suspending in between.
                placementTasks[id] = Task { [self] in
                    defer { placementTasks[id] = nil }
                    await performPlacement(id: id, intent: intent, skills: skills, owner: owner)
                }
                return .placement(admitted)
            }
        } catch {
            return .error(code: "placement-failed", message: String(describing: error), forceAllowed: false, shortStatus: nil)
        }
    }

    private func performPlacement(id: UUID, intent: HostPlacementIntent, skills: [RemoteSkillSnapshot], owner: RemoteMacConnectionSummary.ID) async {
        do {
            try Task.checkCancellation()
            let prepare: (@MainActor @Sendable (String) async throws -> Void)?
            if let request = intent.devContainer {
                prepare = { [self] path in
                    let mcp: MCPProfileMount?
                    if let grants = request.mcpGrants {
                        guard let mcpProfiles else { throw HostRuntimeError.invalid("Managed MCP profile service is unavailable") }
                        mcp = try mcpProfiles.prepare(operationID: id, configurations: grants.map { .init(parent: owner, scope: $0) })
                    } else { mcp = nil }
                    let environment = try await devContainers.prepare(workspace: path, configuration: request.configuration, operationID: id, skills: skills,
                        agent: request.agentRuntime.flatMap(TeamHookRuntime.init(rawValue:)), mcp: mcp)
                    try placements.recordEnvironment(operationID: id, environment: environment)
                }
            } else { prepare = nil }
            let created = try await createWorktree(repository: intent.repositoryID, name: intent.worktreeName, branch: intent.branchName,
                command: intent.devContainer?.agentRuntime,
                relativeGitPaths: intent.devContainer != nil, prepareEnvironment: prepare)
            try placements.complete(operationID: id, worktreeID: created.path, paneID: created.session)
        } catch {
            await mcpProfiles?.stop(operationID: id)
            // Git may have succeeded even if setup or persistence failed. If the
            // failure itself cannot be saved, keep the original preparing claim;
            // restart recovery marks it uncertain without repeating any mutation.
            try? placements.markOutcomeUnknown(operationID: id, message: String(describing: error))
        }
    }

    private func placementDiskPath(for intent: HostPlacementIntent) throws -> String {
        var path = (intent.worktreePath as NSString).deletingLastPathComponent
        var nearest: String?
        while path.hasPrefix(intent.repositoryID + "/") {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw HostRuntimeError.invalid("Placement parent must be a directory without symlinks")
                }
                if nearest == nil { nearest = path }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
            path = (path as NSString).deletingLastPathComponent
        }
        return nearest ?? intent.repositoryID
    }
}

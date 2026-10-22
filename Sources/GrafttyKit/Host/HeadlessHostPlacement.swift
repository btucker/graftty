import Foundation
import GrafttyProtocol

public extension HeadlessHostRuntime {
    func place(_ request: HostPlacementRequest, owner: RemoteMacConnectionSummary.ID) async -> WorktreeManagementResponse {
        do {
            switch request {
            case .status(let id):
                guard let record = try placements.status(operationID: id, owner: owner) else {
                    throw HostRuntimeError.notFound("Placement not found")
                }
                return .placement(record)
            case .create(let id, let intent), .createInDevContainer(let id, let intent):
                let containerRequest: Bool
                if case .createInDevContainer = request { containerRequest = true } else { containerRequest = false }
                guard containerRequest == (intent.devContainer != nil) else {
                    throw HostRuntimeError.invalid("Container placement requires the explicit container request type")
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
                    await performPlacement(id: id, intent: intent)
                }
                return .placement(admitted)
            }
        } catch {
            return .error(code: "placement-failed", message: String(describing: error), forceAllowed: false, shortStatus: nil)
        }
    }

    private func performPlacement(id: UUID, intent: HostPlacementIntent) async {
        do {
            try Task.checkCancellation()
            let prepare: (@MainActor @Sendable (String) async throws -> Void)?
            if let request = intent.devContainer {
                prepare = { [self] path in
                    let environment = try await devContainers.prepare(workspace: path, configuration: request.configuration, operationID: id)
                    try placements.recordEnvironment(operationID: id, environment: environment)
                }
            } else { prepare = nil }
            let created = try await createWorktree(repository: intent.repositoryID, name: intent.worktreeName, branch: intent.branchName,
                relativeGitPaths: intent.devContainer != nil, prepareEnvironment: prepare)
            try placements.complete(operationID: id, worktreeID: created.path, paneID: created.session)
        } catch {
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

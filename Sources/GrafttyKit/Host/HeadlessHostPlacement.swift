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
            case .create(let id, let intent):
                // Check ownership and immutable arguments before any filesystem or Git work.
                if try placements.status(operationID: id, owner: owner) != nil {
                    return .placement(try placements.admit(operationID: id, owner: owner, intent: intent, sample: nil))
                }
                guard state.repos.contains(where: { $0.path == intent.repositoryID }) else {
                    throw HostRuntimeError.notFound("Repository must be registered on this host before placement")
                }
                if let error = WorktreeCreationInput.validationError(worktreeName: intent.worktreeName, branchName: intent.branchName) {
                    throw HostRuntimeError.invalid(error)
                }
                guard !FileManager.default.fileExists(atPath: intent.worktreePath), state.worktree(forPath: intent.worktreePath) == nil else {
                    throw HostRuntimeError.invalid("Worktree destination already exists")
                }
                // Probe the nearest existing parent, including nested .worktrees mounts.
                // createWorktree repeats symlink and destination checks before Git runs.
                let diskPath = try placementDiskPath(for: intent)
                var sample = hostResources
                sample?.diskPath = diskPath
                sample?.diskAvailableBytes = HostResourceSampler.availableDiskBytes(at: diskPath)
                sample?.pendingWorktreeOperations = busyPaths.count
                _ = try placements.admit(operationID: id, owner: owner, intent: intent, sample: sample, filesystemPath: diskPath)
                do {
                    let created = try await createWorktree(repository: intent.repositoryID, name: intent.worktreeName, branch: intent.branchName)
                    try placements.complete(operationID: id, worktreeID: created.path, paneID: created.session)
                } catch {
                    // Git may have succeeded even if shell startup or persistence failed.
                    // Keep the claim and operation identity so a retry cannot duplicate it.
                    try placements.markOutcomeUnknown(operationID: id, message: String(describing: error))
                }
                guard let result = try placements.status(operationID: id, owner: owner) else {
                    throw HostRuntimeError.notFound("Placement result missing")
                }
                return .placement(result)
            }
        } catch {
            return .error(code: "placement-failed", message: String(describing: error), forceAllowed: false, shortStatus: nil)
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

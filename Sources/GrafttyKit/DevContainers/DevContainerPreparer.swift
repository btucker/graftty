import Foundation
import GrafttyProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Uses upstream parsing and lifecycle execution. This component does not install
/// tools, add credential mounts, forward agents, or declare an agent authenticated.
public actor DevContainerPreparer {
    private let executor: any CLIExecutor
    private var preparing: Set<String> = []
    public init(executor: any CLIExecutor = CLIRunner()) { self.executor = executor }

    public func checkRelativeWorktreeSupport(at workspace: String) async throws {
        for command in ["read-configuration", "up", "exec"] {
            let help = try await run([command, "--help"], at: workspace, stage: "compatibility", timeout: .seconds(5))
            guard help.stdout.contains("--mount-git-worktree-common-dir") else {
                throw DevContainerPreparationError(stage: "compatibility", message: "Install a Dev Container CLI supporting relative Git worktree common-directory mounts")
            }
        }
    }

    public func prepare(workspace rawWorkspace: String, configuration: String? = nil, operationID: UUID) async throws -> PreparedDevContainer {
        guard rawWorkspace.hasPrefix("/") else { throw DevContainerPreparationError(stage: "configuration", message: "Workspace must be absolute") }
        let workspace = CanonicalPath.canonicalize(rawWorkspace)
        guard workspace.hasPrefix("/"), preparing.insert(workspace).inserted else {
            throw DevContainerPreparationError(stage: "configuration", message: "Workspace must be absolute and cannot already be preparing")
        }
        defer { preparing.remove(workspace) }
        let config = try configurationFile(workspace: workspace, selected: configuration)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: config))
        let contents: Data
        do { contents = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard contents.count <= 1024 * 1024 else {
            throw DevContainerPreparationError(stage: "configuration", message: "Dev Container configuration exceeds 1 MiB")
        }
        let relativeGit = try usesRelativeWorktree(at: workspace)
        if relativeGit { try await checkRelativeWorktreeSupport(at: workspace) }
        var common = ["--workspace-folder", workspace, "--config", config, "--mount-workspace-git-root", "false"]
        if relativeGit { common += ["--mount-git-worktree-common-dir", "true"] }
        let read = try await run(["read-configuration"] + common, at: workspace, stage: "configuration", timeout: .seconds(60))
        guard let configuration = try json(read.stdout, stage: "configuration")["configuration"] as? [String: Any] else {
            throw DevContainerPreparationError(stage: "configuration", message: "CLI did not return a resolved configuration")
        }
        guard configuration["dockerComposeFile"] == nil else {
            throw DevContainerPreparationError(stage: "configuration", message: "Compose preparation is not yet supported; use an image or Dockerfile configuration")
        }
        let label = "graftty.placement=\(operationID.uuidString.lowercased())"
        let workspaceLabel = "graftty.workspace=" + SHA256.hash(data: Data(workspace.utf8)).map { String(format: "%02x", $0) }.joined()
        let up = try await run(["up"] + common + ["--id-label", label, "--id-label", workspaceLabel], at: workspace, stage: "lifecycle", timeout: .seconds(1800))
        let output = try json(up.stdout, stage: "lifecycle")
        guard output["outcome"] as? String == "success", let containerID = output["containerId"] as? String,
              containerID.count == 64, containerID.allSatisfy({ "0123456789abcdef".contains($0) }), let remoteFolder = output["remoteWorkspaceFolder"] as? String,
              validValue(remoteFolder), remoteFolder.hasPrefix("/") else {
            throw DevContainerPreparationError(stage: "lifecycle", message: "CLI did not return a complete successful container result")
        }
        // Up can print success before background lifecycle tasks finish. run waits
        // for process exit before this check, including a later non-zero exit.
        _ = try await run(["exec"] + common + ["--container-id", containerID, "git", "status", "--porcelain"],
            at: workspace, stage: "git-access", timeout: .seconds(60))
        guard try Data(contentsOf: URL(fileURLWithPath: config)) == contents else {
            throw DevContainerPreparationError(stage: "configuration-changed", message: "Configuration changed while preparing; the container is not reported prepared")
        }
        return PreparedDevContainer(containerID: containerID, workspace: workspace, configurationPath: config,
            configurationDigest: SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined(),
            remoteWorkspaceFolder: remoteFolder, remoteUser: output["remoteUser"] as? String, usesRelativeGitWorktree: relativeGit)
    }

    public nonisolated static func shellCommand(for environment: PreparedDevContainer, command: String? = nil) -> String {
        var args = ["devcontainer", "exec", "--container-id", environment.containerID,
                    "--workspace-folder", environment.workspace, "--config", environment.configurationPath,
                    "--mount-workspace-git-root", "false"]
        if environment.usesRelativeGitWorktree { args += ["--mount-git-worktree-common-dir", "true"] }
        if let command { args += ["/bin/sh", "-lc", command + "\nexec /bin/sh -l"] }
        else { args += ["/bin/sh", "-l"] }
        return "exec " + args.map(WorktreeAgentLaunchCommand.shellLiteral).joined(separator: " ")
    }

    /// Labels locate resources for an already authenticated, retained operation.
    /// They never authorize a peer or establish parent identity.
    public func findPlacementContainer(operationID: UUID, workspace: String) async throws -> String? {
        let workspaceHash = SHA256.hash(data: Data(workspace.utf8)).map { String(format: "%02x", $0) }.joined()
        let output = try await docker(["ps", "--all", "--quiet", "--no-trunc",
            "--filter", "label=graftty.placement=" + operationID.uuidString.lowercased(),
            "--filter", "label=graftty.workspace=" + workspaceHash])
        let ids = output.stdout.split(whereSeparator: \.isWhitespace).map(String.init)
        guard ids.count <= 1, ids.allSatisfy(Self.validContainerID) else {
            throw DevContainerPreparationError(stage: "cleanup", message: "Placement container discovery is ambiguous; inspect the retained operation before deleting")
        }
        return ids.first
    }

    /// Return whether a rejected deletion needs to restart the container.
    public func stopForDeletion(containerID: String) async throws -> Bool {
        guard try await containerExists(containerID) else { return false }
        let state = try await docker(["inspect", "--format", "{{.State.Running}}", containerID])
        let running = state.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard running == "true" || running == "false" else {
            throw DevContainerPreparationError(stage: "cleanup", message: "Docker returned an unknown running state")
        }
        if running == "true" { _ = try await docker(["stop", "--timeout", "10", containerID]) }
        return running == "true"
    }
    public func restartAfterRejectedDeletion(containerID: String) async throws {
        guard Self.validContainerID(containerID) else { throw DevContainerPreparationError(stage: "cleanup", message: "Invalid retained container ID") }
        _ = try await docker(["start", containerID])
    }
    public func removeStoppedContainer(containerID: String) async throws {
        guard try await containerExists(containerID) else { return }
        // Do not remove volumes or force-kill a container that another actor restarted.
        _ = try await docker(["rm", containerID])
    }
    private static func validContainerID(_ id: String) -> Bool { id.count == 64 && id.allSatisfy { "0123456789abcdef".contains($0) } }
    private func containerExists(_ id: String) async throws -> Bool {
        guard Self.validContainerID(id) else { throw DevContainerPreparationError(stage: "cleanup", message: "Invalid retained container ID") }
        let output = try await docker(["ps", "--all", "--quiet", "--no-trunc", "--filter", "id=" + id])
        let ids = output.stdout.split(whereSeparator: \.isWhitespace).map(String.init)
        guard ids.isEmpty || ids == [id] else {
            throw DevContainerPreparationError(stage: "cleanup", message: "Docker returned an unexpected container identity")
        }
        return !ids.isEmpty
    }
    private func docker(_ args: [String]) async throws -> CLIOutput {
        do {
            let result = try await executor.run(command: "docker", args: args, at: NSHomeDirectory(), timeout: .seconds(30))
            guard result.exitCode == 0 else { throw DevContainerPreparationError(stage: "cleanup", message: "Docker exited with status \(result.exitCode)") }
            return result
        } catch { throw DevContainerPreparationError(stage: "cleanup", message: String(describing: error)) }
    }

    private func run(_ args: [String], at workspace: String, stage: String, timeout: Duration) async throws -> CLIOutput {
        try Task.checkCancellation()
        do {
            let result = try await executor.run(command: "devcontainer", args: args, at: workspace, timeout: timeout)
            guard result.exitCode == 0 else { throw DevContainerPreparationError(stage: stage, message: "CLI exited with status \(result.exitCode)") }
            try Task.checkCancellation()
            return result
        } catch is CancellationError { throw CancellationError() }
        catch { throw DevContainerPreparationError(stage: stage, message: String(describing: error)) }
    }

    private func json(_ text: String, stage: String) throws -> [String: Any] {
        guard text.utf8.count <= 8 * 1024 * 1024,
              let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw DevContainerPreparationError(stage: stage, message: "CLI returned invalid or oversized JSON")
        }
        return value
    }
    private func validValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private func configurationFile(workspace: String, selected: String?) throws -> String {
        let candidates = selected.map { [$0] } ?? [".devcontainer/devcontainer.json", ".devcontainer.json"]
        for candidate in candidates {
            guard !candidate.hasPrefix("/"), !candidate.split(separator: "/").contains("..") else {
                throw DevContainerPreparationError(stage: "configuration", message: "Configuration must be inside the worktree")
            }
            let path = CanonicalPath.canonicalize((workspace as NSString).appendingPathComponent(candidate))
            guard path.hasPrefix(workspace + "/") else {
                throw DevContainerPreparationError(stage: "configuration", message: "Configuration escapes the worktree")
            }
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue { return path }
        }
        throw DevContainerPreparationError(stage: "configuration", message: "No selected Dev Container configuration exists; use the project-setup skill")
    }
    private func usesRelativeWorktree(at workspace: String) throws -> Bool {
        let git = (workspace as NSString).appendingPathComponent(".git")
        let attributes = try FileManager.default.attributesOfItem(atPath: git)
        if attributes[.type] as? FileAttributeType == .typeDirectory { return false }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 4096 else {
            throw DevContainerPreparationError(stage: "git-layout", message: "Unsupported Git metadata layout")
        }
        let value = try String(contentsOfFile: git, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("gitdir: "), !value.dropFirst(8).isEmpty, !value.dropFirst(8).hasPrefix("/"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DevContainerPreparationError(stage: "git-layout", message: "Linked worktrees require relative Git metadata; existing absolute metadata is not rewritten automatically")
        }
        return true
    }
}

public struct DevContainerPreparationError: Error, Sendable, CustomStringConvertible {
    public let stage: String
    public let message: String
    public var description: String { "Dev Container \(stage): \(message)" }
}

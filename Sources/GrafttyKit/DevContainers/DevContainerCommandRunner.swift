import Foundation
#if os(Linux)
import func Subprocess.run
import struct Subprocess.PlatformOptions
#endif

/// Lifecycle commands can leave Docker attachment processes running. Linux
/// Foundation.Process waits for descendants holding its termination socket;
/// use Swift's subprocess package to observe the actual command's exit instead.
public struct DevContainerCommandRunner: CLIExecutor {
    public init() {}

    public func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory, timeout: nil)
    }

    public func run(command: String, args: [String], at directory: String, timeout: Duration?) async throws -> CLIOutput {
        let result = try await capture(command: command, args: args, at: directory, timeout: timeout)
        guard result.exitCode == 0 else {
            throw CLIError.nonZeroExit(command: command, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    public func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await capture(command: command, args: args, at: directory, timeout: nil)
    }

    public func capture(command: String, args: [String], at directory: String, timeout: Duration?) async throws -> CLIOutput {
        #if os(Linux)
        do {
            return try await withThrowingTaskGroup(of: CLIOutput.self) { group in
                defer { group.cancelAll() }
                group.addTask { try await runLinuxContainerCommand(command: command, args: args, directory: directory) }
                if let timeout {
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw CLIError.timedOut(command: command, seconds: Subprocess.seconds(of: timeout))
                    }
                }
                return try await group.next()!
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as CLIError { throw error }
        catch { throw CLIError.launchFailed(command: command, message: error.localizedDescription) }
        #else
        return try await CLIRunner(terminatesOnCancellation: true).capture(command: command, args: args, at: directory, timeout: timeout)
        #endif
    }
}

#if os(Linux)
private func runLinuxContainerCommand(command: String, args: [String], directory: String) async throws -> CLIOutput {
    try Task.checkCancellation()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-container-command-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let stdout = root.appendingPathComponent("stdout")
    let stderr = root.appendingPathComponent("stderr")
    try Data().write(to: stdout)
    try Data().write(to: stderr)
    let out = try FileHandle(forWritingTo: stdout)
    defer { try? out.close() }
    let err = try FileHandle(forWritingTo: stderr)
    defer { try? err.close() }
    var options = PlatformOptions()
    options.createSession = true
    // Swift Subprocess 1.0.0 cancels graceful teardown when the leader exits,
    // which can skip its final group KILL while TERM-ignoring children survive.
    // Kill the isolated group in the first step, before the leader is reaped.
    // Successful completion never runs teardown and retains background helpers.
    options.teardownSequence = [.send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero)]
    // File capture also prevents a descendant's inherited stdout/stderr from
    // delaying completion. The files are private and unlinked after exit.
    let result = try await run(.path("/usr/bin/env"), arguments: .init([command] + args),
        environment: .inherit.updating(["PATH": CLIRunner.enrichedEnvironment()["PATH"], "LC_ALL": "C"]), workingDirectory: .init(directory),
        platformOptions: options, input: .none,
        output: .fileDescriptor(.init(rawValue: out.fileDescriptor), closeAfterSpawningProcess: false),
        error: .fileDescriptor(.init(rawValue: err.fileDescriptor), closeAfterSpawningProcess: false))
    try Task.checkCancellation()
    let status: Int32
    switch result.terminationStatus {
    case .exited(let code): status = code
    case .signaled(let signal): status = signal
    }
    return CLIOutput(stdout: String(decoding: try Data(contentsOf: stdout), as: UTF8.self),
        stderr: String(decoding: try Data(contentsOf: stderr), as: UTF8.self), exitCode: status)
}
#endif

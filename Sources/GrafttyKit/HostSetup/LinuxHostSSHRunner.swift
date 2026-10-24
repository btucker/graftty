import Foundation

public protocol LinuxHostSSHExecuting: Sendable {
    func capture(arguments: [String], inputFile: URL?) async throws -> CLIOutput
}

/// System OpenSSH needs stdin for binary archives and trust JSON. CLIRunner
/// remains the local Git/SSH-config executor; this runner adds file stdin,
/// file-backed output, and cancellation for bootstrap connections without an
/// intervening shell.
public struct LinuxHostSSHRunner: LinuxHostSSHExecuting {
    let executable: String
    let timeout: TimeInterval
    let directory: String?
    private let scheduler: SubprocessScheduler

    public init() {
        scheduler = .dispatch
        executable = "/usr/bin/ssh"
        timeout = 600
        directory = nil
    }

    init(executable: String, timeout: TimeInterval, directory: String? = nil, scheduler: SubprocessScheduler = .dispatch) {
        self.scheduler = scheduler
        self.executable = executable
        self.timeout = timeout
        self.directory = directory
    }

    public func capture(arguments: [String], inputFile: URL?) async throws -> CLIOutput {
        try Task.checkCancellation()
        var launch = SubprocessLaunch(
            executable: executable,
            arguments: arguments,
            directory: directory,
            standardInput: inputFile ?? URL(fileURLWithPath: "/dev/null"),
            capture: .files,
            timeout: .seconds(timeout),
            timeoutLabel: "ssh",
            terminatesOnCancellation: true
        )
        launch.scheduler = scheduler
        let output = try await Subprocess.run(launch)
        return CLIOutput(
            stdout: String(decoding: output.stdout, as: UTF8.self),
            stderr: String(decoding: output.stderr, as: UTF8.self),
            exitCode: output.status
        )
    }
}

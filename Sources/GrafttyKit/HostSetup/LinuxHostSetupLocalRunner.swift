import Foundation

/// Keep CLIRunner for bounded local probes. Bundle creation can take minutes
/// for a large project, so it uses the cancellable file-backed process runner.
struct LinuxHostSetupLocalRunner: CLIExecutor {
    private let runner = CLIRunner()

    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await capture(command: command, args: args, at: directory, timeout: .seconds(15))
    }

    func capture(command: String, args: [String], at directory: String, timeout: Duration?) async throws -> CLIOutput {
        try Task.checkCancellation()
        let output: CLIOutput
        if command == "git", args.starts(with: ["bundle", "create"]) {
            let process = LinuxHostSSHRunner(executable: "/usr/bin/env", timeout: 300, directory: directory)
            output = try await process.capture(arguments: [command] + args, inputFile: nil)
        } else {
            output = try await runner.capture(command: command, args: args, at: directory, timeout: timeout)
        }
        try Task.checkCancellation()
        return output
    }

    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory, timeout: .seconds(15))
    }

    func run(command: String, args: [String], at directory: String, timeout: Duration?) async throws -> CLIOutput {
        let output = try await capture(command: command, args: args, at: directory, timeout: timeout)
        guard output.exitCode == 0 else {
            throw CLIError.nonZeroExit(command: command, exitCode: output.exitCode, stderr: output.stderr)
        }
        return output
    }
}

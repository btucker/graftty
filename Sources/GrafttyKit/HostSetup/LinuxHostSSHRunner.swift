import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public protocol LinuxHostSSHExecuting: Sendable {
    func capture(arguments: [String], inputFile: URL?) async throws -> CLIOutput
}

/// System OpenSSH needs stdin for binary archives and trust JSON. CLIRunner
/// remains the local Git/SSH-config executor; this runner adds file stdin and
/// cancellation for bootstrap connections without an intervening shell.
public struct LinuxHostSSHRunner: LinuxHostSSHExecuting {
    let executable: String
    let timeout: TimeInterval
    let directory: String?

    public init() {
        executable = "/usr/bin/ssh"
        timeout = 600
        directory = nil
    }

    init(executable: String, timeout: TimeInterval, directory: String? = nil) {
        self.executable = executable
        self.timeout = timeout
        self.directory = directory
    }

    public func capture(arguments: [String], inputFile: URL?) async throws -> CLIOutput {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        let stdin = try FileHandle(forReadingFrom: inputFile ?? URL(fileURLWithPath: "/dev/null"))
        defer { try? stdout.close(); try? stderr.close(); try? stdin.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = self.directory.map { URL(fileURLWithPath: $0) }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = CLIRunner.enrichedEnvironment()
        let state = LinuxHostSSHProcessState(process: process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { [weak state] process in
                    state?.finish()
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try state.start()
                    let timer = DispatchWorkItem { [weak state] in state?.stop(timedOut: true) }
                    state.setTimer(timer)
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                } catch {
                    state.finish()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            state.stop(timedOut: false)
        }
        try Task.checkCancellation()
        if state.didTimeout { throw CLIError.timedOut(command: "ssh", seconds: timeout) }
        return CLIOutput(
            stdout: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self),
            exitCode: status
        )
    }
}

private final class LinuxHostSSHProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false
    private var finished = false
    private var timeout = false
    private var timer: DispatchWorkItem?

    init(process: Process) { self.process = process }
    var didTimeout: Bool { lock.lock(); defer { lock.unlock() }; return timeout }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
    }

    func setTimer(_ timer: DispatchWorkItem) {
        lock.lock(); defer { lock.unlock() }
        if finished { timer.cancel() } else { self.timer = timer }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
        timer?.cancel()
        timer = nil
    }

    func stop(timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        cancelled = true
        timeout = timedOut
        guard process.isRunning else { return }
        process.terminate()
        // OpenSSH normally exits on SIGTERM. Bound a wedged child too, and
        // check the same Process before killing so a completed PID isn't used.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if !self.finished, self.process.isRunning {
                _ = kill(self.process.processIdentifier, SIGKILL)
            }
        }
    }
}

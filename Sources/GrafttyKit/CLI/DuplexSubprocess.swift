import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owns a byte-stream proxy and its process group. Close any duplicated stream
/// descriptors (for example an SSH channel) before stopping the proxy.
public final class DuplexSubprocess: @unchecked Sendable {
    public let processID: Int32
    public let input: FileHandle
    public let output: FileHandle
    private let errors: FileHandle
    private let lifecycle = NSLock()
    private let diagnosticLock = NSLock()
    private var stopped = false
    private var diagnosticBytes = Data()

    public convenience init(command: String, arguments: [String]) throws {
        try self.init(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [command] + arguments,
                      environment: CLIRunner.enrichedEnvironment())
    }

    public init(executable: URL, arguments: [String], environment: [String: String]) throws {
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let handles = [stdin.fileHandleForReading, stdin.fileHandleForWriting,
                       stdout.fileHandleForReading, stdout.fileHandleForWriting,
                       stderr.fileHandleForReading, stderr.fileHandleForWriting]
        // Each child gets only its standard streams, even when another proxy
        // starts while these descriptors are still open in the parent.
        for handle in handles {
            guard fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        processID = try SpawnedProcessGroup.spawn(executable: executable, args: arguments, env: environment,
            standardInput: stdin.fileHandleForReading.fileDescriptor,
            standardOutput: stdout.fileHandleForWriting.fileDescriptor,
            standardError: stderr.fileHandleForWriting.fileDescriptor,
            closeDescriptors: handles.map(\.fileDescriptor))
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        errors.readabilityHandler = { [weak self] handle in
            guard let chunk = Subprocess.drainChunk(from: handle) else {
                handle.readabilityHandler = nil
                return
            }
            self?.appendDiagnostics(chunk)
        }
    }

    public var diagnostics: String {
        diagnosticLock.withLock { String(decoding: diagnosticBytes, as: UTF8.self) }
    }

    public func stop() async {
        await Task.detached { self.stopSynchronously() }.value
    }

    private func appendDiagnostics(_ chunk: Data) {
        diagnosticLock.withLock {
            diagnosticBytes.append(chunk)
            if diagnosticBytes.count > 65536 {
                diagnosticBytes = Data(diagnosticBytes.suffix(65536))
            }
        }
    }

    private func stopSynchronously() {
        lifecycle.withLock {
            guard !stopped else { return }
            stopped = true
            // Retain the unreaped leader until after signalling the entire group.
            // Otherwise an exited AWS CLI could leave its plugin behind, or its
            // PID could be reused before cleanup signals it.
            _ = killpg(processID, SIGKILL)
            var status: Int32 = 0
            while waitpid(processID, &status, 0) == -1 && errno == EINTR {}
            try? input.close()
            try? output.close()
            errors.readabilityHandler = nil
            try? errors.close()
        }
    }

    deinit { stopSynchronously() }
}

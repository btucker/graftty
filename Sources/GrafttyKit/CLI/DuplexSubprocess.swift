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
    private let shutdown = NSLock()
    private let diagnosticState = DiagnosticState()

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
        let errorDescriptor = errors.fileDescriptor
        // Retain only read state. Retaining the owner here could run its deinit
        // on FileHandle's monitoring queue and make close() sync onto itself.
        errors.readabilityHandler = { [diagnosticState] handle in
            if !diagnosticState.read(from: errorDescriptor) {
                // Foundation may synchronize with callbacks during teardown.
                // The read-state lock must already be released.
                handle.readabilityHandler = nil
            }
        }
    }

    public var diagnostics: String { diagnosticState.text }

    public func stop() async {
        await Task.detached { self.stopSynchronously() }.value
    }

    fileprivate func stopSynchronously() {
        // All callers wait for the entire shutdown, including descriptor close.
        // Callbacks never acquire this lock, so Foundation may wait for them.
        shutdown.withLock {
            guard diagnosticState.stopReading() else { return }
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

    private final class DiagnosticState: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var bytes = Data()

        var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }

        func read(from descriptor: Int32) -> Bool {
            lock.withLock {
                // Do not read a descriptor closed and reused after shutdown.
                guard !stopped, let chunk = Subprocess.drainChunk(fd: descriptor) else { return false }
                bytes.append(chunk)
                if bytes.count > 65536 { bytes = Data(bytes.suffix(65536)) }
                return true
            }
        }

        func stopReading() -> Bool {
            lock.withLock {
                guard !stopped else { return false }
                stopped = true
                return true
            }
        }
    }
}

/// Tracks children without extending their normal lifetime. App termination can
/// close this scope synchronously even after its async executor stops running.
public final class DuplexSubprocessScope: @unchecked Sendable {
    private struct Child { weak var process: DuplexSubprocess? }
    private let lock = NSLock()
    private var children: [Child] = []
    private var closed = false
    public init() {}

    /// Creation and registration share the shutdown lock, so app termination
    /// cannot miss a process spawned just before it takes its child snapshot.
    public func launch(_ create: () throws -> DuplexSubprocess) throws -> DuplexSubprocess {
        try lock.withLock {
            guard !closed else { throw CancellationError() }
            let process = try create()
            children.removeAll { $0.process == nil }
            children.append(Child(process: process))
            return process
        }
    }

    public func close() {
        let processes = lock.withLock {
            closed = true
            let live = children.compactMap(\.process)
            children.removeAll()
            return live
        }
        for process in processes { process.stopSynchronously() }
    }

    deinit { close() }
}

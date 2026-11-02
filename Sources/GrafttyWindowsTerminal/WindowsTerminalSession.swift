#if os(Windows)
import Foundation
import CGrafttyConPTY

/// One native Windows pseudoconsole. This owns the shell, not an attachment to
/// a persistent broker. Closing it terminates the attached process tree.
/// Output arrives on a dedicated thread and must be consumed promptly.
public final class WindowsTerminalSession: @unchecked Sendable {
    public struct Failure: Swift.Error, CustomStringConvertible, Sendable {
        public let operation: String
        public let code: UInt32
        public var description: String { "\(operation) failed with Windows error \(code)" }
    }

    private final class Output: @unchecked Sendable {
        let consume: @Sendable (Data) -> Void
        init(_ consume: @escaping @Sendable (Data) -> Void) { self.consume = consume }
    }

    private let session: OpaquePointer
    private let output: Output

    /// Pass an absolute executable path. `arguments` excludes argv[0]. An
    /// omitted environment inherits the parent environment. The callback must
    /// not call session methods or release the last reference to this session.
    public init(executable: String, arguments: [String], directory: String,
                environment: [String: String]? = nil, columns: Int = 80, rows: Int = 24,
                onOutput: @escaping @Sendable (Data) -> Void) throws {
        guard let columns = Int16(exactly: columns), columns > 0,
              let rows = Int16(exactly: rows), rows > 0,
              !directory.isEmpty, !directory.utf16.contains(0) else {
            throw Failure(operation: "validate launch", code: 87)
        }
        let command = try WindowsTerminalLaunch.commandLine(arguments: [executable] + arguments)
        let executableUTF16 = Array(executable.utf16) + [0]
        let commandUTF16 = Array(command.utf16) + [0]
        let directoryUTF16 = Array(directory.utf16) + [0]
        let environmentUTF16 = try environment.map(WindowsTerminalLaunch.environmentBlock)
        let output = Output(onOutput)
        self.output = output
        var session: OpaquePointer?
        let callback: graftty_conpty_output = { context, bytes, count in
            guard let context, let bytes else { return }
            Unmanaged<Output>.fromOpaque(context).takeUnretainedValue().consume(Data(bytes: bytes, count: count))
        }
        let create: (UnsafePointer<UInt16>?) -> UInt32 = { environment in
            graftty_conpty_create(executableUTF16, commandUTF16, directoryUTF16, environment,
                columns, rows, callback, Unmanaged.passUnretained(output).toOpaque(), &session)
        }
        let result = environmentUTF16.map { $0.withUnsafeBufferPointer { create($0.baseAddress) } } ?? create(nil)
        guard result == 0, let session else { throw Failure(operation: "create pseudoconsole", code: result) }
        self.session = session
    }

    deinit {
        graftty_conpty_destroy(session)
        withExtendedLifetime(output) {}
    }

    /// May block until the child consumes input. Call off the main actor and
    /// network event loop. Concurrent close interrupts a blocked write.
    public func write(_ data: Data) throws {
        let result = data.withUnsafeBytes {
            graftty_conpty_write(session, $0.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        try check(result, operation: "write terminal input")
    }

    public func resize(columns: Int, rows: Int) throws {
        guard let columns = Int16(exactly: columns), columns > 0,
              let rows = Int16(exactly: rows), rows > 0 else {
            throw Failure(operation: "validate terminal size", code: 87)
        }
        try check(graftty_conpty_resize(session, columns, rows), operation: "resize pseudoconsole")
    }

    /// Returns nil on timeout. Output may still be draining after process exit.
    public func wait(milliseconds: UInt32) throws -> UInt32? {
        var code: UInt32 = 0
        let result = graftty_conpty_wait(session, milliseconds, &code)
        if result == 1460 { return nil } // ERROR_TIMEOUT
        try check(result, operation: "wait for terminal process")
        return code
    }

    /// Idempotent. Drains final output before returning. Run off the UI actor.
    public func close() throws {
        try check(graftty_conpty_close(session), operation: "close pseudoconsole")
    }

    private func check(_ code: UInt32, operation: String) throws {
        if code != 0 { throw Failure(operation: operation, code: code) }
    }
}
#endif

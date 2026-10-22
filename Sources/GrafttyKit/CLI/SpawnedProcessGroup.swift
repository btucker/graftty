import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Shared POSIX launcher for commands whose descendants must stop with their owner.
enum SpawnedProcessGroup {
    static func spawn(executable: URL, args: [String], env: [String: String],
                      standardInput: Int32? = nil, standardOutput: Int32,
                      standardError: Int32?, closeDescriptors: [Int32]) throws -> pid_t {
        #if os(Linux)
        var actions = posix_spawn_file_actions_t()
        #else
        var actions: posix_spawn_file_actions_t?
        #endif
        var rc = posix_spawn_file_actions_init(&actions)
        guard rc == 0 else { throw posixError(rc) }
        defer { posix_spawn_file_actions_destroy(&actions) }

        rc = posix_spawn_file_actions_adddup2(&actions, standardOutput, STDOUT_FILENO)
        guard rc == 0 else { throw posixError(rc) }
        if let standardInput {
            rc = posix_spawn_file_actions_adddup2(&actions, standardInput, STDIN_FILENO)
            guard rc == 0 else { throw posixError(rc) }
        }

        if let standardError {
            rc = posix_spawn_file_actions_adddup2(&actions, standardError, STDERR_FILENO)
            guard rc == 0 else { throw posixError(rc) }
        } else {
            rc = "/dev/null".withCString {
                posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, $0, O_WRONLY, 0)
            }
            guard rc == 0 else { throw posixError(rc) }
        }

        for descriptor in Set(closeDescriptors) where descriptor > STDERR_FILENO {
            rc = posix_spawn_file_actions_addclose(&actions, descriptor)
            guard rc == 0 else { throw posixError(rc) }
        }

        #if os(Linux)
        var attrs = posix_spawnattr_t()
        #else
        var attrs: posix_spawnattr_t?
        #endif
        rc = posix_spawnattr_init(&attrs)
        guard rc == 0 else { throw posixError(rc) }
        defer { posix_spawnattr_destroy(&attrs) }
        rc = posix_spawnattr_setpgroup(&attrs, 0)
        guard rc == 0 else { throw posixError(rc) }
        rc = posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        guard rc == 0 else { throw posixError(rc) }

        let argvStrings = [executable.path] + args
        let argvCStrings = argvStrings.map { strdup($0) }
        var argvPointers: [UnsafeMutablePointer<CChar>?] = argvCStrings + [nil]
        defer { argvCStrings.forEach { free($0) } }

        let envStrings = env.map { "\($0)=\($1)" }
        let envCStrings = envStrings.map { strdup($0) }
        var envPointers: [UnsafeMutablePointer<CChar>?] = envCStrings + [nil]
        defer { envCStrings.forEach { free($0) } }

        var pid: pid_t = 0
        rc = executable.path.withCString { path in
            argvPointers.withUnsafeMutableBufferPointer { argvBuffer in
                envPointers.withUnsafeMutableBufferPointer { envBuffer in
                    posix_spawn(
                        &pid,
                        path,
                        &actions,
                        &attrs,
                        argvBuffer.baseAddress!,
                        envBuffer.baseAddress!
                    )
                }
            }
        }
        guard rc == 0 else { throw posixError(rc) }

        return pid
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

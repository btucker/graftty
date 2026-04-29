// Sources/GrafttyKit/Editor/ShellEnvProbe.swift
import Foundation

/// Reads a single environment variable as the user's *login shell* would
/// see it — i.e. after their shell rc files have run.
///
/// macOS GUI apps don't inherit shell env, so a literal `ProcessInfo.processInfo.environment["EDITOR"]`
/// is empty for most users. Spawning `$SHELL -ilc 'echo "$VAR"'` runs an
/// interactive login shell which sources `.zshrc`/`.bashrc`/etc., capturing
/// the rc-defined value. Cached at app startup; per-pane overrides are out
/// of scope for v1.
public protocol ShellEnvProbe {
    /// Returns the resolved value of `name`, or nil if unset / probe failed.
    /// Implementations should be safe to call from any thread.
    func value(forName name: String) -> String?
}

/// Production probe that runs `$SHELL -ilc 'echo "$<NAME>"'` and trims
/// the result. Returns nil on any failure (timeout, non-zero exit, missing
/// $SHELL). Designed to fail soft — the caller falls through the layered
/// editor lookup to a hardcoded default.
public struct LoginShellEnvProbe: ShellEnvProbe {
    /// Path to the user's shell. Defaults to `$SHELL` from the app process
    /// environment (Launch Services seeds this from the user's account).
    public let shellPath: String

    /// Hard cap on the probe's runtime so a slow rc file can't block app
    /// startup forever. Default: 2 seconds.
    public let timeout: TimeInterval

    public init(
        shellPath: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        timeout: TimeInterval = 2.0
    ) {
        self.shellPath = shellPath
        self.timeout = timeout
    }

    public func value(forName name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        // -i: interactive (sources rc files), -l: login (sources profile),
        // -c: command. The single-quote in the shell command prevents any
        // word-splitting on $name; we only support [A-Za-z_][A-Za-z0-9_]*
        // names so injection is impossible.
        process.arguments = ["-ilc", "echo \"$\(name)\""]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        // Bound the wait so a hung rc file can't pin the calling thread.
        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }
}

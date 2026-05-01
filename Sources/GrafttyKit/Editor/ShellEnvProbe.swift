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
        return Self.parseValueOutput(data)
    }

    static func parseValueOutput(_ data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let stripped = stripTerminalControlSequences(raw)
        let lines = stripped
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isShellIntegrationLeak($0) }
        return lines.last
    }

    private static func stripTerminalControlSequences(_ raw: String) -> String {
        let scalars = Array(raw.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x1B:
                index = skipEscapeSequence(in: scalars, from: index)
            case 0x9D:
                index = skipOSCSequence(in: scalars, from: index + 1)
            case 0x00..<0x20 where scalar != "\n" && scalar != "\r" && scalar != "\t":
                index += 1
            default:
                output.append(scalar)
                index += 1
            }
        }

        return String(output)
    }

    private static func skipEscapeSequence(
        in scalars: [UnicodeScalar],
        from index: Int
    ) -> Int {
        guard index + 1 < scalars.count else { return scalars.count }
        let next = scalars[index + 1]

        switch next {
        case "]":
            return skipOSCSequence(in: scalars, from: index + 2)
        case "[":
            var cursor = index + 2
            while cursor < scalars.count {
                let value = scalars[cursor].value
                cursor += 1
                if (0x40...0x7E).contains(value) { break }
            }
            return cursor
        case "P", "^", "_":
            return skipStringTerminatedSequence(in: scalars, from: index + 2)
        default:
            return index + 2
        }
    }

    /// OSC sequences terminate at BEL (0x07) or ST (ESC `\`); DCS/SOS/PM/APC
    /// terminate at ST only. `acceptBEL` selects between them.
    private static func skipOSCSequence(
        in scalars: [UnicodeScalar],
        from index: Int
    ) -> Int {
        skipUntilStringTerminator(in: scalars, from: index, acceptBEL: true)
    }

    private static func skipStringTerminatedSequence(
        in scalars: [UnicodeScalar],
        from index: Int
    ) -> Int {
        skipUntilStringTerminator(in: scalars, from: index, acceptBEL: false)
    }

    private static func skipUntilStringTerminator(
        in scalars: [UnicodeScalar],
        from index: Int,
        acceptBEL: Bool
    ) -> Int {
        var cursor = index
        while cursor < scalars.count {
            if acceptBEL && scalars[cursor].value == 0x07 {
                return cursor + 1
            }
            if scalars[cursor].value == 0x1B,
               cursor + 1 < scalars.count,
               scalars[cursor + 1] == "\\" {
                return cursor + 2
            }
            cursor += 1
        }
        return scalars.count
    }

    private static func isShellIntegrationLeak(_ value: String) -> Bool {
        value.hasPrefix("]1337;")
    }
}

import Foundation
import Darwin
import Testing
@testable import GrafttyKit

@Suite(.serialized)
struct ShellSleepActivityTests {
    @Test("Owned interactive ZLE distinguishes its primary prompt, quiet builtin read, and nested vared input")
    func interactivePromptLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shell-zle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state")
        let hooks = directory.appendingPathComponent("hooks.zsh")
        try ShellSleepActivity.zshHooks.write(to: hooks, atomically: true, encoding: .utf8)
        let child = try PtyProcess.spawn(argv: ["/bin/zsh", "-dfi"], env: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin", "GRAFTTY_SLEEP_STATE_FILE": state.path])
        defer {
            _ = kill(child.pid, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(child.pid, &status, 0)
            close(child.masterFD)
        }
        _ = fcntl(child.masterFD, F_SETFL, O_NONBLOCK)
        func input(_ text: String) {
            let bytes = Array(text.utf8)
            #expect(bytes.withUnsafeBytes { Darwin.write(child.masterFD, $0.baseAddress, $0.count) } == bytes.count)
        }
        func waitFor(_ kind: String) throws {
            let deadline = Date().addingTimeInterval(3)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while Date() < deadline {
                _ = Darwin.read(child.masterFD, &buffer, buffer.count)
                if let contents = try? String(contentsOf: state, encoding: .utf8),
                   contents.split(separator: " ").dropFirst().first == Substring(kind) { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
            Issue.record("The isolated shell never reached \(kind)")
            throw NSError(domain: "ShellSleepActivityTests", code: 1)
        }
        input("source '\(hooks.path)'\n")
        try waitFor("prompt")
        let identity = try #require(SleepProcessReader.sample(pid: child.pid)?.identity)
        #expect(ShellSleepActivity.isAtPrompt(file: state, identity: identity))
        input("read -t 1 response\n")
        try waitFor("busy")
        #expect(!ShellSleepActivity.isAtPrompt(file: state, identity: identity))
        #expect(ProcessTreeWalker().descendants(of: child.pid) == [child.pid])
        try waitFor("prompt")
        input("vared -c response\n")
        try waitFor("unknown")
        #expect(!ShellSleepActivity.isAtPrompt(file: state, identity: identity))
        #expect(ProcessTreeWalker().descendants(of: child.pid) == [child.pid])
    }

    @Test("@spec SLEEP-31: While a shell is executing a command, has scheduled or callback work, or lacks an identity-matching prompt boundary, the application shall keep that shell awake even if it has no child processes or terminal output.", arguments: ["TMOUT=60", "CONTEXT=vared", "trap 'read -t 60 ignored' USR1", "function periodic() { :; }", "sched +1 'print later'", "function completion() { :; }; zle -C complete-word complete-word completion", "function completion() { :; }; compctl -K completion example"])
    func promptIdentityAndBusyBoundary(unsupportedWork: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shell-sleep-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state")
        let script = ShellSleepActivity.zshHooks + """

        CONTEXT=start
        _graftty_sleep_prompt
        cp "$GRAFTTY_SLEEP_STATE_FILE" "$GRAFTTY_SLEEP_STATE_FILE.prompt"
        _graftty_sleep_busy
        # A quiet builtin command has no lasting child process.
        read -t 0.01 ignored
        cp "$GRAFTTY_SLEEP_STATE_FILE" "$GRAFTTY_SLEEP_STATE_FILE.busy"
        \(unsupportedWork)
        _graftty_sleep_prompt
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", script]
        var environment = ProcessInfo.processInfo.environment
        environment["GRAFTTY_SLEEP_STATE_FILE"] = state.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let identity = SleepProcessIdentity(pid: process.processIdentifier, startTime: 1)
        #expect(ShellSleepActivity.isAtPrompt(file: state.appendingPathExtension("prompt"), identity: identity))
        #expect(!ShellSleepActivity.isAtPrompt(file: state.appendingPathExtension("busy"), identity: identity))
        #expect(!ShellSleepActivity.isAtPrompt(file: state, identity: identity))
        #expect(!ShellSleepActivity.isAtPrompt(file: state.appendingPathExtension("prompt"), identity: .init(pid: identity.pid, startTime: Int64.max)))
        #expect(!ShellSleepActivity.isAtPrompt(file: state.appendingPathExtension("prompt"), identity: identity, minimumBoundary: Date().timeIntervalSince1970 + 10))
        #expect(!ShellSleepActivity.isAtPrompt(file: directory.appendingPathComponent("missing"), identity: identity))
    }
}

import Foundation
import Testing
import GrafttyWindowsTerminal

#if os(Windows)
import WinSDK
private final class TerminalOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data) }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
}

@Suite(.serialized)
struct WindowsTerminalSessionTests {
    private var cmd: String { ProcessInfo.processInfo.environment["SystemRoot"]! + "\\System32\\cmd.exe" }
    private var directory: String { ProcessInfo.processInfo.environment["TEMP"]! }

    @Test("@spec TERM-13.4: When a native Windows terminal runs a shell, the application shall deliver its UTF-8 output through ConPTY and drain final output before close returns.")
    func outputAndClose() throws {
        let output = TerminalOutput()
        let terminal = try WindowsTerminalSession(executable: cmd,
            arguments: ["/D", "/Q", "/C", "echo graftty-native-terminal"],
            directory: directory, onOutput: { output.append($0) })
        defer { try? terminal.close() }
        #expect(try terminal.wait(milliseconds: 10_000) == 0)
        try terminal.close()
        #expect(output.text.contains("graftty-native-terminal"))
        try terminal.close()
    }

    @Test("@spec TERM-13.5: When a native Windows terminal receives input or a size change, the application shall forward it to the pseudoconsole and reject operations after close.")
    func inputAndResize() throws {
        let output = TerminalOutput()
        let terminal = try WindowsTerminalSession(executable: cmd, arguments: ["/D", "/Q"],
            directory: directory, onOutput: { output.append($0) })
        defer { try? terminal.close() }
        try terminal.resize(columns: 120, rows: 40)
        // Escape the marker so console input echo alone cannot satisfy this.
        try terminal.write(Data("echo graftty-input-^o^k\r\nexit\r\n".utf8))
        #expect(try terminal.wait(milliseconds: 10_000) == 0)
        try terminal.close()
        #expect(output.text.contains("graftty-input-ok"))
        #expect(throws: WindowsTerminalSession.Failure.self) { try terminal.write(Data("x".utf8)) }
        #expect(throws: WindowsTerminalSession.Failure.self) { try terminal.resize(columns: 80, rows: 24) }
    }

    @Test("@spec TERM-13.6: If a native Windows terminal cannot create its child process, then the application shall return a launch error and release the pseudoconsole and pipe handles.")
    func failedLaunch() throws {
        func handleCount() throws -> DWORD {
            var count: DWORD = 0
            guard GetProcessHandleCount(GetCurrentProcess(), &count) else {
                throw NSError(domain: "Win32", code: Int(GetLastError()))
            }
            return count
        }
        func failLaunch() {
            #expect(throws: WindowsTerminalSession.Failure.self) {
                try WindowsTerminalSession(executable: "C:\\graftty-does-not-exist\\shell.exe", arguments: [],
                    directory: directory, onOutput: { _ in })
            }
        }
        // Warm up process/runtime initialization before measuring repeated
        // failures, then bound how long deferred Windows cleanup may converge.
        failLaunch()
        let before = try handleCount()
        for _ in 0..<10 { failLaunch() }
        var after = try handleCount()
        let deadline = Date().addingTimeInterval(2)
        while after > before + 4 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            after = try handleCount()
        }
        #expect(after <= before + 4, "Handle counts before=\(before), after=\(after)")
    }

    @Test("@spec TERM-13.7: When a native Windows terminal uses a Unicode working directory and environment, the application shall pass both to the child without loss.")
    func unicodeLaunch() throws {
        let path = directory + "\\graftty-工具-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let output = TerminalOutput()
        let terminal = try WindowsTerminalSession(executable: cmd,
            arguments: ["/D", "/Q", "/C", "echo %GRAFTTY_NATIVE_VALUE% & cd"], directory: path,
            environment: ["SystemRoot": ProcessInfo.processInfo.environment["SystemRoot"]!, "GRAFTTY_NATIVE_VALUE": "café-工具"],
            onOutput: { output.append($0) })
        defer { try? terminal.close() }
        #expect(try terminal.wait(milliseconds: 10_000) == 0)
        try terminal.close()
        #expect(output.text.contains("café-工具"))
        #expect(output.text.contains("graftty-工具-"))
    }

    @Test("@spec TERM-13.8: If terminal input is blocked while a native Windows terminal closes, then the application shall interrupt the writer and finish shutdown without waiting for the child to read input.")
    func closeInterruptsBlockedInput() throws {
        let powershell = ProcessInfo.processInfo.environment["SystemRoot"]! + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
        let output = TerminalOutput()
        let ready = DispatchSemaphore(value: 0)
        let terminal = try WindowsTerminalSession(executable: powershell,
            arguments: ["-NoProfile", "-Command", "Write-Output 'graftty-ready'; Start-Sleep -Seconds 30"], directory: directory,
            onOutput: {
                output.append($0)
                if output.text.contains("graftty-ready") { ready.signal() }
            })
        defer { try? terminal.close() }
        try #require(ready.wait(timeout: .now() + 10) == .success)
        let writers = DispatchGroup()
        writers.enter()
        DispatchQueue.global().async {
            defer { writers.leave() }
            try? terminal.write(Data(repeating: 0x61, count: 1_048_576))
        }
        Thread.sleep(forTimeInterval: 0.1)
        try terminal.close()
        #expect(writers.wait(timeout: .now() + 5) == .success)
    }
}
#endif

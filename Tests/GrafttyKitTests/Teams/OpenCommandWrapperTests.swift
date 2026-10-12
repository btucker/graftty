import Foundation
import Testing
@testable import GrafttyKit

#if os(macOS)
struct OpenCommandWrapperTests {
    @Test("@spec PORTS-5.36: When a Mac Graftty pane invokes open with one HTTP(S) URL, the application shall route it through the pane owner without falling back after a routing failure, and shall preserve native open arguments outside a pane or for other invocations.")
    func routesURLsAndPreservesNativeOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-open-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cli = root.appendingPathComponent("graftty cli's")
        let native = root.appendingPathComponent("native-open")
        try "#!/bin/sh\nprintf 'cli\\n'\nprintf '%s\\n' \"$@\"\nexit \"${FIXTURE_CLI_STATUS:-0}\"\n".write(to: cli, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nprintf 'native\\n'\nprintf '%s\\n' \"$@\"\nexit 7\n".write(to: native, atomically: true, encoding: .utf8)
        for file in [cli, native] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        _ = try AgentHookInstaller(rootDirectory: root, grafttyCLIPath: cli.path).install()
        let wrapper = root.appendingPathComponent("bin/open")
        try #require(FileManager.default.isExecutableFile(atPath: wrapper.path))
        let script = try String(contentsOf: wrapper, encoding: .utf8)
        try script.replacingOccurrences(of: "'/usr/bin/open'", with: "'\(native.path)'")
            .write(to: wrapper, atomically: true, encoding: .utf8)
        let url = "https://example.com/authorize?state=a'b&literal=$(printf+oops)"
        for (arguments, pane, cliStatus, expected) in [
            ([url], true, 0, ["cli", "open", url]),
            (["HTTPS://example.com"], true, 0, ["cli", "open", "HTTPS://example.com"]),
            ([url], true, 9, ["cli", "open", url]),
            ([url], false, 0, ["native", url]),
            (["-a", "Safari", url], true, 0, ["native", "-a", "Safari", url]),
            (["a file.txt"], true, 0, ["native", "a file.txt"]),
            ([url, url], true, 0, ["native", url, url]),
        ] {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [wrapper.path] + arguments
            process.environment = ["PATH": "/usr/bin:/bin", "FIXTURE_CLI_STATUS": String(cliStatus)]
            if pane {
                process.environment?["GRAFTTY_SOCK"] = "/tmp/fixture.sock"
                process.environment?["ZMX_SESSION"] = "graftty-pane"
            }
            process.standardOutput = output
            try process.run()
            let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").map(String.init)
            process.waitUntilExit()
            #expect(lines == expected)
            #expect(process.terminationStatus == (expected[0] == "cli" ? Int32(cliStatus) : 7))
        }
    }
}
#endif

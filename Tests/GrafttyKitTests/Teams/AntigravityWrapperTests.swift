import Foundation
import Testing
@testable import GrafttyKit

@Suite("""
@spec AGENT-6.176: When `agy` is launched from a Graftty terminal, the wrapper shall start the real `agy` outside the wrapper directory with the caller's arguments and a server credential that Graftty's hooks can read, minting a new credential for each launch unless the caller already supplied one.
""")
struct AntigravityWrapperTests {
    @Test func launchesTheRealBinaryWithAMatchingHookReadableCredential() throws {
        let fixture = try Fixture()

        let first = try fixture.run(arguments: ["--prompt-interactive=two words", "-c"])
        let second = try fixture.run(arguments: [])

        #expect(first.arguments == ["--prompt-interactive=two words", "-c"])
        let token = try #require(first.environment["ANTIGRAVITY_SERVER_CSRF_TOKEN"])
        #expect(token.count >= 32)
        #expect(first.environment[AntigravityServerBinder.tokenEnvironmentKey] == token)
        #expect(second.environment["ANTIGRAVITY_SERVER_CSRF_TOKEN"] != token)
    }

    @Test func keepsACredentialTheCallerSupplied() throws {
        let fixture = try Fixture()

        let run = try fixture.run(arguments: [], environment: ["ANTIGRAVITY_SERVER_CSRF_TOKEN": "caller-token"])

        #expect(run.environment["ANTIGRAVITY_SERVER_CSRF_TOKEN"] == "caller-token")
        #expect(run.environment[AntigravityServerBinder.tokenEnvironmentKey] == "caller-token")
    }

    @Test func reportsAMissingRealBinary() throws {
        let fixture = try Fixture(installsRealBinary: false)

        #expect(throws: Fixture.Failure.self) { try fixture.run(arguments: []) }
    }

    @Test func installWritesTheWrapper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-antigravity-install-\(UUID().uuidString)")
        _ = try AgentHookInstaller(rootDirectory: root, grafttyCLIPath: "/usr/local/bin/graftty").install()

        #expect(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("bin/agy").path))
    }

    private struct Fixture {
        struct Run {
            let arguments: [String]
            let environment: [String: String]
        }

        struct Failure: Error {
            let status: Int32
        }

        let wrapper: URL
        let wrapperDirectory: URL
        let realDirectory: URL

        init(installsRealBinary: Bool = true) throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-antigravity-wrapper-\(UUID().uuidString)")
            wrapperDirectory = root.appendingPathComponent("wrapper bin", isDirectory: true)
            realDirectory = root.appendingPathComponent("real", isDirectory: true)
            for directory in [wrapperDirectory, realDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            wrapper = wrapperDirectory.appendingPathComponent("agy")
            try write(AgentHookInstaller.antigravityWrapperScript(wrapperDirectory: wrapperDirectory.path), to: wrapper)
            if installsRealBinary {
                // Prints its arguments one per line, a separator, then its environment.
                try write("""
                #!/bin/sh
                for argument in "$@"; do printf '%s\\n' "$argument"; done
                printf '%s\\n' '--environment--'
                env
                """, to: realDirectory.appendingPathComponent("agy"))
            }
        }

        func run(arguments: [String], environment: [String: String] = [:]) throws -> Run {
            let process = Process()
            process.executableURL = wrapper
            process.arguments = arguments
            var processEnvironment = environment
            processEnvironment["PATH"] = "\(wrapperDirectory.path):\(realDirectory.path):/usr/bin:/bin"
            process.environment = processEnvironment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure(status: process.terminationStatus) }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            let separator = lines.firstIndex(of: "--environment--") ?? lines.endIndex
            var parsed: [String: String] = [:]
            for line in lines.dropFirst(separator + 1) {
                guard let equals = line.firstIndex(of: "=") else { continue }
                parsed[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
            return Run(arguments: Array(lines[..<separator]), environment: parsed)
        }

        private func write(_ script: String, to url: URL) throws {
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
}

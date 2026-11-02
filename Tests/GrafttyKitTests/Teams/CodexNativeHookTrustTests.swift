import Foundation
import Testing
@testable import GrafttyKit
import GrafttyTestSupport

@Suite("Native Codex hook trust")
struct CodexNativeHookTrustTests {
    // Opt in with an installed Codex binary. No authentication or model call
    // is needed; every config and hook file belongs to the temporary fixture.
    @Test("Native review and disable choices survive managed rebuilds while changed hooks still require review",
          .enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_TEST_CODEX_BINARY"] != nil))
    func nativeChoicesSurviveFreshServers() throws {
        let binary = try #require(ProcessInfo.processInfo.environment["GRAFTTY_TEST_CODEX_BINARY"])
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let durable = root.appendingPathComponent("durable")
        let managed = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: durable, withIntermediateDirectories: true)
        let config = durable.appendingPathComponent("config.toml")
        let original = "model = \"fixture-before\"\n[features]\nhooks = true\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        try writeHook(command: "echo original-fixture", in: durable)
        let mirror = CodexHomeMirror(sourceDirectory: durable, mirrorDirectory: managed)
        try mirror.rebuild()

        let reviewed = try withServer(binary: binary, home: managed, root: root) { server in
            let hook = try server.hook(cwd: root)
            #expect(hook.trustStatus == "untrusted")
            try server.writeState(hook.key, field: "trusted_hash", value: hook.currentHash)
            return hook
        }
        #expect(try String(contentsOf: config, encoding: .utf8) == original)

        let refreshed = "model = \"fixture-after\"\n[features]\nhooks = true\n"
        try refreshed.write(to: config, atomically: true, encoding: .utf8)
        try mirror.rebuild()
        #expect(try String(contentsOf: managed.appendingPathComponent("config.toml"), encoding: .utf8)
            .contains("model = \"fixture-after\""))
        try withServer(binary: binary, home: managed, root: root) { server in
            let hook = try server.hook(cwd: root)
            #expect(hook.currentHash == reviewed.currentHash)
            #expect(hook.trustStatus == "trusted")
            #expect(hook.enabled)
            try server.writeState(hook.key, field: "enabled", value: false)
        }

        for _ in 0..<2 { try mirror.rebuild() }
        try withServer(binary: binary, home: managed, root: root) { server in
            let hook = try server.hook(cwd: root)
            #expect(hook.currentHash == reviewed.currentHash)
            #expect(hook.trustStatus == "trusted")
            #expect(!hook.enabled)
        }

        try writeHook(command: "echo changed-fixture", in: durable)
        try mirror.rebuild()
        try withServer(binary: binary, home: managed, root: root) { server in
            let hook = try server.hook(cwd: root)
            #expect(hook.currentHash != reviewed.currentHash)
            #expect(hook.trustStatus == "modified")
            #expect(!hook.enabled)
        }
        #expect(try String(contentsOf: config, encoding: .utf8) == refreshed)
    }

    @Test("A Graftty wrapper cannot redirect the native probe into the user's managed home")
    func rejectsGrafttyWrapperBeforeLaunch() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = root.appendingPathComponent("codex")
        try "#!/bin/sh\n# GRAFTTY_AGENT_HOOK_WRAPPER version=fixture\ntouch \"$HOME/probe-ran\"\n"
            .write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        #expect(throws: ProbeError.grafttyWrapper) {
            _ = try NativeServer(binary: wrapper.path, home: root, root: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("probe-ran").path))
    }

    private func writeHook(command: String, in home: URL) throws {
        let hooks: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": command]]]]]]
        try JSONSerialization.data(withJSONObject: hooks)
            .write(to: home.appendingPathComponent("hooks.json"), options: .atomic)
    }

    private func withServer<T>(binary: String, home: URL, root: URL, body: (NativeServer) throws -> T) throws -> T {
        let server = try NativeServer(binary: binary, home: home, root: root)
        defer { server.close() }
        return try body(server)
    }

    private struct Hook {
        let key: String
        let currentHash: String
        let trustStatus: String
        let enabled: Bool
    }

    private enum ProbeError: Error, Equatable {
        case grafttyWrapper
        case response(String)
    }

    private final class NativeServer {
        private let scope = DuplexSubprocessScope()
        private let stream: NativeAgentProbeStream
        private var nextID = 0

        init(binary: String, home: URL, root: URL) throws {
            let executable = URL(fileURLWithPath: binary)
            let file = try FileHandle(forReadingFrom: executable)
            defer { try? file.close() }
            let header = try file.read(upToCount: 256) ?? Data()
            guard !String(decoding: header, as: UTF8.self).contains("GRAFTTY_AGENT_HOOK_WRAPPER") else {
                throw ProbeError.grafttyWrapper
            }
            let child = try scope.launch {
                try DuplexSubprocess(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "cd \"$1\" && shift && exec \"$@\"", "graftty-hook-probe", root.path, executable.path, "app-server"],
                    environment: [
                        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                        "HOME": root.path, "CODEX_HOME": home.path, "GRAFTTY_DISABLE_AGENT_HOOKS": "1",
                    ])
            }
            stream = NativeAgentProbeStream(child: child)
            _ = try call("initialize", params: ["clientInfo": ["name": "graftty-hook-test", "version": "1"]])
            try stream.send(["method": "initialized", "params": [:]])
        }

        func close() { scope.close() }

        func hook(cwd: URL) throws -> Hook {
            let result = try call("hooks/list", params: ["cwds": [cwd.path]])
            let entries = try #require(result["data"] as? [[String: Any]])
            let hooks = try #require(entries.first?["hooks"] as? [[String: Any]])
            try #require(hooks.count == 1)
            let hook = hooks[0]
            return Hook(key: try #require(hook["key"] as? String),
                        currentHash: try #require(hook["currentHash"] as? String),
                        trustStatus: try #require(hook["trustStatus"] as? String),
                        enabled: try #require(hook["enabled"] as? Bool))
        }

        func writeState(_ key: String, field: String, value: Any) throws {
            let quoted = try JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            let path = "hooks.state.\(String(decoding: quoted, as: UTF8.self)).\(field)"
            _ = try call("config/value/write", params: ["keyPath": path, "value": value, "mergeStrategy": "replace"])
        }

        private func call(_ method: String, params: [String: Any]) throws -> [String: Any] {
            nextID += 1
            try stream.send(["id": nextID, "method": method, "params": params])
            let reply = try stream.receive { $0["id"] as? Int == nextID }
            if let error = reply["error"] { throw ProbeError.response(String(describing: error)) }
            return try #require(reply["result"] as? [String: Any])
        }
    }
}

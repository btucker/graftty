import Foundation
import Testing
@testable import Graftty

@Suite("Codex artwork app-server")
struct CodexArtworkClientTests {
    @Test("@spec LAYOUT-2.89: When Codex generates worktree artwork, the application shall use a separate ephemeral read-only thread, accept its completed image, and bound subprocess lifetime on failure, timeout, or cancellation.")
    func isolatedThreadAndEarlyImage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let data = try await fixture.client.generate(prompt: "Generate a fern")
        #expect(data == Data([1, 2, 3]))
        let requests = try fixture.requests()
        let start = try #require(requests.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
        #expect(start["ephemeral"] as? Bool == true)
        #expect(start["sandbox"] as? String == "read-only")
        #expect(start["approvalPolicy"] as? String == "never")
        let cwd = try #require(start["cwd"] as? String)
        #expect(!FileManager.default.fileExists(atPath: cwd))
        let config = try #require(start["config"] as? [String: Any])
        #expect((config["features"] as? [String: Bool])?["hooks"] == false)
        #expect((config["features"] as? [String: Bool])?["shell_tool"] == false)
        #expect(((config["mcp_servers"] as? [String: Any])?["example"] as? [String: Bool])?["enabled"] == false)
        #expect(!requests.contains { ["thread/resume", "turn/steer"].contains($0["method"] as? String ?? "") })
    }

    @Test func unsupportedCodexDoesNotStartTurn() async throws {
        let fixture = try Fixture(capable: false)
        defer { fixture.remove() }
        await #expect(throws: CodexArtworkClient.Failure.unavailable) {
            try await fixture.client.generate(prompt: "image")
        }
        #expect(try !fixture.requests().contains { $0["method"] as? String == "thread/start" })
    }

    @Test(arguments: ["failure", "empty", "malformed", "approval", "auth", "invalidImage", "exit"])
    func rejectsFailedTurns(mode: String) async throws {
        let fixture = try Fixture(mode: mode)
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) { try await fixture.client.generate(prompt: "image") }
    }

    @Test func timeoutAndCancellationStopAnUnresponsiveServer() async throws {
        let fixture = try Fixture(mode: "hang")
        defer { fixture.remove() }
        var client = fixture.client
        client.timeout = 0.15
        await #expect(throws: CodexArtworkClient.Failure.timedOut) { try await client.generate(prompt: "image") }
        let task = Task { try await fixture.client.generate(prompt: "image") }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func discoverySkipsHookWrappersAndFindsDesktopInstall() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let wrapper = fixture.directory.appendingPathComponent("Graftty/agent-hooks/bin")
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.binary, to: wrapper.appendingPathComponent("codex"))
        let result = CodexArtworkClient.findBinary(path: "relative:\(wrapper.path):\(fixture.directory.path)", desktopPaths: [])
        #expect(result == fixture.binary)
        #expect(CodexArtworkClient.findBinary(path: "", desktopPaths: [fixture.binary.path]) == fixture.binary)
        #expect(CodexArtworkClient.findBinary(path: "/nonexistent", desktopPaths: []) == nil)
    }

    private struct Fixture {
        let directory: URL
        var binary: URL { directory.appendingPathComponent("codex") }
        var transcript: URL { directory.appendingPathComponent("requests.jsonl") }
        var client: CodexArtworkClient {
            var client = CodexArtworkClient(binaryURL: binary)
            client.environment["GRAFTTY_TEST_TRANSCRIPT"] = transcript.path
            client.timeout = 2
            return client
        }

        init(capable: Bool = true, mode: String = "success") throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let completion: String
            switch mode {
            case "auth": completion = #"{"id":5,"error":{"code":-32000,"message":"Authentication required"}}"#
            case "invalidImage": completion = #"{"method":"item/completed","params":{"threadId":"art","item":{"type":"imageGeneration","status":"completed","result":"not base64"}}}"#
            case "failure": completion = #"{"method":"item/completed","params":{"threadId":"art","item":{"type":"imageGeneration","status":"failed","result":"","failure":{"type":"usageLimitExceeded"}}}}"#
            case "empty": completion = #"{"method":"turn/completed","params":{"threadId":"art","turn":{"status":"completed"}}}"#
            case "malformed": completion = "not json"
            case "approval": completion = #"{"id":99,"method":"item/commandExecution/requestApproval","params":{"threadId":"art"}}"#
            default: completion = #"{"method":"item/completed","params":{"threadId":"art","item":{"type":"imageGeneration","status":"completed","result":"AQID","failure":null}}}"#
            }
            let script = """
            #!/bin/sh
            while IFS= read -r line; do
              printf '%s\\n' "$line" >> "$GRAFTTY_TEST_TRANSCRIPT"
              \(mode == "hang" ? "continue" : "")
              case "$line" in
                *'"method":"initialize"'*) echo '{"id":1,"result":{}}' ;;
                *'"method":"modelProvider/capabilities/read"'*) echo '{"id":2,"result":{"imageGeneration":\(capable)}}' ;;
                *'"method":"config/read"'*) echo '{"id":3,"result":{"config":{"mcp_servers":{"example":{"enabled":true}},"plugins":{"example":{"enabled":true}}}}}' ;;
                *'"method":"thread/start"'*) echo '{"id":4,"result":{"thread":{"id":"art"}}}' ;;
                *'"method":"turn/start"'*)
                  \(mode == "exit" ? "exit 1" : "")
                  echo '\(completion)'
                  echo '{"id":5,"result":{}}'
                  ;;
              esac
            done
            """
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        func requests() throws -> [[String: Any]] {
            try String(contentsOf: transcript, encoding: .utf8).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
        }
    }
}

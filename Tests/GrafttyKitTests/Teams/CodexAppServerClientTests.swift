import Foundation
import Testing
@testable import GrafttyKit

@Suite("CodexAppServerClient", .serialized)
struct CodexAppServerClientTests {
    @Test("Single loaded thread with matching cwd starts a turn and returns the thread id.")
    func singleLoadedThreadStartsTurn() async throws {
        let fake = try makeFakeProxy(threads: ["thread-123"], cwd: "/repo/.worktrees/alice")
        let client = CodexAppServerClient(timeout: 1.0)

        let result = try await client.deliver(
            binaryPath: fake.binaryPath.path,
            socketPath: "/tmp/graftty-codex.sock",
            expectedCWD: "/repo/.worktrees/alice",
            message: "hello from team"
        )

        #expect(result == CodexAppServerDeliveryResult(threadID: "thread-123"))

        let requests = try fake.recordedRequests()
        #expect(try methods(in: requests) == [
            "initialize",
            "initialized",
            "thread/loaded/list",
            "thread/read",
            "turn/start",
        ])
        #expect(try dictionary(at: 0, in: requests)["params"].flatMap(valueDictionary)?["clientInfo"].flatMap(valueDictionary)?["name"] as? String == "graftty")
        #expect(try dictionary(at: 2, in: requests)["params"].flatMap(valueDictionary)?["limit"] as? Int == 10)
        #expect(try dictionary(at: 3, in: requests)["params"].flatMap(valueDictionary)?["threadId"] as? String == "thread-123")

        let turnParams = try #require(dictionary(at: 4, in: requests)["params"].flatMap(valueDictionary))
        #expect(turnParams["threadId"] as? String == "thread-123")
        #expect(turnParams["cwd"] as? String == "/repo/.worktrees/alice")
        let input = try #require(turnParams["input"] as? [[String: String]])
        #expect(input == [["type": "text", "text": "hello from team"]])
    }

    @Test("Zero loaded threads throws and does not start a turn.")
    func zeroLoadedThreadsThrowsWithoutStartingTurn() async throws {
        let fake = try makeFakeProxy(threads: [], cwd: "/repo/.worktrees/alice")
        let client = CodexAppServerClient(timeout: 1.0)

        try await expectDeliveryThrows(containing: "exactly one loaded thread") {
            _ = try await client.deliver(
                binaryPath: fake.binaryPath.path,
                socketPath: "/tmp/graftty-codex.sock",
                expectedCWD: "/repo/.worktrees/alice",
                message: "hello"
            )
        }

        #expect(try methods(in: fake.recordedRequests()).contains("turn/start") == false)
    }

    @Test("Multiple loaded threads throws and does not start a turn.")
    func multipleLoadedThreadsThrowsWithoutStartingTurn() async throws {
        let fake = try makeFakeProxy(threads: ["one", "two"], cwd: "/repo/.worktrees/alice")
        let client = CodexAppServerClient(timeout: 1.0)

        try await expectDeliveryThrows(containing: "exactly one loaded thread") {
            _ = try await client.deliver(
                binaryPath: fake.binaryPath.path,
                socketPath: "/tmp/graftty-codex.sock",
                expectedCWD: "/repo/.worktrees/alice",
                message: "hello"
            )
        }

        #expect(try methods(in: fake.recordedRequests()).contains("turn/start") == false)
    }

    @Test("Thread cwd mismatch throws and does not start a turn.")
    func cwdMismatchThrowsWithoutStartingTurn() async throws {
        let fake = try makeFakeProxy(threads: ["thread-123"], cwd: "/repo/other")
        let client = CodexAppServerClient(timeout: 1.0)

        try await expectDeliveryThrows(containing: "cwd mismatch") {
            _ = try await client.deliver(
                binaryPath: fake.binaryPath.path,
                socketPath: "/tmp/graftty-codex.sock",
                expectedCWD: "/repo/.worktrees/alice",
                message: "hello"
            )
        }

        #expect(try methods(in: fake.recordedRequests()).contains("turn/start") == false)
    }

    @Test("turn/start JSON-RPC error throws.")
    func turnStartRPCErrorThrows() async throws {
        let fake = try makeFakeProxy(
            threads: ["thread-123"],
            cwd: "/repo/.worktrees/alice",
            turnStartResponse: .error(message: "turn rejected")
        )
        let client = CodexAppServerClient(timeout: 1.0)

        try await expectDeliveryThrows(containing: "turn rejected") {
            _ = try await client.deliver(
                binaryPath: fake.binaryPath.path,
                socketPath: "/tmp/graftty-codex.sock",
                expectedCWD: "/repo/.worktrees/alice",
                message: "hello"
            )
        }
    }

    @Test("turn/start response without object result is accepted when it has no error.")
    func turnStartNullResultIsAccepted() async throws {
        let fake = try makeFakeProxy(
            threads: ["thread-123"],
            cwd: "/repo/.worktrees/alice",
            turnStartResponse: .nullResult
        )
        let client = CodexAppServerClient(timeout: 1.0)

        let result = try await client.deliver(
            binaryPath: fake.binaryPath.path,
            socketPath: "/tmp/graftty-codex.sock",
            expectedCWD: "/repo/.worktrees/alice",
            message: "hello"
        )

        #expect(result.threadID == "thread-123")
    }

    @Test("turn/start response missing result and error throws.")
    func turnStartMissingResultThrows() async throws {
        let fake = try makeFakeProxy(
            threads: ["thread-123"],
            cwd: "/repo/.worktrees/alice",
            turnStartResponse: .missingResult
        )
        let client = CodexAppServerClient(timeout: 1.0)

        try await expectDeliveryThrows(containing: "missing result") {
            _ = try await client.deliver(
                binaryPath: fake.binaryPath.path,
                socketPath: "/tmp/graftty-codex.sock",
                expectedCWD: "/repo/.worktrees/alice",
                message: "hello"
            )
        }
    }

    @Test("Notifications before responses are skipped while waiting for matching ids.")
    func skipsNotificationBeforeResponse() async throws {
        let fake = try makeFakeProxy(
            threads: ["thread-123"],
            cwd: "/repo/.worktrees/alice",
            notificationBeforeLoadedListResponse: true
        )
        let client = CodexAppServerClient(timeout: 1.0)

        let result = try await client.deliver(
            binaryPath: fake.binaryPath.path,
            socketPath: "/tmp/graftty-codex.sock",
            expectedCWD: "/repo/.worktrees/alice",
            message: "hello"
        )

        #expect(result.threadID == "thread-123")
    }

    @Test("Mismatched JSON-RPC response ids throw.")
    func mismatchedResponseIDThrows() async throws {
        let fake = try makeFakeProxy(
            threads: ["thread-123"],
            cwd: "/repo/.worktrees/alice",
            loadedListResponseID: 99
        )
        let client = CodexAppServerClient(timeout: 1.0)

        try await expectDeliveryThrows(containing: "expected id 2") {
            _ = try await client.deliver(
                binaryPath: fake.binaryPath.path,
                socketPath: "/tmp/graftty-codex.sock",
                expectedCWD: "/repo/.worktrees/alice",
                message: "hello"
            )
        }
    }

    @Test("Writing a large request times out when the proxy stops reading stdin.")
    func writeTimeoutWhenProxyStopsReading() async throws {
        let fake = try makeFakeProxy(
            threads: ["thread-123"],
            cwd: "/repo/.worktrees/alice",
            mode: .stopReadingAfterThreadRead
        )
        let client = CodexAppServerClient(timeout: 0.3)
        let largeMessage = String(repeating: "x", count: 2_000_000)

        try await expectDeliveryThrows(containing: "write timed out") {
            _ = try await client.deliver(
                binaryPath: fake.binaryPath.path,
                socketPath: "/tmp/graftty-codex.sock",
                expectedCWD: "/repo/.worktrees/alice",
                message: largeMessage
            )
        }
    }

    @Test("Cleanup returns when the proxy ignores SIGTERM after turn acceptance.")
    func cleanupKillsProxyThatIgnoresSIGTERM() async throws {
        let fake = try makeFakeProxy(
            threads: ["thread-123"],
            cwd: "/repo/.worktrees/alice",
            mode: .hangAfterTurnIgnoringSIGTERM
        )
        let client = CodexAppServerClient(timeout: 0.5)

        let result = try await client.deliver(
            binaryPath: fake.binaryPath.path,
            socketPath: "/tmp/graftty-codex.sock",
            expectedCWD: "/repo/.worktrees/alice",
            message: "hello"
        )

        #expect(result.threadID == "thread-123")
    }

    @Test("Closed proxy stdin before turn write is reported as write failure.")
    func closedProxyStdinBeforeTurnWriteDoesNotTerminateProcess() async throws {
        let fake = try makeFakeProxy(
            threads: ["thread-123"],
            cwd: "/repo/.worktrees/alice",
            mode: .closeStdinAfterThreadRead
        )
        let client = CodexAppServerClient(timeout: 1.0)

        try await expectDeliveryThrows(containing: "write failed") {
            _ = try await client.deliver(
                binaryPath: fake.binaryPath.path,
                socketPath: "/tmp/graftty-codex.sock",
                expectedCWD: "/repo/.worktrees/alice",
                message: "hello"
            )
        }
    }

    @Test("Subprocess receives app-server proxy socket arguments.")
    func subprocessReceivesProxyArguments() async throws {
        let fake = try makeFakeProxy(threads: ["thread-123"], cwd: "/repo/.worktrees/alice")
        let client = CodexAppServerClient(timeout: 1.0)

        _ = try await client.deliver(
            binaryPath: fake.binaryPath.path,
            socketPath: "/tmp/graftty-codex.sock",
            expectedCWD: "/repo/.worktrees/alice",
            message: "hello"
        )

        #expect(try fake.recordedArguments() == [
            "app-server",
            "proxy",
            "--sock",
            "/tmp/graftty-codex.sock",
        ])
    }

    private enum TurnStartResponse {
        case accepted
        case nullResult
        case missingResult
        case error(message: String)
    }

    private enum FakeProxyMode {
        case normal
        case stopReadingAfterThreadRead
        case closeStdinAfterThreadRead
        case hangAfterTurnIgnoringSIGTERM
    }

    private struct FakeProxy {
        let binaryPath: URL
        let argsPath: URL
        let stdinPath: URL

        func recordedArguments() throws -> [String] {
            try String(contentsOf: argsPath, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .dropLastIfEmpty()
        }

        func recordedRequests() throws -> [[String: Any]] {
            let lines = try String(contentsOf: stdinPath, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
            return try lines.map { line in
                let data = try #require(line.data(using: .utf8))
                let object = try JSONSerialization.jsonObject(with: data)
                return try #require(object as? [String: Any])
            }
        }
    }

    private func makeFakeProxy(
        threads: [String],
        cwd: String,
        turnStartResponse: TurnStartResponse = .accepted,
        loadedListResponseID: Int = 2,
        notificationBeforeLoadedListResponse: Bool = false,
        mode: FakeProxyMode = .normal
    ) throws -> FakeProxy {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-client-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let script = dir.appendingPathComponent("codex-fake")
        let args = dir.appendingPathComponent("args.txt")
        let stdin = dir.appendingPathComponent("stdin.jsonl")
        let loadedListResponse = try jsonLine([
            "jsonrpc": "2.0",
            "id": loadedListResponseID,
            "result": ["data": threads],
        ])
        let readResponse = try jsonLine([
            "jsonrpc": "2.0",
            "id": 3,
            "result": ["thread": ["cwd": cwd]],
        ])
        let turnResponse: String
        switch turnStartResponse {
        case .accepted:
            turnResponse = try jsonLine(["jsonrpc": "2.0", "id": 4, "result": [:] as [String: String]])
        case .nullResult:
            turnResponse = try jsonLine(["jsonrpc": "2.0", "id": 4, "result": NSNull()])
        case .missingResult:
            turnResponse = try jsonLine(["jsonrpc": "2.0", "id": 4])
        case .error(let message):
            turnResponse = try jsonLine([
                "jsonrpc": "2.0",
                "id": 4,
                "error": ["code": -32000, "message": message] as [String: Any],
            ])
        }
        let loadedListNotification = notificationBeforeLoadedListResponse
            ? "              printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"thread/updated\",\"params\":{}}'\n"
            : ""
        let trapTerm = mode == .hangAfterTurnIgnoringSIGTERM ? "trap '' TERM\n" : ""
        let afterThreadRead = mode == .stopReadingAfterThreadRead
            ? "              while true; do sleep 1; done\n"
            : ""
        let closeStdinAfterThreadRead = mode == .closeStdinAfterThreadRead
            ? "              exec 0<&-\n              while true; do sleep 1; done\n"
            : ""
        let afterTurn = mode == .hangAfterTurnIgnoringSIGTERM
            ? "              while true; do sleep 1; done\n"
            : ""

        let body = """
        #!/bin/sh
        \(trapTerm)
        printf '%s\\n' "$@" > '\(shellSingleQuoted(args.path))'
        : > '\(shellSingleQuoted(stdin.path))'
        n=0
        while IFS= read -r line; do
          n=$((n + 1))
          printf '%s\\n' "$line" >> '\(shellSingleQuoted(stdin.path))'
          case "$n" in
            1)
              printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
              ;;
            3)
        \(loadedListNotification)
              printf '%s\\n' '\(shellSingleQuoted(loadedListResponse))'
              ;;
            4)
              printf '%s\\n' '\(shellSingleQuoted(readResponse))'
        \(afterThreadRead)
        \(closeStdinAfterThreadRead)
              ;;
            5)
              printf '%s\\n' '\(shellSingleQuoted(turnResponse))'
        \(afterTurn)
              ;;
          esac
        done
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        return FakeProxy(binaryPath: script, argsPath: args, stdinPath: stdin)
    }

    private func jsonLine(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    private func shellSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func methods(in requests: [[String: Any]]) throws -> [String] {
        try requests.map { try #require($0["method"] as? String) }
    }

    private func dictionary(at index: Int, in requests: [[String: Any]]) throws -> [String: Any] {
        try #require(requests[safe: index])
    }

    private func valueDictionary(_ value: Any) -> [String: Any]? {
        value as? [String: Any]
    }

    private func expectDeliveryThrows(
        containing expectedDescription: String,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            Issue.record("Expected delivery to throw.")
        } catch {
            #expect(String(describing: error).contains(expectedDescription))
        }
    }
}

private extension Array where Element == String {
    func dropLastIfEmpty() -> [String] {
        guard last == "" else { return self }
        return Array(dropLast())
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

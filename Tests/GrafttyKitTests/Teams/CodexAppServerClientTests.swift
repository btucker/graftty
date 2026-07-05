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

        #expect(try fake.recordedHandshake().contains("Upgrade: websocket"))
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

    @Test("Multiple loaded threads chooses the one with matching cwd.")
    func multipleLoadedThreadsChoosesMatchingCWD() async throws {
        let fake = try makeFakeProxy(
            threads: ["one", "two"],
            cwd: "/repo/other",
            cwdByThread: ["two": "/repo/.worktrees/alice"]
        )
        let client = CodexAppServerClient(timeout: 1.0)

        let result = try await client.deliver(
            binaryPath: fake.binaryPath.path,
            socketPath: "/tmp/graftty-codex.sock",
            expectedCWD: "/repo/.worktrees/alice",
            message: "hello"
        )

        #expect(result.threadID == "two")
        let requests = try fake.recordedRequests()
        #expect(try methods(in: requests).filter { $0 == "thread/read" }.count == 2)
        #expect(try methods(in: requests).contains("turn/start"))
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

    @Test("Closed proxy stdin before turn response is reported as a timeout.")
    func closedProxyStdinBeforeTurnResponseTimesOut() async throws {
        let fake = try makeFakeProxy(
            threads: ["thread-123"],
            cwd: "/repo/.worktrees/alice",
            mode: .closeStdinAfterThreadRead
        )
        let client = CodexAppServerClient(timeout: 1.0)

        try await expectDeliveryThrows(containing: "timed out waiting for a response") {
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

    @Test("Proxy stderr is included when startup exits before the websocket handshake.")
    func proxyStartupStderrIsIncludedWhenHandshakeCloses() async throws {
        let script = try makeFailingProxy(stderr: "env: node: No such file or directory")
        let client = CodexAppServerClient(timeout: 1.0)

        try await expectDeliveryThrows(containing: "env: node: No such file or directory") {
            _ = try await client.deliver(
                binaryPath: script.path,
                socketPath: "/tmp/graftty-codex.sock",
                expectedCWD: "/repo/.worktrees/alice",
                message: "hello"
            )
        }
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
        let handshakePath: URL

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

        func recordedHandshake() throws -> String {
            try String(contentsOf: handshakePath, encoding: .utf8)
        }
    }

    private func makeFakeProxy(
        threads: [String],
        cwd: String,
        cwdByThread: [String: String] = [:],
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
        let handshake = dir.appendingPathComponent("handshake.txt")
        let threadsJSON = try jsonLine(threads)
        let cwdByThreadJSON = try jsonLine(cwdByThread)
        let turnResponseKind: String
        let turnErrorMessage: String
        switch turnStartResponse {
        case .accepted:
            turnResponseKind = "accepted"
            turnErrorMessage = ""
        case .nullResult:
            turnResponseKind = "nullResult"
            turnErrorMessage = ""
        case .missingResult:
            turnResponseKind = "missingResult"
            turnErrorMessage = ""
        case .error(let message):
            turnResponseKind = "error"
            turnErrorMessage = message
        }
        let loadedListNotification = notificationBeforeLoadedListResponse
            ? "  write_text('{\"method\":\"thread/updated\",\"params\":{}}')\n"
            : ""
        let trapTerm = mode == .hangAfterTurnIgnoringSIGTERM ? "Signal.trap('TERM', 'IGNORE')\n" : ""
        let afterThreadRead = mode == .stopReadingAfterThreadRead
            ? "  loop { sleep 1 }\n"
            : ""
        let closeStdinAfterThreadRead = mode == .closeStdinAfterThreadRead
            ? "  STDIN.close\n  loop { sleep 1 }\n"
            : ""
        let afterTurn = mode == .hangAfterTurnIgnoringSIGTERM
            ? "  loop { sleep 1 }\n"
            : ""

        let body = """
        #!/usr/bin/env ruby
        require 'json'
        STDIN.binmode
        STDOUT.binmode
        \(trapTerm)
        File.write('\(shellSingleQuoted(args.path))', ARGV.join("\\n") + "\\n")
        File.write('\(shellSingleQuoted(stdin.path))', '')

        def read_exact(count)
          data = STDIN.read(count)
          exit 0 if data.nil?
          exit 4 unless data.bytesize == count
          data
        end

        def read_frame
          first = read_exact(2).bytes
          opcode = first[0] & 0x0f
          length = first[1] & 0x7f
          masked = (first[1] & 0x80) != 0
          length = read_exact(2).unpack1('n') if length == 126
          length = read_exact(8).unpack1('Q>') if length == 127
          mask = masked ? read_exact(4).bytes : nil
          payload = read_exact(length).bytes
          payload = payload.each_with_index.map { |byte, index| byte ^ mask[index % 4] } if mask
          [opcode, payload.pack('C*').force_encoding('UTF-8')]
        end

        def write_text(text)
          bytes = text.b
          header = [0x81]
          if bytes.bytesize < 126
            header << bytes.bytesize
          elsif bytes.bytesize <= 65_535
            header << 126
            header.concat([bytes.bytesize].pack('n').bytes)
          else
            header << 127
            header.concat([bytes.bytesize].pack('Q>').bytes)
          end
          STDOUT.write(header.pack('C*'))
          STDOUT.write(bytes)
          STDOUT.flush
        end

        handshake = +''
        handshake << read_exact(1) until handshake.include?("\\r\\n\\r\\n")
        File.write('\(shellSingleQuoted(handshake.path))', handshake)
        exit 3 unless handshake.start_with?('GET ') && handshake.downcase.include?('upgrade: websocket')
        STDOUT.write("HTTP/1.1 101 Switching Protocols\\r\\nConnection: Upgrade\\r\\nUpgrade: websocket\\r\\nSec-WebSocket-Accept: test\\r\\n\\r\\n")
        STDOUT.flush

        threads = JSON.parse(<<'GRAFTTY_JSON')
        \(threadsJSON)
        GRAFTTY_JSON
        cwd_by_thread = JSON.parse(<<'GRAFTTY_JSON')
        \(cwdByThreadJSON)
        GRAFTTY_JSON
        default_cwd = '\(shellSingleQuoted(cwd))'
        turn_response_kind = '\(turnResponseKind)'
        turn_error_message = '\(shellSingleQuoted(turnErrorMessage))'

        n=0
        loop do
          opcode, line = read_frame
          exit 0 if opcode == 8
          next unless opcode == 1
          n += 1
          File.open('\(shellSingleQuoted(stdin.path))', 'a') { |file| file.puts(line) }
          request = JSON.parse(line)
          case request['method']
          when 'initialize'
            write_text(JSON.generate({ id: request['id'], result: {} }))
          when 'thread/loaded/list'
        \(loadedListNotification)
            write_text(JSON.generate({ id: \(loadedListResponseID), result: { data: threads } }))
          when 'thread/read'
            thread_id = request.dig('params', 'threadId')
            write_text(JSON.generate({ id: request['id'], result: { thread: { cwd: cwd_by_thread.fetch(thread_id, default_cwd) } } }))
        \(afterThreadRead)
        \(closeStdinAfterThreadRead)
          when 'turn/start'
            case turn_response_kind
            when 'accepted'
              write_text(JSON.generate({ id: request['id'], result: {} }))
            when 'nullResult'
              write_text(JSON.generate({ id: request['id'], result: nil }))
            when 'missingResult'
              write_text(JSON.generate({ id: request['id'] }))
            when 'error'
              write_text(JSON.generate({ id: request['id'], error: { code: -32_000, message: turn_error_message } }))
            end
        \(afterTurn)
          end
        end
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        return FakeProxy(binaryPath: script, argsPath: args, stdinPath: stdin, handshakePath: handshake)
    }

    private func makeFailingProxy(stderr: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-client-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("codex-fake")
        let body = """
        #!/bin/sh
        printf '%s\\n' '\(shellSingleQuoted(stderr))' >&2
        exit 127
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func jsonLine(_ value: Any) throws -> String {
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

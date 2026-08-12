import Foundation
import Testing
@testable import GrafttyKit

@Suite("CodexAppServerClient", .serialized)
struct CodexAppServerClientTests {
    @Test("""
    @spec AGENT-6.7: When Graftty has a hook-bound Codex thread ID, the application shall read only that exact thread immediately before delivery, inject a provenance-tagged peer message with `turn/start` while it is idle or `turn/steer` with its active turn ID while it is active, and never select another thread that shares the worktree cwd.
    """)
    func exactIdleThreadStartsWithoutDiscovery() async throws {
        let fake = try makeFakeProxy(threads: ["other"], cwd: "/same")
        let client = CodexAppServerClient(timeout: 1.0)

        let result = try await client.deliver(
            binaryPath: fake.binaryPath.path,
            socketPath: "/tmp/graftty-codex.sock",
            expectedCWD: "/same",
            message: "untrusted peer context",
            target: CodexAppServerTarget(threadID: "exact", activeTurnID: nil)
        )

        #expect(result.threadID == "exact")
        let requests = try fake.recordedRequests()
        #expect(try methods(in: requests) == ["initialize", "initialized", "thread/read", "turn/start"])
        let params = try #require(requests.last?["params"] as? [String: Any])
        #expect(params["threadId"] as? String == "exact")
    }

    @Test("Exact active thread steers the observed turn.")
    func exactActiveThreadSteers() async throws {
        let fake = try makeFakeProxy(threads: [], cwd: "/same", activeTurnID: "turn-7")
        let client = CodexAppServerClient(timeout: 1.0)

        _ = try await client.deliver(
            binaryPath: fake.binaryPath.path,
            socketPath: "/tmp/graftty-codex.sock",
            expectedCWD: "/same",
            message: "untrusted peer context",
            target: CodexAppServerTarget(threadID: "exact", activeTurnID: nil)
        )

        let requests = try fake.recordedRequests()
        #expect(try methods(in: requests) == ["initialize", "initialized", "thread/read", "turn/steer"])
        let params = try #require(requests.last?["params"] as? [String: Any])
        #expect(params["threadId"] as? String == "exact")
        #expect(params["expectedTurnId"] as? String == "turn-7")
    }

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
        #expect(try dictionary(at: 2, in: requests)["params"].flatMap(valueDictionary)?["limit"] as? Int == 100)
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

    @Test("""
    @spec TEAM-12.4: When a Codex app-server has one loaded root thread and one or more loaded subagent threads for the same worktree cwd, automatic team-message delivery shall use `thread/read` metadata to target the root thread. Spawned subagents are identified by `parentThreadId`; other subagent kinds are identified by their `source`. If more than one root thread matches, delivery shall remain ambiguous and shall not start a turn.
    """)
    func rootThreadWinsWhenSubagentsShareItsCWD() async throws {
        let fake = try makeFakeProxy(
            threads: ["root", "review-cli", "review-lifecycle", "review-tests", "guardian"],
            cwd: "/repo/.worktrees/alice",
            parentThreadIDByThread: [
                "review-cli": "root",
                "review-lifecycle": "root",
                "review-tests": "root",
            ],
            subagentSourceThreadIDs: ["guardian"]
        )
        let client = CodexAppServerClient(timeout: 1.0)

        let result = try await client.deliver(
            binaryPath: fake.binaryPath.path,
            socketPath: "/tmp/graftty-codex.sock",
            expectedCWD: "/repo/.worktrees/alice",
            message: "CI failed"
        )

        #expect(result.threadID == "root")
        let turnStart = try #require(
            fake.recordedRequests().first { request in
                request["method"] as? String == "turn/start"
            }
        )
        let params = try #require(turnStart["params"] as? [String: Any])
        #expect(params["threadId"] as? String == "root")
    }

    @Test("Multiple loaded threads with the same cwd throw without starting a turn.")
    func duplicateMatchingCWDThrowsWithoutStartingTurn() async throws {
        let fake = try makeFakeProxy(
            threads: ["one", "two"],
            cwd: "/repo/.worktrees/alice"
        )
        let client = CodexAppServerClient(timeout: 1.0)

        try await expectDeliveryThrows(containing: "refusing ambiguous delivery") {
            _ = try await client.deliver(
                binaryPath: fake.binaryPath.path,
                socketPath: "/tmp/graftty-codex.sock",
                expectedCWD: "/repo/.worktrees/alice",
                message: "hello"
            )
        }

        #expect(try methods(in: fake.recordedRequests()).contains("turn/start") == false)
    }

    @Test("Loaded thread list pagination is followed before matching cwd.")
    func loadedThreadPaginationFindsMatchingCWD() async throws {
        let fake = try makeFakeProxy(
            threads: [],
            cwd: "/repo/other",
            cwdByThread: ["target": "/repo/.worktrees/alice"],
            threadPages: [["other"], ["target"]]
        )
        let client = CodexAppServerClient(timeout: 1.0)

        let result = try await client.deliver(
            binaryPath: fake.binaryPath.path,
            socketPath: "/tmp/graftty-codex.sock",
            expectedCWD: "/repo/.worktrees/alice",
            message: "hello"
        )

        #expect(result.threadID == "target")
        let requests = try fake.recordedRequests()
        #expect(try methods(in: requests).filter { $0 == "thread/loaded/list" }.count == 2)
        #expect(try dictionary(at: 3, in: requests)["params"].flatMap(valueDictionary)?["cursor"] as? String == "1")
    }

    @Test("Fragmented websocket text responses are assembled before JSON parsing.")
    func fragmentedWebSocketTextResponseIsAssembled() async throws {
        let fake = try makeFakeProxy(
            threads: ["thread-123"],
            cwd: "/repo/.worktrees/alice",
            fragmentThreadReadResponse: true
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

    @Test("Delivery times out when the proxy stops reading stdin.")
    func deliveryTimesOutWhenProxyStopsReading() async throws {
        let fake = try makeFakeProxy(
            threads: ["thread-123"],
            cwd: "/repo/.worktrees/alice",
            mode: .stopReadingAfterThreadRead
        )
        let client = CodexAppServerClient(timeout: 0.3)
        let largeMessage = String(repeating: "x", count: 2_000_000)

        // Darwin may buffer the whole request before the deadline, so this
        // can time out either while writing or while awaiting the response.
        try await expectDeliveryThrows(containingAnyOf: [
            "write timed out",
            "timed out waiting for a response",
        ]) {
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
        parentThreadIDByThread: [String: String] = [:],
        subagentSourceThreadIDs: [String] = [],
        turnStartResponse: TurnStartResponse = .accepted,
        loadedListResponseID: Int = 2,
        notificationBeforeLoadedListResponse: Bool = false,
        threadPages: [[String]]? = nil,
        fragmentThreadReadResponse: Bool = false,
        activeTurnID: String? = nil,
        mode: FakeProxyMode = .normal
    ) throws -> FakeProxy {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-client-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let script = dir.appendingPathComponent("codex-fake")
        let args = dir.appendingPathComponent("args.txt")
        let stdin = dir.appendingPathComponent("stdin.jsonl")
        let handshake = dir.appendingPathComponent("handshake.txt")
        let threadPagesJSON = try jsonLine(threadPages ?? [threads])
        let cwdByThreadJSON = try jsonLine(cwdByThread)
        let parentThreadIDByThreadJSON = try jsonLine(parentThreadIDByThread)
        let subagentSourceThreadIDsJSON = try jsonLine(subagentSourceThreadIDs)
        let activeTurnsJSON = try jsonLine(activeTurnID.map {
            [["id": $0, "status": "inProgress"]]
        } ?? [])
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
        let writeThreadReadResponse = fragmentThreadReadResponse
            ? "write_fragmented_text"
            : "write_text"
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
        #!/usr/bin/ruby --disable-gems
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

        def write_frame(opcode, bytes, fin)
          header = [(fin ? 0x80 : 0x00) | opcode]
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

        def write_text(text)
          bytes = text.b
          write_frame(0x1, bytes, true)
        end

        def write_fragmented_text(text)
          bytes = text.b
          split_at = [1, bytes.bytesize / 2].max
          write_frame(0x1, bytes.byteslice(0, split_at), false)
          write_frame(0x0, bytes.byteslice(split_at, bytes.bytesize - split_at), true)
        end

        handshake = +''
        handshake << read_exact(1) until handshake.include?("\\r\\n\\r\\n")
        File.write('\(shellSingleQuoted(handshake.path))', handshake)
        exit 3 unless handshake.start_with?('GET ') && handshake.downcase.include?('upgrade: websocket')
        STDOUT.write("HTTP/1.1 101 Switching Protocols\\r\\nConnection: Upgrade\\r\\nUpgrade: websocket\\r\\nSec-WebSocket-Accept: test\\r\\n\\r\\n")
        STDOUT.flush

        thread_pages = JSON.parse(<<'GRAFTTY_JSON')
        \(threadPagesJSON)
        GRAFTTY_JSON
        cwd_by_thread = JSON.parse(<<'GRAFTTY_JSON')
        \(cwdByThreadJSON)
        GRAFTTY_JSON
        parent_thread_id_by_thread = JSON.parse(<<'GRAFTTY_JSON')
        \(parentThreadIDByThreadJSON)
        GRAFTTY_JSON
        subagent_source_thread_ids = JSON.parse(<<'GRAFTTY_JSON')
        \(subagentSourceThreadIDsJSON)
        GRAFTTY_JSON
        active_turns = JSON.parse(<<'GRAFTTY_JSON')
        \(activeTurnsJSON)
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
            page_index = request.dig('params', 'cursor').to_i
            result = { data: thread_pages.fetch(page_index) }
            result[:nextCursor] = (page_index + 1).to_s if page_index + 1 < thread_pages.length
            response_id = \(loadedListResponseID) == 2 ? request['id'] : \(loadedListResponseID)
            write_text(JSON.generate({ id: response_id, result: result }))
          when 'thread/read'
            thread_id = request.dig('params', 'threadId')
            thread = { cwd: cwd_by_thread.fetch(thread_id, default_cwd) }
            thread[:turns] = active_turns
            thread[:parentThreadId] = parent_thread_id_by_thread[thread_id] if parent_thread_id_by_thread.key?(thread_id)
            thread[:source] = { subAgent: { other: 'test' } } if subagent_source_thread_ids.include?(thread_id)
            \(writeThreadReadResponse)(JSON.generate({ id: request['id'], result: { thread: thread } }))
        \(afterThreadRead)
        \(closeStdinAfterThreadRead)
          when 'turn/start', 'turn/steer'
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
        try await expectDeliveryThrows(
            containingAnyOf: [expectedDescription],
            operation: operation
        )
    }

    private func expectDeliveryThrows(
        containingAnyOf expectedDescriptions: [String],
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            Issue.record("Expected delivery to throw.")
        } catch {
            let description = String(describing: error)
            #expect(expectedDescriptions.contains { description.contains($0) })
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

import Foundation
import Testing
@testable import GrafttyKit

@Suite("CodexAppServerDeliveryService")
struct CodexAppServerDeliveryTests {
    @Test("Success delivers formatted unread messages through the owner app-server and advances the worktree watermark.")
    func successDeliversAndAdvancesWatermark() async throws {
        let f = try Fixture()
        let first = try f.appendUnread(body: "first")
        let second = try f.appendUnread(body: "second")
        try f.writeOwnerSession()

        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree)

        let calls = await f.client.calls()
        #expect(calls.count == 1)
        #expect(calls[0].binaryPath == f.realBinaryPath)
        #expect(calls[0].socketPath == f.socketPath)
        #expect(calls[0].expectedCWD == f.worktree)
        #expect(calls[0].message == TeamPeerMessageFormatter.context(messages: [first, second]))
        #expect(try f.inbox.worktreeWatermark(
            teamID: f.teamID,
            worktree: f.worktree
        )?.lastDeliveredToAnySessionID == second.id)

        let event = try #require(f.readEvents().last)
        #expect(event.kind == .codexAppServerDeliveryAttempt)
        #expect(event.detail["outcome"] == "sent")
        #expect(event.detail["runtime"] == "codex")
        #expect(event.detail["worktree"] == f.worktree)
        #expect(event.detail["paneSessionName"] == f.ownerPane)
        #expect(event.detail["messageIDs"] == "\(first.id),\(second.id)")
        #expect(event.detail["threadID"] == f.threadID)
    }

    @Test("Codex delivery skips another runtime's row without consuming it or blocking later Codex rows.")
    func runtimeTargetedMessageDoesNotBlockLaterDelivery() async throws {
        let f = try Fixture()
        let claudeMessage = try f.appendUnread(body: "for Claude", runtime: "claude")
        let codexMessage = try f.appendUnread(body: "for Codex")
        try f.writeOwnerSession()

        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree)

        let calls = await f.client.calls()
        #expect(calls.count == 1)
        #expect(calls[0].message == TeamPeerMessageFormatter.context(messages: [codexMessage]))
        let watermark = try f.inbox.worktreeWatermark(
            teamID: f.teamID,
            worktree: f.worktree
        )
        #expect(watermark?.lastDeliveredToAnySessionID == codexMessage.id)
        #expect(watermark?.pendingBeforeWatermarkIDs == [claudeMessage.id])
        #expect(try f.inbox.worktreePendingMessages(
            teamID: f.teamID,
            recipientWorktree: f.worktree
        ) == [claudeMessage])
    }

    @Test("Client failure leaves unread messages queued and logs error_delivery.")
    func clientFailureDoesNotAdvanceWatermark() async throws {
        let f = try Fixture(clientError: DeliveryError.boom)
        _ = try f.appendUnread(body: "hello")
        try f.writeOwnerSession()

        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree)

        #expect(await f.client.callCount() == 1)
        #expect(try f.inbox.worktreeWatermark(teamID: f.teamID, worktree: f.worktree) == nil)
        let pending = try f.inbox.unreadMessages(teamID: f.teamID, recipientWorktree: f.worktree, after: nil)
        #expect(pending.count == 1)
        let event = try #require(f.readEvents().last)
        #expect(event.detail["outcome"] == "error_delivery")
        #expect(event.detail["error"] == "boom")
    }

    @Test("No owner skips without client delivery or watermark advancement.")
    func noOwnerSkips() async throws {
        let f = try Fixture(presenceRecords: [])
        _ = try f.appendUnread(body: "hello")
        try f.writeOwnerSession()

        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree)

        #expect(await f.client.callCount() == 0)
        #expect(try f.inbox.worktreeWatermark(teamID: f.teamID, worktree: f.worktree) == nil)
        let event = try #require(f.readEvents().last)
        #expect(event.detail["outcome"] == "skipped_no_owner")
    }

    @Test("Missing app-server record skips without client delivery.")
    func missingAppServerRecordSkips() async throws {
        let f = try Fixture()
        _ = try f.appendUnread(body: "hello")

        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree)

        #expect(await f.client.callCount() == 0)
        #expect(try f.inbox.worktreeWatermark(teamID: f.teamID, worktree: f.worktree) == nil)
        let event = try #require(f.readEvents().last)
        #expect(event.detail["outcome"] == "skipped_missing_app_server")
    }

    @Test("Stale app-server record skips without client delivery or watermark advancement.")
    func staleAppServerRecordSkips() async throws {
        let f = try Fixture(appServerCurrentStart: 9_999)
        _ = try f.appendUnread(body: "hello")
        try f.writeOwnerSession()

        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree)

        #expect(await f.client.callCount() == 0)
        #expect(try f.inbox.worktreeWatermark(teamID: f.teamID, worktree: f.worktree) == nil)
        let event = try #require(f.readEvents().last)
        #expect(event.detail["outcome"] == "skipped_stale_app_server")
    }

    @Test("App-server records without stored process identity skip without delivery.")
    func missingAppServerProcessIdentitySkips() async throws {
        let f = try Fixture()
        _ = try f.appendUnread(body: "hello")
        try f.writeOwnerSession(appServerStart: nil)

        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree)

        #expect(await f.client.callCount() == 0)
        #expect(try f.inbox.worktreeWatermark(teamID: f.teamID, worktree: f.worktree) == nil)
        let event = try #require(f.readEvents().last)
        #expect(event.detail["outcome"] == "skipped_stale_app_server")
    }

    @Test("Concurrent arrivals for the same worktree coalesce so only one app-server delivery is sent.")
    func concurrentArrivalsForSameWorktreeCoalesce() async throws {
        let f = try Fixture(blockClient: true)
        _ = try f.appendUnread(body: "hello")
        try f.writeOwnerSession()

        async let first: Void = f.service.onMessageArrival(team: f.teamID, worktree: f.worktree)
        await f.client.waitForCallCount(1)

        async let second: Void = f.service.onMessageArrival(team: f.teamID, worktree: f.worktree)
        await second
        #expect(await f.client.callCount() == 1)

        await f.client.unblockDelivery()
        await first

        #expect(await f.client.callCount() == 1)
    }

    @Test("Many arrivals during one blocked failed delivery produce at most one follow-up attempt.")
    func concurrentArrivalsDuringFailureCoalesceToOneFollowUp() async throws {
        let f = try Fixture(clientError: DeliveryError.boom, blockedDeliveries: 1)
        _ = try f.appendUnread(body: "hello")
        try f.writeOwnerSession()

        async let first: Void = f.service.onMessageArrival(team: f.teamID, worktree: f.worktree)
        await f.client.waitForCallCount(1)

        let arrivals = (0..<8).map { _ in
            Task { await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree) }
        }
        for arrival in arrivals {
            await arrival.value
        }
        #expect(await f.client.callCount() == 1)

        await f.client.unblockDelivery()
        await first

        #expect(await f.client.callCount() == 2)
        #expect(try f.inbox.worktreeWatermark(teamID: f.teamID, worktree: f.worktree) == nil)
    }

    @Test("A newer watermark written by another path during delivery is not overwritten by an older delivered batch.")
    func newerConcurrentWatermarkDoesNotRegress() async throws {
        let f = try Fixture(blockClient: true)
        _ = try f.appendUnread(body: "first")
        let deliveredLast = try f.appendUnread(body: "second")
        try f.writeOwnerSession()

        async let delivery: Void = f.service.onMessageArrival(team: f.teamID, worktree: f.worktree)
        await f.client.waitForCallCount(1)

        let newer = try f.appendUnread(body: "newer")
        try f.inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: f.worktree,
                lastDeliveredToAnySessionID: newer.id
            ),
            teamID: f.teamID
        )

        await f.client.unblockDelivery()
        await delivery

        #expect(deliveredLast.id != newer.id)
        #expect(try f.inbox.worktreeWatermark(
            teamID: f.teamID,
            worktree: f.worktree
        )?.lastDeliveredToAnySessionID == newer.id)
    }

    @Test("Multiple presence records use the earliest live owner pane, not a later non-owner app-server.")
    func usesEarliestLiveOwnerPane() async throws {
        let f = try Fixture(
            presenceRecords: [
                Fixture.presenceRecord(pane: "graftty-owner", pid: 101, start: 1_001, registeredAt: 10),
                Fixture.presenceRecord(pane: "graftty-later", pid: 102, start: 1_002, registeredAt: 20),
            ],
            liveSessions: ["graftty-owner", "graftty-later"],
            processStartTimes: [101: 1_001, 102: 1_002, 201: 2_001, 202: 2_002]
        )
        _ = try f.appendUnread(body: "hello")
        try f.writeOwnerSession(pane: "graftty-owner", appServerPID: 201, appServerStart: 2_001)
        try f.writeOwnerSession(
            pane: "graftty-later",
            socketPath: "/tmp/later.sock",
            realBinaryPath: "/bin/later-codex",
            appServerPID: 202,
            appServerStart: 2_002
        )

        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree)

        let calls = await f.client.calls()
        #expect(calls.count == 1)
        #expect(calls[0].socketPath == f.socketPath)
        #expect(calls[0].binaryPath == f.realBinaryPath)
        let event = try #require(f.readEvents().last)
        #expect(event.detail["paneSessionName"] == "graftty-owner")
        #expect(event.detail["outcome"] == "sent")
    }

    @Test("An exact Codex address selects that agent's app-server instead of the earliest Codex owner.")
    func exactAddressSelectsLaterAgent() async throws {
        let firstID = TeamAgentIdentity(runtime: .codex, nativeSessionID: "codex-first").rawValue
        let laterID = TeamAgentIdentity(runtime: .codex, nativeSessionID: "codex-later").rawValue
        let f = try Fixture(
            presenceRecords: [
                Fixture.presenceRecord(
                    pane: "graftty-owner",
                    pid: 101,
                    start: 1_001,
                    registeredAt: 10,
                    sessionID: "codex-first"
                ),
                Fixture.presenceRecord(
                    pane: "graftty-later",
                    pid: 102,
                    start: 1_002,
                    registeredAt: 20,
                    sessionID: "codex-later"
                ),
            ],
            liveSessions: ["graftty-owner", "graftty-later"],
            processStartTimes: [101: 1_001, 102: 1_002, 201: 2_001, 202: 2_002]
        )
        _ = firstID
        _ = try f.appendUnread(body: "for the later agent", agentID: laterID)
        try f.writeOwnerSession(agentID: firstID)
        try f.writeOwnerSession(
            pane: "graftty-later",
            socketPath: "/tmp/later.sock",
            realBinaryPath: "/bin/later-codex",
            appServerPID: 202,
            appServerStart: 2_002,
            agentID: laterID
        )

        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree)

        let calls = await f.client.calls()
        #expect(calls.count == 1)
        #expect(calls[0].socketPath == "/tmp/later.sock")
        #expect(calls[0].binaryPath == "/bin/later-codex")
    }

    struct Fixture {
        let teamID = "/repo"
        let worktree = "/repo/.worktrees/alice"
        let ownerPane = "graftty-owner"
        let socketPath = "/tmp/codex-app-server.sock"
        let realBinaryPath = "/bin/codex"
        let threadID = "thread-123"
        let frozen: Date
        let rootDir: URL
        let inbox: TeamInbox
        let sessionStorage: CodexAppServerSessionStorage
        let client: StubClient
        let eventLog: TeamEventLog
        let service: CodexAppServerDeliveryService

        init(
            presenceRecords: [TeamPresenceRecord]? = nil,
            liveSessions: Set<String> = ["graftty-owner"],
            processStartTimes: [Int32: Int64] = [101: 1_001, 201: 2_001],
            appServerCurrentStart: Int64? = 2_001,
            clientError: Error? = nil,
            blockClient: Bool = false,
            blockedDeliveries: Int? = nil
        ) throws {
            let frozenDate = Date(timeIntervalSince1970: 1_700_000_000)
            self.frozen = frozenDate
            self.rootDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-codex-delivery-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
            self.inbox = TeamInbox(rootDirectory: rootDir, idGenerator: StubIDs().next, now: { frozenDate })
            self.sessionStorage = CodexAppServerSessionStorage(rootDirectory: rootDir)
            self.client = StubClient(
                threadID: threadID,
                error: clientError,
                blockedDeliveries: blockedDeliveries ?? (blockClient ? 1 : 0)
            )
            self.eventLog = TeamEventLog(rootDirectory: rootDir)
            var starts = processStartTimes
            starts[201] = appServerCurrentStart
            let liveness = StubLiveness(liveSessions: liveSessions, processStartTimes: starts)
            let records = presenceRecords ?? [
                Self.presenceRecord(pane: ownerPane, pid: 101, start: 1_001, registeredAt: 10),
            ]
            self.service = CodexAppServerDeliveryService(
                inbox: inbox,
                presenceRecords: { records },
                sessionStorage: sessionStorage,
                liveness: liveness,
                client: client,
                eventLog: eventLog,
                now: { frozenDate }
            )
        }

        func appendUnread(
            body: String,
            runtime: String? = "codex",
            agentID: String? = nil
        ) throws -> TeamInboxMessage {
            try inbox.appendMessage(
                teamID: teamID,
                teamName: "repo",
                repoPath: "/repo",
                from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
                to: TeamInboxEndpoint(
                    member: "alice",
                    worktree: worktree,
                    runtime: runtime,
                    agentID: agentID
                ),
                priority: .normal,
                body: body
            )
        }

        func writeOwnerSession(
            pane: String? = nil,
            socketPath: String? = nil,
            realBinaryPath: String? = nil,
            appServerPID: Int32 = 201,
            appServerStart: Int64? = 2_001,
            agentID: String? = nil
        ) throws {
            try sessionStorage.write(CodexAppServerSessionRecord(
                teamID: teamID,
                worktree: worktree,
                paneSessionName: pane ?? ownerPane,
                socketPath: socketPath ?? self.socketPath,
                realBinaryPath: realBinaryPath ?? self.realBinaryPath,
                appServerPID: appServerPID,
                appServerProcessStartTimeMicroseconds: appServerStart,
                registeredAt: frozen,
                agentID: agentID
            ))
        }

        func readEvents() throws -> [TeamEvent] {
            let eventsPath = rootDir
                .appendingPathComponent(TeamInbox.fileComponent(teamID), isDirectory: true)
                .appendingPathComponent("events.jsonl")
            guard FileManager.default.fileExists(atPath: eventsPath.path) else { return [] }
            let data = try Data(contentsOf: eventsPath)
            let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try lines.map { try decoder.decode(TeamEvent.self, from: Data($0)) }
        }

        static func presenceRecord(
            pane: String,
            pid: Int32,
            start: Int64,
            registeredAt: TimeInterval,
            sessionID: String? = nil
        ) -> TeamPresenceRecord {
            TeamPresenceRecord(
                teamID: "/repo",
                worktree: "/repo/.worktrees/alice",
                runtime: .codex,
                paneSessionName: pane,
                pid: pid,
                processStartTimeMicroseconds: start,
                registeredAt: Date(timeIntervalSince1970: registeredAt),
                runtimeSessionID: sessionID,
                agentID: sessionID.map {
                    TeamAgentIdentity(runtime: .codex, nativeSessionID: $0).rawValue
                }
            )
        }
    }

    final class StubIDs: @unchecked Sendable {
        private var nextID = 0

        func next() -> String {
            nextID += 1
            return "id-\(nextID)"
        }
    }

    actor StubClient: CodexAppServerClienting {
        struct Call {
            let binaryPath: String
            let socketPath: String
            let expectedCWD: String
            let message: String
        }

        private var recordedCalls: [Call] = []
        private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseCount = 0
        let threadID: String
        let error: Error?
        let blockedDeliveries: Int

        init(threadID: String, error: Error?, blockedDeliveries: Int = 0) {
            self.threadID = threadID
            self.error = error
            self.blockedDeliveries = blockedDeliveries
        }

        func deliver(
            binaryPath: String,
            socketPath: String,
            expectedCWD: String,
            message: String
        ) async throws -> CodexAppServerDeliveryResult {
            let callNumber = recordedCalls.count + 1
            recordedCalls.append(Call(
                binaryPath: binaryPath,
                socketPath: socketPath,
                expectedCWD: expectedCWD,
                message: message
            ))
            resumeReadyCallWaiters()
            if callNumber <= blockedDeliveries {
                await waitForRelease()
            }
            if let error { throw error }
            return CodexAppServerDeliveryResult(threadID: threadID)
        }

        func calls() -> [Call] {
            recordedCalls
        }

        func callCount() -> Int {
            recordedCalls.count
        }

        func waitForCallCount(_ count: Int) async {
            guard recordedCalls.count < count else { return }
            await withCheckedContinuation { continuation in
                callWaiters.append((count: count, continuation: continuation))
            }
        }

        func unblockDelivery(count: Int = 1) {
            for _ in 0..<count {
                if releaseWaiters.isEmpty {
                    releaseCount += 1
                } else {
                    releaseWaiters.removeFirst().resume()
                }
            }
        }

        private func waitForRelease() async {
            if releaseCount > 0 {
                releaseCount -= 1
                return
            }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        private func resumeReadyCallWaiters() {
            let ready = callWaiters.filter { recordedCalls.count >= $0.count }
            callWaiters.removeAll { recordedCalls.count >= $0.count }
            for waiter in ready {
                waiter.continuation.resume()
            }
        }
    }

    struct StubLiveness: TeamDeliveryLivenessChecking {
        let liveSessions: Set<String>
        let processStartTimes: [Int32: Int64?]

        func isLivePaneSession(_ sessionName: String) -> Bool {
            liveSessions.contains(sessionName)
        }

        func processStartTimeMicroseconds(ofPID pid: Int32) -> Int64? {
            processStartTimes[pid] ?? nil
        }
    }

    enum DeliveryError: Error {
        case boom
    }
}

import Foundation
import Testing
@testable import GrafttyKit

@Suite("Native team delivery pipeline")
struct TeamDeliveryPipelineTests {
    @Test("@spec TEAM-11.12: While a native delivery pass is running for a worktree, the application shall coalesce further arrivals for that worktree into at most one follow-up pass after the current pass finishes, and shall keep running passes while each pass acknowledges rows.", .timeLimit(.minutes(1)))
    func arrivalsDuringAPassCoalesceIntoOneFollowUp() async throws {
        let fixture = try Fixture(blockedCalls: 1)
        let first = try fixture.append(body: "first")

        async let delivery: Void = fixture.pipeline.onMessageArrival(team: fixture.teamID, worktree: fixture.worktree)
        await fixture.transport.waitForCallCount(1)

        // Arrivals during the blocked pass return immediately and only mark
        // the worktree dirty; none of them reaches the transport.
        let second = try fixture.append(body: "second")
        let arrivals = (0..<8).map { _ in
            Task { await fixture.pipeline.onMessageArrival(team: fixture.teamID, worktree: fixture.worktree) }
        }
        for arrival in arrivals { await arrival.value }
        #expect(await fixture.transport.calls.count == 1)

        await fixture.transport.release()
        await delivery

        let calls = await fixture.transport.calls
        #expect(calls.map(\.pendingIDs) == [[first.id], [second.id]])
        #expect(try fixture.watermark()?.lastDeliveredToAnySessionID == second.id)
    }

    @Test("A failed pass with arrivals queued behind it retries exactly once, then stops.", .timeLimit(.minutes(1)))
    func failedPassRetriesOnceForQueuedArrivals() async throws {
        let fixture = try Fixture(blockedCalls: 1, behavior: { _ in .pending(nil) })
        _ = try fixture.append(body: "hello")

        async let delivery: Void = fixture.pipeline.onMessageArrival(team: fixture.teamID, worktree: fixture.worktree)
        await fixture.transport.waitForCallCount(1)
        for _ in 0..<4 {
            await fixture.pipeline.onMessageArrival(team: fixture.teamID, worktree: fixture.worktree)
        }
        await fixture.transport.release()
        await delivery

        #expect(await fixture.transport.calls.count == 2)
        #expect(try fixture.watermark() == nil)
    }

    @Test("@spec TEAM-11.13: When a native transport acknowledges only some of the rows it was offered, the application shall advance shared delivery state for exactly those rows, offer the remainder in a follow-up pass, and keep rows reserved for another runtime as pending gaps.")
    func partialAcknowledgementRedeliversTheRemainder() async throws {
        let fixture = try Fixture(behavior: { pending in
            .acknowledged(Array(pending.prefix(1)).map(\.id), TeamDeliveryLogEntry(outcome: "sent"))
        })
        let first = try fixture.append(body: "first")
        let forCodex = try fixture.append(body: "for codex", runtime: "codex")
        let last = try fixture.append(body: "last")

        await fixture.pipeline.onMessageArrival(team: fixture.teamID, worktree: fixture.worktree)

        let calls = await fixture.transport.calls
        #expect(calls.map(\.pendingIDs) == [[first.id, last.id], [last.id]])
        let watermark = try fixture.watermark()
        #expect(watermark?.lastDeliveredToAnySessionID == last.id)
        #expect(watermark?.pendingBeforeWatermarkIDs == [forCodex.id])
        let sent = try fixture.events().filter { $0.detail["outcome"] == "sent" }
        #expect(sent.map { $0.detail["messageIDs"] } == [first.id, last.id])
    }

    @Test("@spec TEAM-11.14: If no pending row resolves to a reachable agent of a native transport's runtime, then the application shall leave every row pending without contacting that transport.")
    func unreachableAgentIsSkippedWithoutContactingTransport() async throws {
        let fixture = try Fixture(reachable: false)
        _ = try fixture.append(body: "exact", exactAgent: true)
        _ = try fixture.append(body: "default")

        await fixture.pipeline.onMessageArrival(team: fixture.teamID, worktree: fixture.worktree)

        #expect(await fixture.transport.calls.isEmpty)
        #expect(try fixture.watermark() == nil)
        #expect(try fixture.events().map { $0.detail["outcome"] } == ["skipped_unreachable"])
    }

    @Test("A transport that cannot serve the worktree's agents skips before waking the worktree.")
    func unservableWorktreeIsNotWoken() async throws {
        let wakes = MutableBox<[String]>([])
        let fixture = try Fixture(mayServe: false, wake: { path in
            wakes.value.append(path)
            return true
        })
        _ = try fixture.append(body: "hello")

        await fixture.pipeline.onMessageArrival(team: fixture.teamID, worktree: fixture.worktree)

        #expect(wakes.value.isEmpty)
        #expect(await fixture.transport.calls.isEmpty)
        #expect(try fixture.events().isEmpty)
    }

    @Test("An unreadable inbox is logged only by a transport that may serve the worktree.")
    func unreadableInboxIsLoggedOnlyForServableWorktrees() async throws {
        let servable = try Fixture()
        _ = try servable.append(body: "hello")
        try servable.corruptWatermark()
        await servable.pipeline.onMessageArrival(team: servable.teamID, worktree: servable.worktree)
        #expect(try servable.events().map { $0.detail["outcome"] } == ["error_inbox_read"])

        let unservable = try Fixture(mayServe: false)
        _ = try unservable.append(body: "hello")
        try unservable.corruptWatermark()
        await unservable.pipeline.onMessageArrival(team: unservable.teamID, worktree: unservable.worktree)
        #expect(try unservable.events().isEmpty)
    }

    @Test("A watermark write failure after acknowledgement logs error_watermark_write with the transport's detail and the write error, and stops.")
    func acknowledgementFailureIsLogged() async throws {
        let fixture = try Fixture(behavior: { pending in
            .acknowledged(["not-in-inbox"] + pending.map(\.id), TeamDeliveryLogEntry(outcome: "sent", detail: ["agentID": "a"]))
        })
        _ = try fixture.append(body: "hello")

        await fixture.pipeline.onMessageArrival(team: fixture.teamID, worktree: fixture.worktree)

        #expect(await fixture.transport.calls.count == 1)
        #expect(try fixture.watermark() == nil)
        let event = try #require(try fixture.events().last)
        #expect(event.kind == .nativePeerDeliveryAttempt)
        #expect(event.detail["outcome"] == "error_watermark_write")
        #expect(event.detail["agentID"] == "a")
        #expect(event.detail["runtime"] == "claude")
        #expect(event.detail["error"]?.contains("not-in-inbox") == true)
    }

    private struct Fixture {
        let teamID = "/repo"
        let worktree = "/repo/feature"
        let root: URL
        let inbox: TeamInbox
        let transport: StubTransport
        let pipeline: TeamDeliveryPipeline<StubTransport>
        let agentID = TeamAgentIdentity(runtime: .claude, nativeSessionID: "session-1").rawValue

        init(
            blockedCalls: Int = 0,
            reachable: Bool = true,
            mayServe: Bool = true,
            wake: @escaping @Sendable (String) -> Bool = { _ in true },
            behavior: @escaping @Sendable ([TeamInboxMessage]) -> TeamDeliveryOutcome = { pending in
                .acknowledged(pending.map(\.id), TeamDeliveryLogEntry(outcome: "sent"))
            }
        ) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-delivery-pipeline-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let counter = IDCounter()
            inbox = TeamInbox(rootDirectory: root, idGenerator: { counter.next() })
            transport = StubTransport(blockedCalls: blockedCalls, mayServe: mayServe, behavior: behavior)
            let record = TeamPresenceRecord(
                teamID: teamID,
                worktree: worktree,
                runtime: .claude,
                paneSessionName: "graftty-aabbccdd",
                pid: 101,
                processStartTimeMicroseconds: 1_001,
                registeredAt: Date(timeIntervalSince1970: 10),
                runtimeSessionID: "session-1",
                agentID: agentID
            )
            pipeline = TeamDeliveryPipeline(
                inbox: inbox,
                presenceRecords: { [record] },
                isReachable: { _ in reachable },
                wakeBeforeDelivery: wake,
                logger: TeamDeliveryEventLogger(
                    eventLog: TeamEventLog(rootDirectory: root),
                    kind: .nativePeerDeliveryAttempt,
                    runtime: .claude
                ),
                transport: transport
            )
        }

        func append(body: String, runtime: String? = nil, exactAgent: Bool = false) throws -> TeamInboxMessage {
            try inbox.appendMessage(
                teamID: teamID,
                teamName: "repo",
                repoPath: teamID,
                from: TeamInboxEndpoint(member: "main", worktree: teamID, runtime: nil),
                to: TeamInboxEndpoint(
                    member: "feature",
                    worktree: worktree,
                    runtime: runtime,
                    agentID: exactAgent ? agentID : nil
                ),
                priority: .normal,
                body: body
            )
        }

        func watermark() throws -> TeamInboxWorktreeWatermark? {
            try inbox.worktreeWatermark(teamID: teamID, worktree: worktree)
        }

        /// Makes every inbox read for the worktree throw while appends work.
        func corruptWatermark() throws {
            let directory = root
                .appendingPathComponent(TeamInbox.fileComponent(teamID), isDirectory: true)
                .appendingPathComponent("worktrees", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("not json".utf8).write(
                to: directory.appendingPathComponent(TeamInbox.fileComponent(worktree) + ".json")
            )
        }

        func events() throws -> [TeamEvent] {
            let url = root
                .appendingPathComponent(TeamInbox.fileComponent(teamID), isDirectory: true)
                .appendingPathComponent("events.jsonl")
            guard let data = try? Data(contentsOf: url) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try data.split(separator: UInt8(ascii: "\n")).map {
                try decoder.decode(TeamEvent.self, from: Data($0))
            }
        }
    }

    private final class IDCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> String {
            lock.withLock {
                n += 1
                return "message-\(n)"
            }
        }
    }

    /// Records each offer and can hold the first `blockedCalls` offers open
    /// until `release()` so tests observe arrivals during an in-flight pass
    /// without wall-clock waits.
    private actor StubTransportState {
        struct Call: Sendable {
            let agentID: String
            let pendingIDs: [String]
        }

        private(set) var calls: [Call] = []
        private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        private var released = false
        let blockedCalls: Int

        init(blockedCalls: Int) { self.blockedCalls = blockedCalls }

        func record(_ call: Call) async {
            calls.append(call)
            let ready = callWaiters.filter { calls.count >= $0.count }
            callWaiters.removeAll { calls.count >= $0.count }
            ready.forEach { $0.continuation.resume() }
            guard calls.count <= blockedCalls, !released else { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitForCallCount(_ count: Int) async {
            guard calls.count < count else { return }
            await withCheckedContinuation { callWaiters.append((count, $0)) }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private struct StubTransport: TeamDeliveryTransport {
        let runtime = TeamHookRuntime.claude
        let state: StubTransportState
        let servesWorktree: Bool
        let behavior: @Sendable ([TeamInboxMessage]) -> TeamDeliveryOutcome

        init(
            blockedCalls: Int,
            mayServe: Bool,
            behavior: @escaping @Sendable ([TeamInboxMessage]) -> TeamDeliveryOutcome
        ) {
            state = StubTransportState(blockedCalls: blockedCalls)
            servesWorktree = mayServe
            self.behavior = behavior
        }

        var calls: [StubTransportState.Call] { get async { await state.calls } }
        func waitForCallCount(_ count: Int) async { await state.waitForCallCount(count) }
        func release() async { await state.release() }

        func mayServe(_ records: [TeamPresenceRecord]) -> Bool { servesWorktree }

        func deliver(
            _ pending: [TeamInboxMessage],
            to agent: TeamAgentDescriptor,
            team: String,
            worktree: String
        ) async -> TeamDeliveryOutcome {
            await state.record(.init(agentID: agent.id.rawValue, pendingIDs: pending.map(\.id)))
            return behavior(pending)
        }
    }
}

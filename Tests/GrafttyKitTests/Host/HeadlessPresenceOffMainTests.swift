import Dispatch
import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

private final class HeadlessPresenceReadProbe: @unchecked Sendable {
    let mainQueueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var reads = 0

    func recordRead() {
        lock.withLock { reads += 1 }
        #expect(!Thread.isMainThread, "presence decoding must not block the main thread")
        #expect(DispatchQueue.getSpecific(key: mainQueueKey) == nil,
            "presence decoding must leave the main queue even when its executor is not the OS main thread")
    }

    var count: Int { lock.withLock { reads } }
}

@Suite("@spec REMOTE-22.65: When a headless host answers agent-completion or remote-team requests that read presence, the application shall decode presence files off the main actor while preserving responses and request errors.")
@MainActor
struct HeadlessPresenceOffMainTests {
    private struct Fixture {
        let root: URL
        let runtime: HeadlessHostRuntime
        let record: TeamPresenceRecord
        let agentID: String
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("headless-presence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState(repos: [RepoEntry(path: root.path, displayName: "project", worktrees: [
            WorktreeEntry(path: root.path, branch: "main", state: .running),
        ])])
        let config = HostConfiguration(stateDirectory: root, runtimeDirectory: root.appendingPathComponent("run"),
            zmxExecutable: URL(fileURLWithPath: "/bin/true"))
        let runtime = try HeadlessHostRuntime(configuration: config, initialState: state)
        let record = TeamPresenceRecord(teamID: TeamLookup.id(forRepoPath: root.path), worktree: root.path,
            runtime: .codex, paneSessionName: nil, pid: ProcessInfo.processInfo.processIdentifier,
            registeredAt: Date(timeIntervalSince1970: 100), runtimeSessionID: "presence-test")
        try runtime.presence.write(record)
        return Fixture(root: root, runtime: runtime, record: record,
            agentID: TeamAgentIdentity(runtime: .codex, nativeSessionID: "presence-test").rawValue)
    }

    private func observingRead<T: Sendable>(_ fixture: Fixture,
        operation: @MainActor () async -> T) async throws -> T {
        let probe = HeadlessPresenceReadProbe()
        DispatchQueue.main.setSpecific(key: probe.mainQueueKey, value: true)
        defer { DispatchQueue.main.setSpecific(key: probe.mainQueueKey, value: nil) }
        // This control makes the queue assertion meaningful on Linux too.
        try #require(DispatchQueue.getSpecific(key: probe.mainQueueKey) == true)
        let expectedRecord = fixture.record
        let response = await HeadlessHostRuntime.$presenceRecordsReader.withValue({ storage in
            probe.recordRead()
            let decoded = try storage.listAll()
            #expect(decoded == [expectedRecord])
            return decoded
        }) {
            await operation()
        }
        #expect(probe.count == 1, "observe the actual read rather than an unused mock")
        return response
    }

    @Test(arguments: [false, true])
    func completionsDecodePresenceOffMain(contextual: Bool) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let response = try await observingRead(fixture) {
            await fixture.runtime.manage(contextual
                ? .worktreeAgentCompletions(worktreeID: fixture.root.path) : .agentCompletions)
        }
        #expect(response == .agentCompletions([AgentCompletionCandidate(
            address: fixture.root.path + "#codex", projectPath: fixture.root.path, projectName: "project",
            worktreePath: fixture.root.path, worktreeName: "main", hostName: "This Mac", runtime: "codex",
            isCurrentProject: contextual ? true : nil)]))
    }

    @Test func remoteMembersDecodePresenceOffMain() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let response = try await observingRead(fixture) {
            await fixture.runtime.remoteTeam(.list, deviceID: RemoteDeviceID(value: "peer"))
        }
        #expect(response == .members([TeamListMember(name: "project/main", branch: "main",
            worktreePath: fixture.root.path, isMainWorktree: true, isRunning: true,
            agents: [TeamListAgent(id: fixture.agentID, address: fixture.root.path + "#" + fixture.agentID,
                runtime: .codex, displayName: nil, isReachable: true, paneSessionName: nil)],
            projectPath: fixture.root.path, projectName: "project")]))
    }

    @Test func addressedRemoteSendDecodesPresenceOffMain() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let response = try await observingRead(fixture) {
            await fixture.runtime.remoteTeam(.send(senderWorktree: "/remote/project", senderAgentID: nil,
                recipientWorktree: fixture.root.path, recipientSuffix: fixture.agentID, text: "hello", priority: .normal),
                deviceID: RemoteDeviceID(value: "peer"))
        }
        #expect(response == .ok)
        let messages = try fixture.runtime.inbox.messages(teamID: fixture.record.teamID)
        #expect(messages.count == 1)
        #expect(messages.first?.from.worktree == "graftty-mac://peer/remote/project")
        #expect(messages.first?.to.agentID == fixture.agentID)
        #expect(messages.first?.body == "hello")
    }

    @Test func invalidRemoteSenderKeepsItsErrorWithoutReadingPresence() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let response = await HeadlessHostRuntime.$presenceRecordsReader.withValue({ _ in
            Issue.record("invalid sender must fail before reading presence")
            return []
        }) {
            await fixture.runtime.remoteTeam(.send(senderWorktree: "relative", senderAgentID: nil,
                recipientWorktree: fixture.root.path, recipientSuffix: fixture.agentID, text: "hello", priority: .normal),
                deviceID: RemoteDeviceID(value: "peer"))
        }
        #expect(response == .error("invalid remote team sender"))
    }
}

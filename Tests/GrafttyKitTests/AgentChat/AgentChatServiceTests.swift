import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@MainActor
@Suite("AgentChatService")
struct AgentChatServiceTests {
    /// One repo, one worktree, one Codex tab registered with a live app-server.
    @MainActor
    private final class Fixture {
        let path = "/repo/wt"
        let sessionName: String
        let storage: CodexAppServerSessionStorage
        let ownership = SessionDisplayOwnershipStore()
        var state: AppState
        var agent: ManagedAgent
        let servers = Servers()
        private(set) var service: AgentChatService!

        init() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-agent-chat-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            storage = CodexAppServerSessionStorage(rootDirectory: directory)

            let slot = PaneSlotID(), session = PaneSessionID()
            sessionName = ZmxLauncher.sessionName(for: session)
            agent = ManagedAgent(name: "Codex", provider: .codex, parent: nil)
            agent.paneSlotID = slot
            agent.providerSessionID = "thread-1"
            var worktree = WorktreeEntry(path: path, branch: "wt", state: .running)
            worktree.paneSessions[slot] = session
            worktree.agents = [agent]
            state = AppState(repos: [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [worktree])])
            try register(thread: "thread-1")

            let servers = servers
            service = AgentChatService(
                host: AgentChatHost(connect: { _ in servers.make() }),
                storage: storage, ownership: ownership, state: { [unowned self] in self.state }
            )
        }

        func register(thread: String) throws {
            let pid = ProcessInfo.processInfo.processIdentifier
            try storage.write(CodexAppServerSessionRecord(
                teamID: "/repo", worktree: path, paneSessionName: sessionName,
                socketPath: "/tmp/a.sock", realBinaryPath: "/usr/bin/codex", appServerPID: pid,
                appServerProcessStartTimeMicroseconds: ProcessIdentityReader.startTimeMicroseconds(ofPID: pid),
                registeredAt: Date(timeIntervalSince1970: 0), threadID: thread
            ))
        }

        /// The agent's own terminal moved to another conversation.
        func switchConversation(to thread: String) throws {
            state.repos[0].worktrees[0].agents[0].providerSessionID = thread
            try register(thread: thread)
        }

        func binding(_ thread: String = "thread-1") -> AgentChatBinding {
            AgentChatBinding(agentID: agent.id, assignmentID: agent.assignmentID.uuidString, conversationID: thread)
        }

        func submit(_ id: String, as viewer: AgentChatViewer, thread: String = "thread-1") async -> AgentChatSubmissionResult {
            await service.submit(
                AgentChatSubmission(binding: binding(thread), submissionID: id, text: "hello"),
                worktreePath: path, viewer: viewer
            )
        }
    }

    final class Servers: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [FakeCodexServer] = []
        var all: [FakeCodexServer] { lock.withLock { made } }
        func make() -> FakeCodexServer {
            let server = FakeCodexServer()
            lock.withLock { made.append(server) }
            return server
        }
    }

    private func attached(_ feed: AgentChatFeed) -> AgentChatSnapshot? {
        if case .attached(let snapshot, _) = feed { return snapshot }
        return nil
    }

    @Test func theHostMacSendsWhenNobodyHasClaimedTheSession() async throws {
        let fixture = try Fixture()
        #expect(attached(await fixture.service.open(worktreePath: fixture.path, agentID: fixture.agent.id)) != nil)
        #expect(await fixture.submit("s1", as: .host) == .accepted)
        #expect(fixture.servers.all.first?.sent("turn/start").count == 1)
    }

    @Test func aDeviceSendsOnlyWhileItOwnsTheDisplay() async throws {
        let fixture = try Fixture()
        _ = await fixture.service.open(worktreePath: fixture.path, agentID: fixture.agent.id)
        #expect(await fixture.submit("s1", as: .device("phone")) == .rejected(.notController))

        _ = fixture.ownership.attachClient(
            sessionName: fixture.sessionName, clientID: DisplayClientID("ssh-phone-1"), kind: .ios,
            role: .interactive, visible: true, grid: .daemonFallback, identity: "ssh-device:phone"
        )
        #expect(await fixture.submit("s2", as: .host) == .rejected(.notController))
        #expect(await fixture.submit("s3", as: .device("tablet")) == .rejected(.notController))
        #expect(await fixture.submit("s4", as: .device("phone")) == .accepted)
        #expect(fixture.servers.all.first?.sent("turn/start").count == 1)
    }

    @Test func theHostMacDoesNotSendWhileAPairedMacOwnsTheDisplay() async throws {
        let fixture = try Fixture()
        _ = await fixture.service.open(worktreePath: fixture.path, agentID: fixture.agent.id)
        // A paired Mac attaches as a Mac client under its own device identity.
        _ = fixture.ownership.attachClient(
            sessionName: fixture.sessionName, clientID: DisplayClientID("ssh-laptop-1"), kind: .mac,
            role: .interactive, visible: true, grid: .daemonFallback, identity: "ssh-device:laptop"
        )
        #expect(await fixture.submit("s1", as: .host) == .rejected(.notController))
        #expect(await fixture.submit("s2", as: .device("laptop")) == .accepted)
        #expect(fixture.servers.all.first?.sent("turn/start").count == 1)
    }

    @Test func theHostMacSendsWhileItsOwnWindowOwnsTheDisplay() async throws {
        let fixture = try Fixture()
        _ = await fixture.service.open(worktreePath: fixture.path, agentID: fixture.agent.id)
        // The host's own terminal attaches with no device identity.
        _ = fixture.ownership.attachClient(
            sessionName: fixture.sessionName, clientID: DisplayClientID("mac-local"), kind: .mac,
            role: .interactive, visible: true, grid: .daemonFallback
        )
        #expect(await fixture.submit("s1", as: .host) == .accepted)
    }

    @Test("@spec AGENT-6.173: When a paired viewer selects Chat or Terminal, the application shall change only that viewer's presentation and preserve the session's input ownership.")
    func aViewerThatOpensChatDoesNotTakeControl() async throws {
        let fixture = try Fixture()
        _ = fixture.ownership.attachClient(
            sessionName: fixture.sessionName, clientID: DisplayClientID("ssh-phone-1"), kind: .ios,
            role: .interactive, visible: true, grid: .daemonFallback, identity: "ssh-device:phone"
        )
        let before = fixture.ownership.snapshot(sessionName: fixture.sessionName)

        // Another device and the host Mac both read the conversation in Chat.
        let tablet = fixture.service.connection(worktreePath: fixture.path, agentID: fixture.agent.id, viewer: .device("tablet"))
        #expect(attached(await tablet.open()) != nil)
        #expect(attached(await fixture.service.open(worktreePath: fixture.path, agentID: fixture.agent.id)) != nil)

        #expect(fixture.ownership.snapshot(sessionName: fixture.sessionName) == before)
        #expect(await fixture.submit("s1", as: .device("tablet")) == .rejected(.notController))
        #expect(await fixture.submit("s2", as: .device("phone")) == .accepted)
    }

    @Test func aConversationChangedInTheTerminalRejectsTheOldDraft() async throws {
        let fixture = try Fixture()
        _ = await fixture.service.open(worktreePath: fixture.path, agentID: fixture.agent.id)
        try fixture.switchConversation(to: "thread-2")

        #expect(await fixture.submit("s1", as: .host) == .rejected(.staleBinding))
        #expect(fixture.servers.all.first?.sent("turn/start").isEmpty == true)

        let reopened = attached(await fixture.service.open(worktreePath: fixture.path, agentID: fixture.agent.id))
        #expect(reopened?.binding == fixture.binding("thread-2"))
        #expect(await fixture.submit("s2", as: .host, thread: "thread-2") == .accepted)
    }

    @Test func aTabWithNoRegisteredServerIsUnavailable() async throws {
        let fixture = try Fixture()
        #expect(await fixture.service.isAvailable(worktreePath: fixture.path, agentID: fixture.agent.id))
        try fixture.storage.delete(teamID: "/repo", worktree: fixture.path, paneSessionName: fixture.sessionName)

        #expect(await fixture.service.isAvailable(worktreePath: fixture.path, agentID: fixture.agent.id) == false)
        #expect(attached(await fixture.service.open(worktreePath: fixture.path, agentID: fixture.agent.id)) == nil)
        #expect(await fixture.service.isAvailable(worktreePath: fixture.path, agentID: "codex-unknown") == false)
    }
}

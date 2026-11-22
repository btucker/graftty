import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("AgentChatHost")
struct AgentChatHostTests {
    private func endpoint(agent: String = "codex-1", thread: String = "thread-1") -> AgentChatEndpoint {
        AgentChatEndpoint(
            binding: AgentChatBinding(agentID: agent, assignmentID: "A", conversationID: thread),
            socketPath: "/tmp/\(agent).sock", binaryPath: "/usr/bin/codex"
        )
    }


    private typealias Servers = AgentChatServiceTests.Servers

    private func host(_ servers: Servers) -> AgentChatHost {
        AgentChatHost(connect: { _ in servers.make() })
    }

    private func submission(_ id: String, _ endpoint: AgentChatEndpoint) -> AgentChatSubmission {
        AgentChatSubmission(binding: endpoint.binding, submissionID: id, text: "hello")
    }

    @Test func twoViewersOfOneTabShareOneConnection() async throws {
        let servers = Servers()
        let host = host(servers)
        _ = try await host.open(endpoint())
        _ = try await host.open(endpoint())
        #expect(servers.all.count == 1)

        _ = try await host.open(endpoint(agent: "codex-2", thread: "thread-2"))
        #expect(servers.all.count == 2)
    }

    @Test func onlyTheControllerCanSendOrAnswer() async throws {
        let servers = Servers()
        let host = host(servers)
        let tab = endpoint()
        _ = try await host.open(tab)

        let observer = await host.submit(submission("s1", tab), current: tab.binding, isController: false)
        #expect(observer == .rejected(.notController))
        #expect(servers.all[0].sent("turn/start").isEmpty)
        #expect(await host.answer(binding: tab.binding, requestID: "0", decision: .accept,
                                  current: tab.binding, isController: false) == false)

        let controller = await host.submit(submission("s1", tab), current: tab.binding, isController: true)
        #expect(controller == .accepted)
        #expect(servers.all[0].sent("turn/start").count == 1)
    }

    @Test func aSubmissionForAReplacedConversationIsRejected() async throws {
        let servers = Servers()
        let host = host(servers)
        let old = endpoint()
        _ = try await host.open(old)
        let resumed = endpoint(thread: "thread-2")

        let result = await host.submit(submission("s1", old), current: resumed.binding, isController: true)
        #expect(result == .rejected(.staleBinding))
        #expect(await host.submit(submission("s2", old), current: nil, isController: true)
            == .rejected(.staleBinding))
        #expect(servers.all[0].sent("turn/start").isEmpty)
    }

    @Test func reopeningAfterAThreadChangeEndsTheOldSession() async throws {
        let servers = Servers()
        let host = host(servers)
        let (_, oldUpdates) = try await host.open(endpoint())
        _ = try await host.open(endpoint(thread: "thread-2"))
        #expect(servers.all.count == 2)

        var ended = false
        for await update in oldUpdates {
            if case .ended = update.event { ended = true }
        }
        #expect(ended)
    }

    @Test func resolutionRequiresTheExactLiveConversation() throws {
        var agent = ManagedAgent(name: "Codex", provider: .codex, parent: nil)
        agent.providerSessionID = "thread-1"
        func record(thread: String?) -> CodexAppServerSessionRecord {
            CodexAppServerSessionRecord(
                teamID: "/repo", worktree: "/repo/wt", paneSessionName: "graftty-aaaaaaaa",
                socketPath: "/tmp/a.sock", realBinaryPath: "/usr/bin/codex", appServerPID: 1,
                registeredAt: Date(timeIntervalSince1970: 0), threadID: thread
            )
        }

        let resolved = AgentChatHost.resolve(agent: agent, record: record(thread: "thread-1"), appServerIsRunning: true)
        #expect(resolved == .endpoint(AgentChatEndpoint(
            binding: AgentChatBinding(agentID: agent.id, assignmentID: agent.assignmentID.uuidString,
                                      conversationID: "thread-1"),
            socketPath: "/tmp/a.sock", binaryPath: "/usr/bin/codex"
        )))

        func unavailable(_ resolution: AgentChatResolution) -> Bool {
            if case .unavailable = resolution { return true }
            return false
        }
        #expect(unavailable(AgentChatHost.resolve(agent: nil, record: record(thread: "thread-1"),
                                                  appServerIsRunning: true)))
        #expect(unavailable(AgentChatHost.resolve(agent: agent, record: record(thread: "thread-2"),
                                                  appServerIsRunning: true)))
        #expect(unavailable(AgentChatHost.resolve(agent: agent, record: record(thread: "thread-1"),
                                                  appServerIsRunning: false)))
        #expect(unavailable(AgentChatHost.resolve(agent: agent, record: nil, appServerIsRunning: true)))
        let claude = ManagedAgent(name: "Claude", provider: .claude, parent: nil)
        #expect(unavailable(AgentChatHost.resolve(agent: claude, record: record(thread: "thread-1"),
                                                  appServerIsRunning: true)))
    }
}

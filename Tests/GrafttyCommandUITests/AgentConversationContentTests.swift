import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct AgentConversationContentTests {
    private let agent = AgentSessionInfo(id: "agent", name: "Review", provider: "codex", status: "closed",
        sessionName: nil, assignmentID: "assignment", completionID: "completion", canResume: true)

    private func response(_ transcript: String) -> WorktreeManagementResponse {
        .agentConversation(.init(agentID: agent.id, assignmentID: "assignment", result: "Done",
            transcript: transcript, failure: nil, canResume: true))
    }

    @Test("@spec AGENT-6.143: When a newer completed-tab read overtakes an earlier read, the application shall display only the newest archive and keep any resume operation independently guarded.")
    func supersededReadCannotOverwriteArchiveOrReleaseResume() async throws {
        let content = AgentConversationContent()
        var pendingRead: CheckedContinuation<WorktreeManagementResponse, Never>?
        let oldRead = Task { await content.read(agent: agent) { _ in
            await withCheckedContinuation { pendingRead = $0 }
        } }
        while pendingRead == nil { await Task.yield() }
        var pendingResume: CheckedContinuation<WorktreeManagementResponse, Never>?
        let resume = Task { await content.resume(agent: agent) { _ in
            await withCheckedContinuation { pendingResume = $0 }
        } }
        while pendingResume == nil { await Task.yield() }
        await content.read(agent: agent) { _ in response("New archive") }
        #expect(content.resuming)
        await content.resume(agent: agent) { _ in Issue.record("Duplicate resume"); return response("Unexpected") }
        pendingRead?.resume(returning: response("Old archive"))
        await oldRead.value
        #expect(content.detail?.transcript == "New archive")
        pendingResume?.resume(returning: response("New assignment"))
        await resume.value
        #expect(content.resumed)
        #expect(!content.resuming)
    }

    @Test("@spec AGENT-6.144: When a user changes completed tabs while a read is pending, the application shall clear the previous tab's content and ignore its late response.")
    func changedTabRejectsLateRead() async {
        let content = AgentConversationContent()
        var pending: CheckedContinuation<WorktreeManagementResponse, Never>?
        let oldRead = Task { await content.read(agent: agent) { _ in
            await withCheckedContinuation { pending = $0 }
        } }
        while pending == nil { await Task.yield() }
        let other = AgentSessionInfo(id: "other", name: "Other", provider: "claude", status: "closed", sessionName: nil, assignmentID: "other-assignment")
        await content.read(agent: other) { _ in .agentConversation(.init(agentID: "other", assignmentID: "other-assignment",
            result: "Other result", transcript: nil, failure: nil, canResume: false)) }
        pending?.resume(returning: response("Old archive"))
        await oldRead.value
        #expect(content.detail?.agentID == "other")
        #expect(content.detail?.transcript == nil)
    }
}

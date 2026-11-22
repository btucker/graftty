import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct AgentChatModelTests {
    private let binding = AgentChatBinding(agentID: "codex-1", assignmentID: "A", conversationID: "T")

    /// A connection whose replies and live updates the test controls.
    private final class Host: @unchecked Sendable {
        var snapshot: AgentChatSnapshot
        var result: AgentChatSubmissionResult = .accepted
        var submissions: [AgentChatSubmission] = []
        var answers: [String] = []
        var answerAccepted = true
        /// Runs while a submission is in flight, before its result returns.
        var whileSubmitting: (@Sendable () async -> Void)?
        let updates: AsyncStream<AgentChatUpdate>
        let push: AsyncStream<AgentChatUpdate>.Continuation

        init(_ snapshot: AgentChatSnapshot) {
            self.snapshot = snapshot
            (updates, push) = AsyncStream<AgentChatUpdate>.makeStream()
        }

        var connection: AgentChatConnection {
            AgentChatConnection(
                open: { .attached(self.snapshot, self.updates) },
                submit: { submission in
                    self.submissions.append(submission)
                    await self.whileSubmitting?()
                    return self.result
                },
                answer: { _, requestID, _ in
                    self.answers.append(requestID)
                    return self.answerAccepted
                }
            )
        }
    }

    private func attached(_ host: Host) async -> (AgentChatModel, Task<Void, Never>) {
        let model = AgentChatModel()
        let task = Task { await model.run(host.connection) }
        while model.snapshot == nil { await Task.yield() }
        return (model, task)
    }

    private func idleHost(commands: [AgentChatCommand] = []) -> Host {
        Host(AgentChatSnapshot(binding: binding, commands: commands))
    }

    @Test("@spec AGENT-6.181: When the user chooses a slash command in the graphical composer, the application shall insert its invocation into the editable draft and wait for the user to send it.")
    func choosingACommandEditsTheDraftAndSendsNothing() async {
        let host = idleHost(commands: [AgentChatCommand(name: "review", description: "Review changes")])
        let (model, task) = await attached(host)
        defer { task.cancel() }

        model.draft = "/rev"
        #expect(model.slashMatches.map(\.name) == ["review"])
        model.choose(model.slashMatches[0])

        #expect(model.draft == "/review ")
        #expect(model.slashMatches.isEmpty)
        #expect(host.submissions.isEmpty)
    }

    @Test func sendingDeliversTheExactDraftOnceAndClearsIt() async {
        let host = idleHost()
        let (model, task) = await attached(host)
        defer { task.cancel() }

        model.draft = "/review the last two commits"
        await model.send()

        #expect(host.submissions.map(\.text) == ["/review the last two commits"])
        #expect(host.submissions.first?.binding == binding)
        #expect(model.draft.isEmpty)
        #expect(model.notice == nil)
    }

    @Test func textTypedWhileAMessageIsSendingStaysInTheDraft() async {
        let host = idleHost()
        let (model, task) = await attached(host)
        defer { task.cancel() }

        model.draft = "first message"
        host.whileSubmitting = { await MainActor.run { model.draft += " and a second thought" } }
        await model.send()

        #expect(host.submissions.map(\.text) == ["first message"])
        #expect(model.draft == " and a second thought")
    }

    @Test func aRejectedDraftIsKeptWithAReason() async {
        let host = idleHost()
        host.result = .rejected(.notController)
        let (model, task) = await attached(host)
        defer { task.cancel() }

        model.draft = "keep me"
        await model.send()

        #expect(model.draft == "keep me")
        #expect(model.notice != nil)
    }

    @Test func anUncertainDeliveryIsResentOnlyWhenTheUserSendsAgain() async {
        let host = idleHost()
        host.result = .uncertain
        let (model, task) = await attached(host)
        defer { task.cancel() }

        model.draft = "maybe delivered"
        await model.send()
        #expect(host.submissions.count == 1)
        #expect(model.draft == "maybe delivered")
        #expect(model.notice != nil)

        host.result = .accepted
        await model.send()
        #expect(host.submissions.count == 2)
        #expect(host.submissions[0].submissionID != host.submissions[1].submissionID)
        #expect(model.draft.isEmpty)
    }

    @Test func sendIsOfferedOnlyWhenTheSessionCanTakeATurn() async {
        let host = idleHost()
        let (model, task) = await attached(host)
        defer { task.cancel() }

        #expect(model.canSend == false)
        model.draft = "next"
        #expect(model.canSend)

        host.push.yield(AgentChatUpdate(sequence: 1, event: .turnState(.active)))
        while model.snapshot?.turnState != .active { await Task.yield() }
        #expect(model.canSend == false)
        #expect(model.draft == "next")
        await model.send()
        #expect(host.submissions.isEmpty)
    }

    @Test func aStaleAnswerLeavesNoActionBehind() async {
        let request = AgentChatPendingRequest(id: "7", kind: .commandApproval, summary: "touch f", canAnswerInChat: true)
        let host = Host(AgentChatSnapshot(binding: binding, turnState: .waitingOnRequest, requests: [request]))
        host.answerAccepted = false
        let (model, task) = await attached(host)
        defer { task.cancel() }

        await model.answer(request, .accept)
        #expect(host.answers == ["7"])
        #expect(model.notice != nil)

        host.push.yield(AgentChatUpdate(sequence: 1, event: .requestResolved(id: "7")))
        while model.snapshot?.requests.isEmpty == false { await Task.yield() }
        #expect(model.snapshot?.requests.isEmpty == true)
    }

    @Test func aFeedThatStopsWithoutTheConversationEndingSaysSo() async {
        let host = idleHost()
        let (model, task) = await attached(host)
        host.push.finish()
        await task.value
        #expect(model.snapshot == nil)
        #expect(model.unavailable == "Chat lost its connection to the agent.")
    }

    @Test func aFeedThatStopsAfterTheConversationEndedKeepsTheTranscript() async {
        let host = idleHost()
        let (model, task) = await attached(host)
        host.push.yield(AgentChatUpdate(sequence: 1, event: .ended(reason: "The agent exited.")))
        host.push.finish()
        await task.value
        #expect(model.snapshot?.endedReason == "The agent exited.")
        #expect(model.unavailable == nil)
    }

    /// An `open` that waits until the test answers it.
    @MainActor
    private final class PendingOpen {
        private var continuation: CheckedContinuation<AgentChatFeed, Never>?
        var isWaiting: Bool { continuation != nil }
        func wait() async -> AgentChatFeed { await withCheckedContinuation { continuation = $0 } }
        func answer(_ feed: AgentChatFeed) {
            continuation?.resume(returning: feed)
            continuation = nil
        }
    }

    @Test func anOpenAnsweredAfterTheViewLeftChangesNothing() async {
        let host = idleHost()
        let (model, first) = await attached(host)
        first.cancel()
        await first.value

        let pending = PendingOpen()
        let connection = AgentChatConnection(
            open: { await pending.wait() },
            submit: { _ in .rejected(.unavailable) }, answer: { _, _, _ in false }
        )
        let task = Task { await model.run(connection) }
        while !pending.isWaiting { await Task.yield() }
        task.cancel()
        pending.answer(.unavailable("Chat could not reach the Mac that runs this agent. The terminal is still available."))
        await task.value

        #expect(model.unavailable == nil)
        #expect(model.snapshot?.binding == binding)
    }

    @Test func anUnavailableSessionExplainsWhy() async {
        let model = AgentChatModel()
        let connection = AgentChatConnection(
            open: { .unavailable("Chat is not available for this agent yet. Use Terminal.") },
            submit: { _ in .rejected(.unavailable) }, answer: { _, _, _ in false }
        )
        await model.run(connection)
        #expect(model.unavailable == "Chat is not available for this agent yet. Use Terminal.")
        #expect(model.canSend == false)
    }
}

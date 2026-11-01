import Foundation
import Testing
@testable import GrafttyKit

struct ManagedAgentTests {
    @Test("@spec AGENT-6.66: When an agent explicitly finishes an assignment, the application shall retain its result and completion identity until cleanup succeeds, including across persistence and repeated finish requests.")
    func durableCompletion() throws {
        var agent = ManagedAgent(name: "Review", provider: .codex, parent: nil)
        let assignment = agent.assignmentID
        let first = try agent.finish(assignment: assignment, result: "Reviewed the changes.")
        #expect(agent.status == .awaitingCleanup)
        let data = try JSONEncoder().encode(agent)
        agent = try JSONDecoder().decode(ManagedAgent.self, from: data)
        #expect(try agent.finish(assignment: assignment, result: "Retry") == first)
        #expect(agent.completion?.result == "Reviewed the changes.")
        try agent.beginClose(completion: first.id)
        #expect(agent.status == .closing)
        agent.closeFailed(reason: "Session still running")
        #expect(agent.status == .awaitingCleanup)
        #expect(agent.failure == "Session still running")
        try agent.beginClose(completion: first.id)
        agent.didClose()
        #expect(agent.status == .closed)
        #expect(agent.completion == first)
        try agent.beginClose(completion: first.id)
        #expect(agent.status == .closed)
    }

    @Test("@spec AGENT-6.67: When a completed agent resumes, the application shall reject completion and cleanup requests for its earlier assignment while preserving the earlier result.")
    func staleCompletionCannotCloseResumedWork() throws {
        var agent = ManagedAgent(name: "Review", provider: .claude, parent: nil)
        let oldAssignment = agent.assignmentID
        let completion = try agent.finish(assignment: oldAssignment, result: "First pass")
        try agent.resume()
        #expect(agent.assignmentID != oldAssignment)
        #expect(agent.results == [completion])
        #expect(throws: ManagedAgent.LifecycleError.staleAssignment) {
            try agent.finish(assignment: oldAssignment, result: "Delayed retry")
        }
        #expect(throws: ManagedAgent.LifecycleError.staleCompletion) {
            try agent.beginClose(completion: completion.id)
        }
        #expect(agent.status == .running)
    }

    @Test("@spec AGENT-6.68: While an agent is running or waiting for input, the application shall require explicit assignment completion before parent cleanup.")
    func turnEndIsNotCompletion() throws {
        var agent = ManagedAgent(name: "Review", provider: .codex, parent: nil)
        #expect(throws: ManagedAgent.LifecycleError.staleCompletion) {
            try agent.beginClose(completion: UUID())
        }
        agent.observeWaiting(true)
        #expect(agent.status == .waiting)
        #expect(agent.completion == nil)
        agent.observeWaiting(false)
        #expect(agent.status == .running)
        let completion = try agent.finish(assignment: agent.assignmentID, result: "Done")
        agent.observeWaiting(false)
        #expect(agent.completion == completion)
        #expect(agent.status == .awaitingCleanup)
    }
}

import Foundation
@testable import GrafttyHostAgent
import Testing

@Suite("Terminal output credit gate", .timeLimit(.minutes(1)))
struct TerminalOutputCreditGateTests {
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, Error>?
        var value: Result<Void, Error>? { lock.withLock { result } }
        func set(_ result: Result<Void, Error>) { lock.withLock { self.result = result } }
    }

    private func reserve(_ gate: TerminalOutputCreditGate, _ bytes: Int) -> (Task<Void, Never>, Completion) {
        let completion = Completion()
        let task = Task {
            do { try await gate.reserve(bytes); completion.set(.success(())) }
            catch { completion.set(.failure(error)) }
        }
        return (task, completion)
    }

    /// Lets a blocked reservation prove it stayed blocked without a fixed sleep budget.
    private func settle() async throws {
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
    }

    @Test func holdsOutputUntilAcknowledged() async throws {
        let gate = TerminalOutputCreditGate(windowBytes: 100)
        try await gate.reserve(100)
        let (task, completion) = reserve(gate, 1)
        try await settle()
        #expect(completion.value == nil)
        gate.acknowledge(consumed: 1)
        await task.value
        #expect(completion.value != nil)
    }

    @Test func rejectsClaimsPastWhatWasSent() async throws {
        let gate = TerminalOutputCreditGate(windowBytes: 100)
        try await gate.reserve(100)
        gate.acknowledge(consumed: 1_000_000)
        let (task, completion) = reserve(gate, 1)
        try await settle()
        #expect(completion.value == nil)
        gate.close()
        await task.value
    }

    @Test func staleTotalDoesNotRewindTheWindow() async throws {
        let gate = TerminalOutputCreditGate(windowBytes: 100)
        try await gate.reserve(100)
        gate.acknowledge(consumed: 50)
        gate.acknowledge(consumed: 10)
        try await gate.reserve(50)
        let (task, completion) = reserve(gate, 1)
        try await settle()
        #expect(completion.value == nil)
        gate.close()
        await task.value
    }

    // A repeated `shell` request starts a second forwarding task on this gate,
    // and the peer controls that, so it must close the channel and not trap.
    @Test func aSecondBlockedForwarderFailsInsteadOfTrapping() async throws {
        let gate = TerminalOutputCreditGate(windowBytes: 100)
        try await gate.reserve(100)
        let (first, firstCompletion) = reserve(gate, 1)
        try await settle()
        await #expect(throws: CancellationError.self) { try await gate.reserve(1) }
        #expect(firstCompletion.value == nil)
        gate.acknowledge(consumed: 1)
        await first.value
        guard case .success? = firstCompletion.value else {
            Issue.record("Expected the first forwarder to keep its reservation")
            return
        }
    }

    @Test func closeAndCancellationReleaseAWaiter() async throws {
        for useCancel in [false, true] {
            let gate = TerminalOutputCreditGate(windowBytes: 100)
            try await gate.reserve(100)
            let (task, completion) = reserve(gate, 1)
            try await settle()
            if useCancel { task.cancel() } else { gate.close() }
            await task.value
            guard case .failure(let error)? = completion.value else {
                Issue.record("Expected the waiter to fail")
                continue
            }
            #expect(error is CancellationError)
        }
    }
}

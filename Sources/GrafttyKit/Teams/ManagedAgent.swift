import Foundation

/// A durable assignment. Presence and terminal layout have independent lifetimes.
public struct ManagedAgent: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case starting, running, waiting
        case awaitingCleanup = "awaiting-cleanup"
        case closing, closed, failed
    }

    public struct Completion: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public let assignmentID: UUID
        public let result: String
        public let date: Date
    }

    public enum LifecycleError: String, Error, LocalizedError {
        case staleAssignment, staleCompletion, invalidState, emptyResult
        public var errorDescription: String? {
            switch self {
            case .staleAssignment: "This assignment has been replaced. Refresh the agent status."
            case .staleCompletion: "Cleanup requires the current completion ID. Refresh the agent status."
            case .invalidState: "This agent cannot perform that transition in its current state."
            case .emptyResult: "Provide a result before finishing the assignment."
            }
        }
    }

    public let id: String
    public let provider: TeamHookRuntime
    public var name: String
    public var parent: TeamInboxEndpoint?
    public private(set) var assignmentID: UUID
    public private(set) var status: Status
    public var paneSlotID: PaneSlotID?
    public var nativeAgentID: String?
    public var parentManagedAgentID: String?
    public var launchOperationID: String?
    public var transcript: String?
    public var initialPrompt: String?
    public private(set) var completion: Completion?
    public private(set) var results: [Completion]
    public private(set) var failure: String?
    /// Completion is an outbox item until its exact parent inbox row is durable.
    public var deliveredCompletionID: UUID?

    public init(name: String, provider: TeamHookRuntime, parent: TeamInboxEndpoint?, status: Status = .running) {
        self.id = TeamAgentIdentity(runtime: provider, nativeSessionID: UUID().uuidString).rawValue
        self.provider = provider
        self.name = name
        self.parent = parent
        self.assignmentID = UUID()
        self.status = status
        self.results = []
    }

    public func launchPrompt(_ task: String?) -> String {
        """
        \(WorktreeAgentLaunchCommand.initialPrompt(task))

        Graftty assignment: \(assignmentID.uuidString). Managed agent: \(id).
        When this assignment is complete, report the result using:
        graftty agent finish \(id) --assignment \(assignmentID.uuidString) --result-stdin
        Supply the result on stdin. This explicitly finishes the assignment and asks your parent to clean up this terminal. Do not run it merely because a turn ends or you need input. Continue to use the graftty Attention skill for ordinary turn recaps. Harness-native subagents remain available for work inside this session.
        """
    }

    @discardableResult
    public mutating func finish(assignment: UUID, result: String) throws -> Completion {
        guard assignment == assignmentID else { throw LifecycleError.staleAssignment }
        if let completion { return completion }
        guard [.starting, .running, .waiting, .failed].contains(status) else { throw LifecycleError.invalidState }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LifecycleError.emptyResult }
        let record = Completion(id: UUID(), assignmentID: assignmentID, result: result, date: Date())
        completion = record
        results.append(record)
        status = .awaitingCleanup
        failure = nil
        return record
    }

    public mutating func beginClose(completion expectedID: UUID) throws {
        guard completion?.id == expectedID, completion?.assignmentID == assignmentID else {
            throw LifecycleError.staleCompletion
        }
        if status == .closed { return }
        guard status == .awaitingCleanup || status == .closing else { throw LifecycleError.invalidState }
        status = .closing
        failure = nil
    }

    public mutating func didClose() {
        guard status == .closing else { return }
        status = .closed
        failure = nil
    }

    public mutating func closeFailed(reason: String) {
        guard status == .closing else { return }
        status = .awaitingCleanup
        failure = reason
    }

    public mutating func launchFailed(reason: String) {
        guard status == .starting else { return }
        status = .failed
        failure = reason
    }

    public mutating func observeWaiting(_ waiting: Bool) {
        guard [.starting, .running, .waiting].contains(status) else { return }
        status = waiting ? .waiting : .running
    }

    public mutating func resume() throws {
        guard status == .awaitingCleanup else { throw LifecycleError.invalidState }
        assignmentID = UUID()
        completion = nil
        deliveredCompletionID = nil
        failure = nil
        status = .running
    }
}

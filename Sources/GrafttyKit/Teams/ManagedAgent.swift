import Foundation
import GrafttyProtocol

/// A durable assignment. Presence and terminal layout have independent lifetimes.
/// @spec AGENT-6.86
/// When an unfinished provider exits, the application shall retain an interrupted outcome without claiming successful completion and require parent acknowledgment only for CLI-added additional agents in existing worktrees.
public struct ManagedAgent: Codable, Sendable, Equatable, Identifiable {
    public enum LaunchOrigin: String, Codable, Sendable {
        case cliAgentAdd, userInterface, observedSession, resumedSession
    }

    public enum Status: String, Codable, Sendable {
        case starting, running, waiting
        case awaitingCleanup = "awaiting-cleanup"
        case closing, closed, failed, interrupted
    }

    public struct Completion: Codable, Sendable, Equatable, Identifiable {
        public enum Outcome: String, Codable, Sendable { case completed, interrupted, failed }
        public let id: UUID
        public let assignmentID: UUID
        public let result: String
        public let date: Date
        /// Absent in records written before interrupted assignments were supported.
        public var outcome: Outcome? = nil
    }

    public enum LifecycleError: String, Error, LocalizedError {
        case staleAssignment, staleCompletion, invalidState, emptyResult, ongoingSession
        public var errorDescription: String? {
            switch self {
            case .staleAssignment: "This assignment has been replaced. Refresh the agent status."
            case .staleCompletion: "Cleanup requires the current completion ID. Refresh the agent status."
            case .invalidState: "This agent cannot perform that transition in its current state."
            case .emptyResult: "Provide a result before finishing the assignment."
            case .ongoingSession: "This is an ongoing session. Only CLI-added additional agents can finish a bounded assignment. Close this session explicitly when needed."
            }
        }
    }

    public let id: String
    public let provider: TeamHookRuntime
    public var name: String
    public var parent: TeamInboxEndpoint?
    /// Nil identifies a saved record from before primary-session lifetime was explicit.
    public var isPrimary: Bool?
    /// Unknown provenance never grants bounded-assignment cleanup eligibility.
    public var launchOrigin: LaunchOrigin?
    public private(set) var assignmentID: UUID
    public private(set) var status: Status
    public var paneSlotID: PaneSlotID? {
        didSet { if let paneSlotID { retainedPaneSlotID = paneSlotID } }
    }
    /// Presentation survives terminal cleanup; a restart reserves this same slot.
    public var retainedPaneSlotID: PaneSlotID?
    /// Exact provider conversation ID, never the hashed team routing identity.
    public var providerSessionID: String?
    public var resumingSessionID: String?
    public var presentationSlotID: PaneSlotID? { paneSlotID ?? retainedPaneSlotID }
    public var paneSessionID: PaneSessionID?
    public var processObservation: AgentProcessObservation?
    public var nativeAgentID: String?
    public var nativeBindingDate: Date?
    public var parentManagedAgentID: String?
    public var launchOperationID: String?
    public var launchAssignmentID: UUID?
    public var launchTargetWorktree: String?
    public var transcript: String?
    /// Host-owned archive. `transcript` is retained only for legacy decoding and full detail transport.
    public var transcriptArchive: AgentTranscriptArchive?
    public var transcriptHistory: [UUID: AgentTranscriptArchive]?
    public var initialPrompt: String?
    public private(set) var completion: Completion?
    public private(set) var results: [Completion]
    public private(set) var failure: String?
    /// The interrupted completion a host stop caused. Host start restarts that conversation once.
    public private(set) var hostStopCompletionID: UUID?
    /// Completion is an outbox item until its exact parent inbox row is durable.
    public var deliveredCompletionID: UUID?
    public var deliveryFailure: String?
    public var retainedResultCount: Int?
    public var detailsOmitted: Bool?

    public init(name: String, provider: TeamHookRuntime, parent: TeamInboxEndpoint?, status: Status = .running,
                launchOrigin: LaunchOrigin? = nil, isPrimary: Bool? = nil) {
        self.id = TeamAgentIdentity(runtime: provider, nativeSessionID: UUID().uuidString).rawValue
        self.provider = provider
        self.name = name
        self.parent = parent
        self.launchOrigin = launchOrigin
        self.isPrimary = isPrimary
        self.assignmentID = UUID()
        self.launchAssignmentID = self.assignmentID
        self.status = status
        self.results = []
    }

    public func launchPrompt(_ task: String?) -> String {
        """
        \(WorktreeAgentLaunchCommand.initialPrompt(task))

        \(sessionInstructions)
        """
    }

    public var sessionInstructions: String {
        let identity = "Managed agent \(id), assignment \(assignmentID.uuidString)."
        if isPrimary == true {
            return """
            \(identity) You are the primary agent for this worktree. Keep this session open for ongoing work, including when another agent created this worktree. Completing a task or opening a PR does not finish this session. Do not finish this agent automatically; finish only if the user explicitly asks to end it. Report progress through Graftty Attention and send a result to your creating agent when needed.
            """
        }
        if !isBoundedAssignment {
            return """
            \(identity) You are an ongoing agent in this worktree. Keep this session open for ongoing work. Completing a task, ending a turn, or posting an Attention recap does not finish this session. Close it only when the user explicitly asks. Report progress through Graftty Attention and send a result to your creating agent when needed.
            """
        }
        return """
        \(identity) You are an additional agent in this worktree. When this assignment is complete, report the result using:
        graftty agent finish \(id) --assignment \(assignmentID.uuidString) --result-stdin
        Supply the result on stdin. This explicitly finishes the assignment and asks your parent to clean up this terminal. Do not run it merely because a turn ends or you need input. Continue to use the graftty Attention skill for ordinary turn recaps. Harness-native subagents remain available for work inside this session.
        """
    }

    @discardableResult
    public mutating func finish(assignment: UUID, result: String) throws -> Completion {
        guard assignment == assignmentID else { throw LifecycleError.staleAssignment }
        guard isBoundedAssignment else { throw LifecycleError.ongoingSession }
        if let completion { return completion }
        guard [.starting, .running, .waiting, .failed].contains(status) else { throw LifecycleError.invalidState }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LifecycleError.emptyResult }
        let record = Completion(id: UUID(), assignmentID: assignmentID, result: result, date: Date(), outcome: .completed)
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
        guard [.awaitingCleanup, .interrupted, .failed, .closing].contains(status) else { throw LifecycleError.invalidState }
        retainedPaneSlotID = presentationSlotID
        status = .closing
        failure = nil
    }

    public mutating func didClose() {
        guard status == .closing else { return }
        status = .closed
        paneSlotID = nil
        processObservation = .exited
        failure = nil
    }

    public mutating func closeFailed(reason: String) {
        guard status == .closing else { return }
        status = completion?.outcome == .interrupted ? .interrupted : completion?.outcome == .failed ? .failed : .awaitingCleanup
        failure = reason
    }

    public mutating func recordFailure(_ reason: String) { failure = reason }

    public mutating func launchFailed(reason: String) {
        guard completion == nil, status != .closed else { return }
        sessionEnded(reason: reason, failedLaunch: true)
    }

    public mutating func sessionEnded(reason: String, failedLaunch: Bool = false, hostStopped: Bool = false) {
        let wasUnfinished = completion == nil
        processObservation = .exited
        recordInterruption(reason: reason, failedLaunch: failedLaunch)
        if hostStopped, wasUnfinished, completion?.outcome == .interrupted { hostStopCompletionID = completion?.id }
    }

    /// A provider bound by the running host did not end with an earlier host stop.
    public func launchedBefore(_ hostStart: Date) -> Bool { nativeBindingDate.map { $0 < hostStart } ?? true }

    /// A closed tab has no pane slot, and a bounded assignment keeps its outcome for the parent.
    public var awaitsHostRestart: Bool {
        !isBoundedAssignment && status == .interrupted && paneSlotID != nil && providerSessionID?.isEmpty == false
            && hostStopCompletionID != nil && hostStopCompletionID == completion?.id
    }

    /// One attempt per host stop: a failed restart leaves the manual Resume action.
    public mutating func hostRestartAttempted() { hostStopCompletionID = nil }

    /// Closing intent records the assignment outcome without claiming the process has exited.
    public mutating func requestSessionClose(reason: String) {
        recordInterruption(reason: reason, failedLaunch: false)
    }

    private mutating func recordInterruption(reason: String, failedLaunch: Bool) {
        guard status != .closed else { return }
        if completion == nil {
            let record = Completion(id: UUID(), assignmentID: assignmentID, result: reason,
                date: Date(), outcome: failedLaunch ? .failed : .interrupted)
            completion = record
            results.append(record)
            deliveredCompletionID = nil
            status = failedLaunch ? .failed : .interrupted
            failure = reason
        }
    }

    public var isBoundedAssignment: Bool { launchOrigin == .cliAgentAdd && isPrimary == false }

    public var requiresAcknowledgment: Bool { isBoundedAssignment && completion != nil && status != .closed }

    /// A transport projection. The stored record is never modified.
    public func summary(maximumResultBytes: Int = 1024) -> Self {
        var value = self
        value.transcript = nil
        value.transcriptHistory = nil
        value.initialPrompt = nil
        value.retainedResultCount = results.count
        value.results = []
        value.detailsOmitted = true
        value.name = AgentTextPreview.prefix(name, bytes: 256)
        value.failure = failure.map { AgentTextPreview.prefix($0, bytes: 1024) }
        if let completion {
            value.completion = Completion(id: completion.id, assignmentID: completion.assignmentID,
                result: AgentTextPreview.prefix(completion.result, bytes: maximumResultBytes),
                date: completion.date, outcome: completion.outcome)
        }
        return value
    }

    public mutating func observeWaiting(_ waiting: Bool) {
        guard [.starting, .running, .waiting].contains(status) else { return }
        processObservation = .reachable
        status = waiting ? .waiting : .running
    }

    public mutating func restartConversation() throws {
        guard status == .closed, let conversation = providerSessionID, !conversation.isEmpty else {
            throw LifecycleError.invalidState
        }
        resetConversationAssignment()
        resumingSessionID = conversation
        launchOrigin = .resumedSession
        paneSlotID = presentationSlotID ?? PaneSlotID()
        if paneSessionID == nil { paneSessionID = PaneSessionID() }
        processObservation = nil
        status = .starting
    }

    /// A launch that failed before its provider started holds no conversation, only its task.
    public var canRetryLaunch: Bool {
        status == .failed && completion?.outcome == .failed && providerSessionID?.isEmpty != false
    }

    public mutating func retryLaunch() throws {
        guard canRetryLaunch else { throw LifecycleError.invalidState }
        let task = initialPrompt
        resetConversationAssignment()
        initialPrompt = task
        launchTargetWorktree = nil
        paneSlotID = presentationSlotID ?? PaneSlotID()
        paneSessionID = PaneSessionID()
        processObservation = nil
        status = .starting
    }

    /// A new provider started in a surviving ongoing shell owns a fresh assignment.
    mutating func recoverOngoingConversation() {
        guard !isBoundedAssignment, completion != nil,
              [.interrupted, .failed, .awaitingCleanup].contains(status) else { return }
        resetConversationAssignment()
        launchOrigin = .observedSession
        resumingSessionID = nil
        status = .running
    }

    private mutating func resetConversationAssignment() {
        if let transcriptArchive { transcriptHistory = (transcriptHistory ?? [:]).merging([assignmentID: transcriptArchive]) { _, new in new } }
        transcriptArchive = nil
        transcript = nil
        assignmentID = UUID()
        launchAssignmentID = assignmentID
        nativeBindingDate = nil
        completion = nil
        deliveredCompletionID = nil
        deliveryFailure = nil
        failure = nil
        initialPrompt = nil
    }

    /// A restart that never acquired a live binding is safe to retry after host recovery.
    public mutating func recoverUnlaunchedConversation() {
        guard status == .starting, resumingSessionID != nil, let previous = results.last else { return }
        assignmentID = previous.assignmentID
        completion = previous
        launchAssignmentID = previous.assignmentID
        transcriptArchive = transcriptHistory?[previous.assignmentID]
        paneSlotID = nil
        processObservation = .exited
        resumingSessionID = nil
        status = .closed
        failure = "The host stopped before the conversation could restart. Resume session to retry."
    }

    public mutating func resume() throws {
        guard status == .awaitingCleanup, processObservation != .exited,
              processObservation != .disconnected else { throw LifecycleError.invalidState }
        assignmentID = UUID()
        completion = nil
        deliveredCompletionID = nil
        failure = nil
        status = .running
    }
}

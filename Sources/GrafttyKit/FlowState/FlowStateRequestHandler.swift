import Foundation

public struct FlowStateRequestHandler {
    private let store: FlowStateStore
    private let activityStore: FlowStateActivityStore
    private let appState: AppState
    private let signals: FlowExternalSignals
    private let status: FlowStatus
    private let now: () -> Date

    public init(
        store: FlowStateStore,
        activityStore: FlowStateActivityStore,
        appState: AppState,
        signals: FlowExternalSignals = .empty,
        status: FlowStatus = .init(enabled: false, running: false, message: nil),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.activityStore = activityStore
        self.appState = appState
        self.signals = signals
        self.status = status
        self.now = now
    }

    public func handle(_ message: NotificationMessage) throws -> ResponseMessage? {
        switch message {
        case .flowStatus:
            return .flowStatus(status)
        case .flowContext:
            return .flowContext(try context())
        case .flowRecommend:
            return .flowRecommendation(try store.recommendation() ?? fallbackRecommendation())
        case let .flowSnooze(worktreeRef, until, reason):
            try store.writeSnooze(FlowSnooze(worktreeRef: worktreeRef, updatedAt: now(), until: until, reason: reason))
            return .ok
        case let .flowNote(worktreeRef, body):
            try store.writeNote(FlowWorktreeNote(worktreeRef: worktreeRef, updatedAt: now(), body: body))
            return .ok
        case let .flowSummary(summary):
            try store.writeSummary(summary)
            return .ok
        case let .flowPublish(rawJSON):
            return try handlePublish(rawJSON: rawJSON)
        case .flowRequestStatus:
            return nil
        default:
            return nil
        }
    }

    private func context() throws -> FlowContextEnvelope {
        try FlowStateContextBuilder.build(
            appState: appState,
            summaries: store.summaries(),
            notes: store.notes(),
            snoozes: store.snoozes(),
            signals: signals,
            now: now()
        )
    }

    private func handlePublish(rawJSON: String) throws -> ResponseMessage {
        do {
            var recommendation = try JSONDecoder.flowState.decode(
                FlowRecommendationEnvelope.self,
                from: Data(rawJSON.utf8)
            )
            recommendation.proposedActions = recommendation.proposedActions.map(actionWithPolicyRequirement)
            try store.writeRecommendation(recommendation)
            try activityStore.append(FlowStateActivity(
                createdAt: now(),
                kind: .publishAccepted,
                message: "accepted recommendation",
                worktreeRef: recommendation.primary.worktreeRef
            ))
            return .ok
        } catch {
            try activityStore.append(FlowStateActivity(
                createdAt: now(),
                kind: .publishError,
                message: String(describing: error),
                worktreeRef: nil
            ))
            return .error("invalid Flow State recommendation: \(error)")
        }
    }

    private func actionWithPolicyRequirement(_ action: FlowProposedAction) -> FlowProposedAction {
        var copy = action
        copy.extraFields["effectiveRequirement"] = .string(
            FlowStateActionPolicy.effectiveRequirement(for: action).rawValue
        )
        return copy
    }

    private func fallbackRecommendation() -> FlowRecommendationEnvelope {
        FlowRecommendationEnvelope(
            generatedAt: now(),
            primary: FlowPrimaryRecommendation(
                intent: .none,
                title: "No recommendation",
                reason: "No Flow State recommendation has been published yet.",
                confidence: .low
            )
        )
    }
}

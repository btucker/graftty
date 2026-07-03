import SwiftUI
import GrafttyKit

enum FlowStateActionPresentationState: Equatable {
    case autonomous
    case needsConfirmation
    case explicitOptInOnly
    case unsupported
}

struct FlowStateProposedActionRow: Identifiable, Equatable {
    let action: FlowProposedAction
    let state: FlowStateActionPresentationState
    let detail: String

    var id: String { action.id }

    var isConfirmable: Bool {
        state == .needsConfirmation
    }
}

struct FlowStateViewModel: Equatable {
    let primaryTitle: String
    let primaryReason: String
    let sameContext: [FlowSameContextItem]
    let heldInterruptions: [FlowHeldInterruptionItem]
    let resumeCards: [FlowResumeCard]
    let proposedActions: [FlowStateProposedActionRow]
    let recentActivity: [FlowStateActivity]

    static func make(
        recommendation: FlowRecommendationEnvelope?,
        status: FlowStatus,
        activity: [FlowStateActivity] = []
    ) -> FlowStateViewModel {
        guard let recommendation else {
            return FlowStateViewModel(
                primaryTitle: unavailableTitle(status),
                primaryReason: unavailableReason(status),
                sameContext: [],
                heldInterruptions: [],
                resumeCards: [],
                proposedActions: [],
                recentActivity: activity
            )
        }

        return FlowStateViewModel(
            primaryTitle: recommendation.primary.title,
            primaryReason: recommendation.primary.reason,
            sameContext: recommendation.sameContext,
            heldInterruptions: recommendation.heldInterruptions,
            resumeCards: recommendation.resumeCards,
            proposedActions: recommendation.proposedActions.map(actionRow(for:)),
            recentActivity: activity
        )
    }

    private static func unavailableTitle(_ status: FlowStatus) -> String {
        if let message = status.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        if !status.enabled {
            return "Flow State is off"
        }
        if !status.running {
            return "Flow State is idle"
        }
        return "No recommendation yet"
    }

    private static func unavailableReason(_ status: FlowStatus) -> String {
        if !status.enabled {
            return "Enable Flow State to let Graftty render recommendations from the latest agent publish."
        }
        if !status.running {
            return "Open or restart the Flow State agent pane, then refresh after it publishes a recommendation."
        }
        return "Flow State is running, but no valid recommendation has been published yet."
    }

    private static func actionRow(for action: FlowProposedAction) -> FlowStateProposedActionRow {
        let state: FlowStateActionPresentationState
        let detail: String
        switch FlowStateActionPolicy.effectiveRequirement(for: action) {
        case .autonomousAllowed:
            state = .autonomous
            detail = "Handled automatically when policy allows."
        case .confirmationRequired:
            state = .needsConfirmation
            detail = "Needs confirmation before Graftty runs it."
        case .explicitOptInOnly:
            state = .explicitOptInOnly
            detail = "Visible for review; this action type is not available from this view."
        case .unsupported:
            state = .unsupported
            detail = "Unsupported by this Graftty version."
        }
        return FlowStateProposedActionRow(action: action, state: state, detail: detail)
    }
}

struct FlowStateSidebarStatus {
    static func label(recommendation: FlowRecommendationEnvelope?, status: FlowStatus) -> String {
        if let title = recommendation?.primary.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let message = status.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        if !status.enabled {
            return "Off"
        }
        if status.running {
            return "Running"
        }
        return "Idle"
    }
}

struct FlowStateView: View {
    let status: FlowStatus
    let recommendation: FlowRecommendationEnvelope?
    let activity: [FlowStateActivity]
    var requestRefresh: () -> Void = {}
    var openAgentPane: () -> Void = {}
    var restartAgent: () -> Void = {}
    var confirmAction: (FlowProposedAction) -> Void = { _ in }

    var body: some View {
        let model = FlowStateViewModel.make(
            recommendation: recommendation,
            status: status,
            activity: activity
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(model)
                if !model.sameContext.isEmpty {
                    itemSection("Same Context", model.sameContext) { item in
                        FlowStateItemRow(
                            title: item.title,
                            detail: item.reason,
                            meta: [item.worktreeRef, item.estimatedEffort?.rawValue, item.confidence?.rawValue]
                        )
                    }
                }
                if !model.heldInterruptions.isEmpty {
                    itemSection("Held Interruptions", model.heldInterruptions) { item in
                        FlowStateItemRow(
                            title: item.title,
                            detail: item.reason,
                            meta: [item.worktreeRef, holdUntilText(item.holdUntil), item.urgency?.rawValue]
                        )
                    }
                }
                if !model.resumeCards.isEmpty {
                    itemSection("Resume", model.resumeCards) { card in
                        FlowStateItemRow(
                            title: card.title,
                            detail: "\(card.summary)\nNext: \(card.nextAction)",
                            meta: [card.worktreeRef, card.stale ? "stale" : nil]
                        )
                    }
                }
                if !model.proposedActions.isEmpty {
                    itemSection("Proposed Actions", model.proposedActions) { row in
                        FlowStateActionRow(row: row, confirmAction: confirmAction)
                    }
                }
                if !model.recentActivity.isEmpty {
                    itemSection("Recent Activity", model.recentActivity) { item in
                        FlowStateItemRow(
                            title: activityTitle(item.kind),
                            detail: item.message,
                            meta: [item.worktreeRef, item.createdAt.formatted(date: .abbreviated, time: .shortened)]
                        )
                    }
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func header(_ model: FlowStateViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Flow State", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Spacer()
                HStack(spacing: 8) {
                    Button("Refresh", action: requestRefresh)
                    Button("Open Flow State Agent Pane", action: openAgentPane)
                    Button("Restart Agent", action: restartAgent)
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(model.primaryTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                Text(model.primaryReason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func itemSection<Data: RandomAccessCollection, Content: View>(
        _ title: String,
        _ data: Data,
        @ViewBuilder row: @escaping (Data.Element) -> Content
    ) -> some View {
        let rows = Array(data.enumerated())
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(rows, id: \.offset) { offset, item in
                    row(item)
                    if offset != rows.indices.last {
                        Divider()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
    }

    private func holdUntilText(_ holdUntil: FlowHoldUntil?) -> String? {
        switch holdUntil {
        case .nextFocusBreak:
            return "next focus break"
        case .manualRefresh:
            return "manual refresh"
        case .absolute(let date):
            return date.formatted(date: .abbreviated, time: .shortened)
        case nil:
            return nil
        }
    }

    private func activityTitle(_ kind: FlowStateActivity.Kind) -> String {
        switch kind {
        case .publishError:
            return "Publish Error"
        case .publishAccepted:
            return "Publish Accepted"
        case .statusRequestSent:
            return "Status Request Sent"
        case .statusRequestSkipped:
            return "Status Request Skipped"
        case .actionRequiresConfirmation:
            return "Action Needs Confirmation"
        case .actionExecuted:
            return "Action Executed"
        case .actionSkipped:
            return "Action Skipped"
        }
    }
}

private struct FlowStateItemRow: View {
    let title: String
    let detail: String
    let meta: [String?]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 12)
                metaText
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var metaText: some View {
        let values = meta.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        if !values.isEmpty {
            Text(values.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct FlowStateActionRow: View {
    let row: FlowStateProposedActionRow
    let confirmAction: (FlowProposedAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(row.action.kind.rawValue)
                        .font(.callout)
                        .fontWeight(.medium)
                    if let target = row.action.target {
                        Text(target)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let body = row.action.body {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            actionControl
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var actionControl: some View {
        switch row.state {
        case .autonomous:
            Text("Auto")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .needsConfirmation:
            Button("Confirm") {
                confirmAction(row.action)
            }
            .buttonStyle(.bordered)
        case .explicitOptInOnly:
            Text("Manual only")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unsupported:
            Text("Unsupported")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

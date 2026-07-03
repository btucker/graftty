import Foundation

public protocol FlowTeamMessaging {
    func sendStatusRequest(target: String, body: String) throws
    func sendMessage(target: String, body: String) throws
}

public enum FlowTeamMessagingError: Error, Sendable, Equatable {
    case skipped(String)
}

public protocol FlowConfirmedAppActions {
    func focusWorktree(ref: String) throws
    func restartAgent(ref: String) throws
}

public enum FlowStatePermissionMode: String, Codable, Sendable, Equatable {
    case conservative
    case manualOnly
}

public struct FlowStateActionExecutor {
    private let activityStore: FlowStateActivityStore
    private let teamMessenger: any FlowTeamMessaging
    private let appActions: (any FlowConfirmedAppActions)?
    private let permissionMode: FlowStatePermissionMode
    private let statusRequestCooldown: TimeInterval
    private let now: () -> Date

    public init(
        activityStore: FlowStateActivityStore,
        teamMessenger: any FlowTeamMessaging,
        appActions: (any FlowConfirmedAppActions)? = nil,
        permissionMode: FlowStatePermissionMode = .conservative,
        statusRequestCooldown: TimeInterval = 1_200,
        now: @escaping () -> Date = Date.init
    ) {
        self.activityStore = activityStore
        self.teamMessenger = teamMessenger
        self.appActions = appActions
        self.permissionMode = permissionMode
        self.statusRequestCooldown = statusRequestCooldown
        self.now = now
    }

    public func executeAutonomousActions(_ actions: [FlowProposedAction]) throws {
        for action in actions {
            let requirement = FlowStateActionPolicy.effectiveRequirement(for: action)
            switch requirement {
            case .autonomousAllowed:
                try executeAutonomousStatusRequest(action)
            case .confirmationRequired:
                try append(
                    kind: .actionRequiresConfirmation,
                    message: "Flow State action requires confirmation: \(action.kind.rawValue)",
                    worktreeRef: action.target
                )
            case .explicitOptInOnly, .unsupported:
                try append(
                    kind: .actionSkipped,
                    message: "Flow State action skipped: \(action.kind.rawValue)",
                    worktreeRef: action.target
                )
            }
        }
    }

    public func requestStatus(worktreeRef: String, explicit: Bool) throws {
        let date = now()
        if permissionMode == .manualOnly {
            try append(
                kind: .statusRequestSkipped,
                message: "Flow State status request requires confirmation in manual-only mode",
                worktreeRef: worktreeRef,
                at: date
            )
            try append(
                kind: .actionRequiresConfirmation,
                message: "Flow State status request requires confirmation",
                worktreeRef: worktreeRef,
                at: date
            )
            return
        }

        if !explicit, let last = try activityStore.lastStatusRequestAt(worktreeRef: worktreeRef),
           date.timeIntervalSince(last) < statusRequestCooldown {
            try append(
                kind: .statusRequestSkipped,
                message: "Flow State status request skipped during cooldown",
                worktreeRef: worktreeRef,
                at: date
            )
            return
        }

        do {
            try teamMessenger.sendStatusRequest(
                target: worktreeRef,
                body: FlowStateActionPolicy.statusRequestTemplate
            )
        } catch FlowTeamMessagingError.skipped(let message) {
            try append(
                kind: .statusRequestSkipped,
                message: message,
                worktreeRef: worktreeRef,
                at: date
            )
            return
        }
        try append(
            kind: .statusRequestSent,
            message: "Flow State requested status",
            worktreeRef: worktreeRef,
            at: date
        )
        try activityStore.recordStatusRequest(worktreeRef: worktreeRef, at: date)
    }

    public func executeConfirmedAction(_ action: FlowProposedAction) throws {
        switch action.kind {
        case .teamStatusRequest:
            try requestStatus(worktreeRef: action.target ?? "", explicit: true)
        case .teamMessage:
            guard let target = action.target, let body = action.body else {
                try append(kind: .actionSkipped, message: "Flow State team message missing target or body", worktreeRef: action.target)
                return
            }
            try teamMessenger.sendMessage(target: target, body: body)
            try append(kind: .actionExecuted, message: "Flow State sent confirmed team message", worktreeRef: target)
        case .focusWorktree:
            guard let target = action.target else {
                try append(kind: .actionSkipped, message: "Flow State focus action missing target", worktreeRef: nil)
                return
            }
            guard let appActions else {
                try append(kind: .actionSkipped, message: "Flow State focus action skipped: app actions unavailable", worktreeRef: target)
                return
            }
            try appActions.focusWorktree(ref: target)
            try append(kind: .actionExecuted, message: "Flow State focused confirmed worktree", worktreeRef: target)
        case .restartAgent:
            guard let target = action.target else {
                try append(kind: .actionSkipped, message: "Flow State restart action missing target", worktreeRef: nil)
                return
            }
            guard let appActions else {
                try append(kind: .actionSkipped, message: "Flow State restart action skipped: app actions unavailable", worktreeRef: target)
                return
            }
            try appActions.restartAgent(ref: target)
            try append(kind: .actionExecuted, message: "Flow State restarted confirmed agent", worktreeRef: target)
        case .paneCommand:
            try append(
                kind: .actionSkipped,
                message: "Flow State pane command skipped: explicit opt-in is not available",
                worktreeRef: action.target
            )
        }
    }

    private func executeAutonomousStatusRequest(_ action: FlowProposedAction) throws {
        guard let target = action.target else {
            try append(kind: .actionSkipped, message: "Flow State status request missing target", worktreeRef: nil)
            return
        }
        if permissionMode == .manualOnly {
            try append(
                kind: .actionRequiresConfirmation,
                message: "Flow State status request requires confirmation",
                worktreeRef: target
            )
            return
        }
        do {
            try teamMessenger.sendStatusRequest(
                target: target,
                body: FlowStateActionPolicy.statusRequestTemplate
            )
        } catch FlowTeamMessagingError.skipped(let message) {
            try append(kind: .actionSkipped, message: message, worktreeRef: target)
            return
        }
        let date = now()
        try append(
            kind: .actionExecuted,
            message: "Flow State executed autonomous status request",
            worktreeRef: target,
            at: date
        )
        try activityStore.recordStatusRequest(worktreeRef: target, at: date)
    }

    private func append(
        kind: FlowStateActivity.Kind,
        message: String,
        worktreeRef: String?,
        at date: Date? = nil
    ) throws {
        try activityStore.append(.init(
            createdAt: date ?? now(),
            kind: kind,
            message: message,
            worktreeRef: worktreeRef
        ))
    }
}

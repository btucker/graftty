import AppKit
import SwiftUI
import GrafttyKit

/// Retains the latest local notification click until a window can handle it.
@MainActor
final class AgentNotificationActivation: ObservableObject {
    static let shared = AgentNotificationActivation()

    struct Request: Equatable {
        let id = UUID()
        let payload: AgentStopNotificationPayload
    }

    @Published private(set) var pending: Request?

    func enqueue(_ payload: AgentStopNotificationPayload) {
        pending = Request(payload: payload)
    }

    func consume(_ id: UUID) -> AgentStopNotificationPayload? {
        guard let request = pending, request.id == id else { return nil }
        pending = nil
        return request.payload
    }

    /// Selection owns wake, renderer restoration, focus, and acknowledgement.
    @discardableResult
    static func open(
        _ payload: AgentStopNotificationPayload,
        worktree: WorktreeEntry?,
        selectWorktree: (String) -> Bool,
        selectPane: (String, PaneSlotID) -> Bool
    ) -> Bool {
        guard let worktree, worktree.path == payload.worktreePath, !worktree.state.isInFlight else { return false }
        if worktree.state == .running, let pane = GrafttyApp.agentStopFocusTarget(worktree: worktree, paneSessionName: payload.paneSessionName) {
            return selectPane(worktree.path, pane)
        }
        return selectWorktree(worktree.path)
    }
}

struct AgentNotificationActivationHandler: ViewModifier {
    @ObservedObject var activation: AgentNotificationActivation
    let onActivate: (AgentStopNotificationPayload) -> Void

    func body(content: Content) -> some View {
        content.background(AgentNotificationActivationWindowBridge(
            activation: activation, requestID: activation.pending?.id, onActivate: onActivate))
    }
}

private struct AgentNotificationActivationWindowBridge: NSViewRepresentable {
    let activation: AgentNotificationActivation
    let requestID: UUID?
    let onActivate: (AgentStopNotificationPayload) -> Void

    func makeNSView(context: Context) -> NotificationActivationWindowView {
        NotificationActivationWindowView()
    }

    func updateNSView(_ view: NotificationActivationWindowView, context: Context) {
        view.activation = activation
        view.requestID = requestID
        view.onActivate = onActivate
        view.scheduleActivation()
    }

    static func dismantleNSView(_ view: NotificationActivationWindowView, coordinator: ()) {
        view.activation = nil
        view.onActivate = nil
    }
}

private final class NotificationActivationWindowView: NSView {
    weak var activation: AgentNotificationActivation?
    var requestID: UUID?
    var onActivate: ((AgentStopNotificationPayload) -> Void)?
    private var activationScheduled = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleActivation()
    }

    func scheduleActivation() {
        guard !activationScheduled else { return }
        activationScheduled = true
        // Consume outside SwiftUI updates, after AppKit has attached the view.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activationScheduled = false
            guard let window = self.window, let id = self.requestID,
                  let onActivate = self.onActivate, let payload = self.activation?.consume(id) else { return }
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            onActivate(payload)
        }
    }
}

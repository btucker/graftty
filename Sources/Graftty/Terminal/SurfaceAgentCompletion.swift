import AppKit
import Combine
import SwiftUI
import GrafttyCommandUI
import GrafttyProtocol

extension SurfaceNSView {
    func configureAgentCompletion(currentWorktreePath: String?,
                                  updates: ((@escaping AgentCompletionModel.CatalogUpdate) async throws -> [AgentCompletionCandidate])? = nil,
                                  loader: @escaping () async throws -> [AgentCompletionCandidate]) {
        agentCompletion.currentWorktreePath = currentWorktreePath
        agentCompletion.loadCandidates = loader
        agentCompletion.loadCandidatesWithUpdates = updates
        agentCompletion.onInsertText = { [weak self] text in self?.insertAgentCompletionText(text, claimEngagement: true) }
        agentCompletion.onInsertLiteral = { [weak self] text in self?.insertAgentCompletionText(text, claimEngagement: false) }
        agentCompletionPresentation = MacAgentCompletionPresentation(view: self)
    }

    func handleAgentCompletionKey(_ event: NSEvent) -> Bool {
        guard !isReadonly, !hasMarkedText() else { return false }
        if event.isARepeat, agentCompletionKeyCodes.contains(event.keyCode),
           [36, 76, 48].contains(event.keyCode)
            || (!agentCompletion.isActive && [51, 53, 125, 126].contains(event.keyCode)) { return true }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            agentCompletion.invalidateBoundary()
            return false
        }
        let consumed: Bool
        switch event.keyCode {
        case 125: consumed = agentCompletion.handleKey(.down)
        case 126: consumed = agentCompletion.handleKey(.up)
        case 36, 76, 48: consumed = agentCompletion.handleKey(.accept)
        case 53: consumed = agentCompletion.handleKey(.escape)
        case 51: consumed = agentCompletion.handleBackspace()
        default:
            if let text = Self.ghosttyTextField(for: event), !text.isEmpty {
                consumed = agentCompletion.handleText(text)
            } else {
                agentCompletion.invalidateBoundary()
                consumed = false
            }
        }
        if consumed { agentCompletionKeyCodes.insert(event.keyCode) }
        else {
            agentCompletionKeyCodes.remove(event.keyCode)
            // Navigation and non-text control keys leave the insertion point unknown.
            if [123, 124, 125, 126, 115, 119, 117, 116, 121].contains(event.keyCode) {
                agentCompletion.invalidateBoundary()
            } else if [36, 76].contains(event.keyCode) {
                agentCompletion.cancel(preserveLiteral: false)
            }
        }
        return consumed
    }

    private func insertAgentCompletionText(_ text: String, claimEngagement: Bool) {
        guard let surface, !isReadonly, acceptsCompositionCallbacks else { return }
        // A focus-loss flush must not take ownership back from another client.
        // Real key/native-text input reclaims control before reaching this path.
        if canTakeDisplayControlNotifier?() == true {
            guard claimEngagement, takeDisplayControlNotifier?() == true else { return }
        }
        // Cursor keys use this synchronous host-managed writer too. Queueing
        // text through Ghostty's IO thread would let a following key overtake it.
        if let hostManagedCompletionWriter {
            hostManagedCompletionWriter(Data(text.utf8), claimEngagement)
            return
        }
        if let hostManagedInputWriter {
            hostManagedInputWriter(Data(text.utf8))
            return
        }
        let deliver = { self.surfaceOperations.text(surface, text) }
        if let hostManagedUserInputScope { hostManagedUserInputScope(deliver) }
        else { deliver() }
    }
}

/// The terminal remains first responder while SwiftUI renders the native list.
@MainActor
final class MacAgentCompletionPresentation {
    private weak var view: SurfaceNSView?
    private var hostingView: NSHostingView<AgentCompletionPicker>?
    private var observation: AnyCancellable?

    init(view: SurfaceNSView) {
        self.view = view
        observation = view.agentCompletion.$isActive.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.update() }
        }
    }

    private func update() {
        guard let view, view.agentCompletion.isActive else {
            hostingView?.removeFromSuperview()
            hostingView = nil
            return
        }
        if hostingView == nil {
            let host = NSHostingView(rootView: AgentCompletionPicker(model: view.agentCompletion))
            hostingView = host
            view.addSubview(host)
        }
        layout()
    }

    func layout() {
        guard let view, let host = hostingView else { return }
        let caret = view.surface.map(view.surfaceOperations.imeRect) ?? .zero
        let width = min(360, view.bounds.width)
        let height = min(310, view.bounds.height)
        let x = min(max(0, caret.minX), max(0, view.bounds.width - width))
        let below = view.bounds.height - caret.maxY - height
        let y = below >= 0 ? below : min(max(0, view.bounds.height - caret.minY), max(0, view.bounds.height - height))
        host.frame = NSRect(x: x, y: y, width: width, height: height)
    }
}

#if canImport(UIKit)
import GhosttyTerminal
import Observation
import SwiftUI

private struct RetainedMobilePanesKey: EnvironmentKey {
    static let defaultValue: RetainedPaneClientPool<RetainedMobilePane>? = nil
}

extension EnvironmentValues {
    var retainedMobilePanes: RetainedPaneClientPool<RetainedMobilePane>? {
        get { self[RetainedMobilePanesKey.self] }
        set { self[RetainedMobilePanesKey.self] = newValue }
    }
}

/// The renderer must outlive its route too: incoming terminal bytes need a
/// live Ghostty surface even when UIKit has detached the pane from its window.
@MainActor
final class RetainedMobilePane: PanePreviewClienting {
    let client: SessionClient
    let assignmentID: String?
    var container: TerminalInputContainerView? {
        didSet { if container !== oldValue { observePresentation() } }
    }
    private(set) var requiresValidation = false
    var sessionName: String { client.sessionName }

    init(client: SessionClient, assignmentID: String? = nil) {
        self.client = client
        self.assignmentID = assignmentID
    }

    /// The same terminal name can belong to a restarted provider invocation.
    /// Keep the generation with the retained client, beyond a view's lifetime.
    @discardableResult
    static func discardPreviousAssignment(from pool: RetainedPaneClientPool<RetainedMobilePane>?,
                                          key: RetainedPaneClientPool<RetainedMobilePane>.Key,
                                          assignmentID: String?) -> Bool {
        guard let assignmentID, let previous = pool?.cached(key), previous.assignmentID != assignmentID else { return false }
        pool?.remove(key)
        return true
    }
    func start() { client.start() }
    func resume() { requiresValidation = false; client.resume() }
    func suspend() { requiresValidation = true; client.suspend() }
    func stop() {
        client.stop()
        detachControls()
        container = nil
    }

    func detachControls() {
        container?.controlAttachmentID = nil
        container?.resetStickyModifiers()
        container?.terminalView.resignFirstResponder()
        container?.committedSoftwareInput = nil
        container?.agentCompletion = nil
        container?.hardwareKeyboardCommands = []
        container?.onUserInteraction = nil
        container?.onApplicationScrollRequested = nil
        container?.onPasteRequested = nil
        container?.onBackRequested = nil
        container?.detachBrowserControls()
        container?.onPhysicalViewportReady = nil
        container?.setStickyControlActivationChangeHandler(nil)
        container?.onTrayShiftSelectionChange = nil
        container?.configureFontSizeObservation(initialFontSize: nil, onChange: nil)
    }

    private func observePresentation() {
        guard let container else { return }
        // A hidden pane can become a follower when the Mac takes control.
        // Keep its renderer on the authoritative grid while output continues.
        withObservationTracking {
            container.authoritativeGrid = client.snapshotCanvasGrid
            container.terminalView.renderPace = client.renderPace
            container.layoutIfNeeded()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observePresentation() }
        }
    }
}
#endif

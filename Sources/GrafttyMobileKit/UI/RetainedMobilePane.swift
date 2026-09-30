#if canImport(UIKit)
import GhosttyTerminal
import Observation

/// The renderer must outlive its route too: incoming terminal bytes need a
/// live Ghostty surface even when UIKit has detached the pane from its window.
@MainActor
final class RetainedMobilePane: PanePreviewClienting {
    let client: SessionClient
    var container: TerminalInputContainerView? {
        didSet { if container !== oldValue { observePresentation() } }
    }
    private(set) var requiresValidation = false
    var sessionName: String { client.sessionName }

    init(client: SessionClient) { self.client = client }
    func start() { client.start() }
    func resume() { requiresValidation = false; client.resume() }
    func suspend() { requiresValidation = true; client.suspend() }
    func stop() {
        client.stop()
        detachControls()
        container = nil
    }

    func detachControls() {
        container?.resetStickyModifiers()
        container?.terminalView.resignFirstResponder()
        container?.committedSoftwareInput = nil
        container?.hardwareKeyboardCommands = []
        container?.onUserInteraction = nil
        container?.onPasteRequested = nil
        container?.onPhysicalViewportReady = nil
        container?.setStickyControlActivationChangeHandler(nil)
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

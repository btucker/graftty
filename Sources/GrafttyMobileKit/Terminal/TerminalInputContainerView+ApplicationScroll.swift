#if canImport(UIKit)
import GhosttyTerminal
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import UIKit

extension TerminalInputContainerView {
    @objc func handleApplicationScroll(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            if applicationScrollAttachmentID != controlAttachmentID {
                cancelPendingApplicationScroll()
                applicationScrollAttachmentID = controlAttachmentID
            }
            applicationScrollEnded = false
            accumulateApplicationScroll(gesture)
            #if DEBUG
            diagnosticApplicationScrollRequests &+= 1
            #endif
            onApplicationScrollRequested?()
            guard applicationScrollTask == nil else { return }
            let attachment = applicationScrollAttachmentID
            applicationScrollTask = Task { @MainActor [weak self] in
                // Preserve an ended drag over a slow ownership round trip, but
                // never replay it indefinitely or into a replacement route.
                for _ in 0..<250 {
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    guard let self, self.applicationScrollAttachmentID == attachment else { return }
                    self.flushPendingApplicationScroll()
                    if self.applicationScrollIsReady {
                        self.applicationScrollTask = nil
                        if self.applicationScrollEnded { self.cancelPendingApplicationScroll() }
                        return
                    }
                }
                self?.cancelPendingApplicationScroll()
            }
        case .changed, .ended:
            accumulateApplicationScroll(gesture)
            applicationScrollEnded = gesture.state == .ended
            flushPendingApplicationScroll()
            if applicationScrollEnded && applicationScrollIsReady { cancelPendingApplicationScroll() }
        case .cancelled, .failed:
            cancelPendingApplicationScroll()
        default: break
        }
    }

    private func accumulateApplicationScroll(_ gesture: UIPanGestureRecognizer) {
        let delta = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        // Bound queued intent while a network claim is pending, including the
        // movement that crossed the recognizer's threshold before .began.
        let limit = max(bounds.width, bounds.height) * 4
        pendingApplicationScroll.x = max(-limit, min(limit, pendingApplicationScroll.x + delta.x))
        pendingApplicationScroll.y = max(-limit, min(limit, pendingApplicationScroll.y + delta.y))
        applicationScrollLocation = gesture.location(in: self)
    }

    private var applicationScrollIsReady: Bool {
        applicationScrollAttachmentID != nil
            && applicationScrollAttachmentID == controlAttachmentID
            && onApplicationScrollRequested != nil && window != nil
            && authoritativeGrid == nil && !awaitingPhysicalViewport
            && terminalView.surface?.isMouseCaptured == true
    }

    private func flushPendingApplicationScroll() {
        guard applicationScrollIsReady, pendingApplicationScroll != .zero,
              let surface = terminalView.surface else { return }
        var point = terminalView.convert(applicationScrollLocation, from: self)
        point.x = max(0, min(terminalView.bounds.width - 1, point.x))
        point.y = max(0, min(terminalView.bounds.height - 1, point.y))
        surface.sendMousePos(x: point.x, y: point.y)
        // Match libghostty-spm's ordinary one-finger touch-scroll multiplier.
        surface.sendMouseScroll(x: Double(pendingApplicationScroll.x * 3),
                                y: Double(pendingApplicationScroll.y * 3))
        pendingApplicationScroll = .zero
        #if DEBUG
        diagnosticApplicationScrollDeliveries &+= 1
        #endif
    }

    /// A later explicit input supersedes an undelivered drag; never replay its
    /// wheel reports after a key or paste that may have changed application mode.
    func cancelPendingApplicationScroll() {
        applicationScrollTask?.cancel()
        applicationScrollTask = nil
        applicationScrollAttachmentID = nil
        pendingApplicationScroll = .zero
        applicationScrollEnded = false
    }
}
#endif

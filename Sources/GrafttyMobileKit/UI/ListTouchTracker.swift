#if canImport(UIKit)
import SwiftUI
import UIKit

/// Reports a finger on a view without taking part in gesture recognition: it
/// never leaves `.possible` while tracking, so scrolling, tapping and swiping
/// behave as if it weren't there. It sits on the window so it can see touches
/// the list's own recognizers would otherwise keep to themselves.
class ListTouchRecognizer: UIGestureRecognizer {
    weak var trackedView: UIView?
    var onChange: ((Bool) -> Void)?
    private(set) var isTracking = false
    /// Counted rather than read from the event, which also holds fingers on
    /// other windows whose lifting never reaches a recognizer on this one.
    private var fingersDown = 0

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    func touchBegan(insideTrackedView: Bool) {
        guard !isTracking else { return }
        guard insideTrackedView else { state = .failed; return }
        isTracking = true
        onChange?(true)
    }

    func stopTracking() {
        fingersDown = 0
        guard isTracking else { return }
        isTracking = false
        onChange?(false)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        fingersDown += touches.count
        let inside = trackedView.map { view in touches.contains { view.bounds.contains($0.location(in: view)) } } ?? false
        touchBegan(insideTrackedView: inside)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        fingersDown -= touches.count
        if fingersDown <= 0 { state = .failed }
    }

    override func reset() {
        super.reset()
        stopTracking()
    }
}

extension ListTouchRecognizer: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Goes behind a list to report whether a finger is on it.
struct ListTouchTracker: UIViewRepresentable {
    @Binding var isTouching: Bool

    final class Marker: UIView {
        let recognizer = ListTouchRecognizer()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            guard let window else {
                // Leaving the screen mid-touch ends nothing the recognizer can see.
                DispatchQueue.main.async { [recognizer] in recognizer.stopTracking() }
                return
            }
            recognizer.trackedView = self
            window.addGestureRecognizer(recognizer)
        }
    }

    func makeUIView(context: Context) -> Marker {
        let marker = Marker()
        marker.isUserInteractionEnabled = false
        return marker
    }

    func updateUIView(_ marker: Marker, context: Context) {
        let binding = $isTouching
        marker.recognizer.onChange = { binding.wrappedValue = $0 }
    }
}
#endif

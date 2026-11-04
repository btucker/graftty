#if canImport(UIKit)
import Testing
import UIKit
@testable import GrafttyMobileKit

@MainActor
struct ListTouchTrackerTests {
    @Test("@spec IOS-13.10: While a finger is on a mobile worktree list, the application shall report it held without claiming the touch, so scrolling, tapping, and swiping keep working.")
    func reportsAFingerWithoutClaimingIt() {
        let recognizer = ListTouchRecognizer()
        var changes: [Bool] = []
        recognizer.onChange = { changes.append($0) }
        #expect(!recognizer.cancelsTouchesInView)
        #expect(!recognizer.delaysTouchesBegan)
        #expect(!recognizer.delaysTouchesEnded)
        recognizer.touchBegan(insideTrackedView: true)
        recognizer.touchBegan(insideTrackedView: true)
        #expect(recognizer.state == .possible)
        recognizer.stopTracking()
        #expect(changes == [true, false])
    }

    /// A finger on another window is in the event, but no touch-up for it ever
    /// reaches a recognizer on this one, so waiting for it would hold rows forever.
    @Test func liftingItsOwnFingerEndsTrackingWhateverElseIsDown() {
        let recognizer = RecordingRecognizer()
        let list = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        recognizer.trackedView = list
        var changes: [Bool] = []
        recognizer.onChange = { changes.append($0) }
        let finger = FakeTouch(phase: .began)
        let onAnotherWindow = FakeTouch(phase: .stationary)
        let event = FakeEvent(touches: [finger, onAnotherWindow])
        recognizer.touchesBegan([finger], with: event)
        #expect(changes == [true])
        finger.fakePhase = .ended
        recognizer.touchesEnded([finger], with: event)
        #expect(recognizer.state == .failed)
        recognizer.reset()
        #expect(changes == [true, false])
    }

    @Test func staysTrackingUntilEveryFingerItSawHasLifted() {
        let recognizer = RecordingRecognizer()
        let list = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        recognizer.trackedView = list
        let first = FakeTouch(phase: .began), second = FakeTouch(phase: .began)
        let event = FakeEvent(touches: [first, second])
        recognizer.touchesBegan([first], with: event)
        recognizer.touchesBegan([second], with: event)
        first.fakePhase = .ended
        recognizer.touchesEnded([first], with: event)
        #expect(recognizer.state == .possible)
        second.fakePhase = .cancelled
        recognizer.touchesCancelled([second], with: event)
        #expect(recognizer.state == .failed)
    }

    /// Leaving the window mid-touch means the lift is never seen, so the count
    /// mustn't carry over and keep the next touch from ever finishing.
    @Test func aTouchLostWithTheWindowDoesNotCountAgainstTheNextOne() {
        let recognizer = RecordingRecognizer()
        let list = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        recognizer.trackedView = list
        let lost = FakeTouch(phase: .began), next = FakeTouch(phase: .began)
        recognizer.touchesBegan([lost], with: FakeEvent(touches: [lost]))
        recognizer.stopTracking()
        recognizer.touchesBegan([next], with: FakeEvent(touches: [next]))
        next.fakePhase = .ended
        recognizer.touchesEnded([next], with: FakeEvent(touches: [next]))
        #expect(recognizer.state == .failed)
    }

    @Test func ignoresAFingerElsewhere() {
        let recognizer = ListTouchRecognizer()
        var changes: [Bool] = []
        recognizer.onChange = { changes.append($0) }
        recognizer.touchBegan(insideTrackedView: false)
        #expect(changes.isEmpty)
        #expect(!recognizer.isTracking)
    }
}
/// UIKit only honors a state change for a recognizer it's delivering touches to.
private final class RecordingRecognizer: ListTouchRecognizer {
    private var recorded: UIGestureRecognizer.State = .possible
    override var state: UIGestureRecognizer.State {
        get { recorded }
        set { recorded = newValue }
    }
}

private final class FakeTouch: UITouch {
    var fakePhase: UITouch.Phase
    init(phase: UITouch.Phase) { fakePhase = phase }
    override var phase: UITouch.Phase { fakePhase }
    override func location(in view: UIView?) -> CGPoint { CGPoint(x: 10, y: 10) }
}

private final class FakeEvent: UIEvent {
    let touches: Set<UITouch>
    init(touches: Set<UITouch>) { self.touches = touches }
    override var allTouches: Set<UITouch>? { touches }
}
#endif

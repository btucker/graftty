import Testing
import AppKit
@testable import Graftty

/// `.rightClickMenu` lives as an overlay NSView on top of the modified
/// SwiftUI view. The overlay must be *invisible* to left-clicks (so the
/// underlying Button still receives them) but *receive* right-clicks and
/// ctrl-clicks (so AppKit dispatches `menu(for:)` to it). The hit-test
/// decision function gates this; these tests pin its behavior.
@Suite("RightClickMenu hit-test gating")
struct RightClickMenuTests {

    @Test func passesThroughLeftClicks() {
        let leftDown = makeEvent(type: .leftMouseDown, modifiers: [])
        #expect(!RightClickHitTest.shouldAcceptHit(for: leftDown))
    }

    @Test func acceptsRightMouseDown() {
        let rightDown = makeEvent(type: .rightMouseDown, modifiers: [])
        #expect(RightClickHitTest.shouldAcceptHit(for: rightDown))
    }

    @Test func acceptsCtrlLeftClick() {
        let ctrlLeftDown = makeEvent(type: .leftMouseDown, modifiers: [.control])
        #expect(RightClickHitTest.shouldAcceptHit(for: ctrlLeftDown))
    }

    @Test func passesThroughMouseMoved() {
        let moved = makeEvent(type: .mouseMoved, modifiers: [])
        #expect(!RightClickHitTest.shouldAcceptHit(for: moved))
    }

    @Test func passesThroughNilEvent() {
        // SwiftUI may re-layout and trigger hit-tests when no AppKit event
        // is in flight (NSApp.currentEvent == nil); the overlay must not
        // claim hits in that case or it would block all subsequent input.
        #expect(!RightClickHitTest.shouldAcceptHit(for: nil))
    }

    @Test func takeControlCommandCallsThroughFromSurfaceMenuPath() {
        let view = SurfaceNSView()
        var calls = 0
        view.takeDisplayControlNotifier = {
            calls += 1
            return true
        }

        view.takeDisplayControlFromMenu(nil)

        #expect(calls == 1)
    }

    @Test("@spec LAYOUT-2.98: When right-click menus are nested, the application shall open the innermost menu under the pointer.")
    @MainActor func innermostNestedMenuWins() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let content = NSView(frame: root.bounds)
        let inner = RightClickMenuHostView(frame: NSRect(x: 10, y: 40, width: 20, height: 20))
        content.addSubview(inner)
        root.addSubview(content)
        let outer = RightClickMenuHostView(frame: root.bounds)
        root.addSubview(outer)
        #expect(RightClickMenuHostView.innermostHost(at: NSPoint(x: 15, y: 45), in: root) === inner)
        #expect(RightClickMenuHostView.innermostHost(at: NSPoint(x: 100, y: 45), in: root) === outer)
        inner.isHidden = true
        #expect(RightClickMenuHostView.innermostHost(at: NSPoint(x: 15, y: 45), in: root) === outer)
    }

    private func makeEvent(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
    }
}

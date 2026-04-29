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

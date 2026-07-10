import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import Graftty

/// Rationale for why the forwarding matters lives on the
/// `SurfaceNSView.flagsChanged` doc comment (KEY-1.4).
@MainActor
@Suite("""
@spec KEY-1.4: When a modifier key is pressed or released over a terminal pane (AppKit `flagsChanged`), the application shall forward the modifier transition to libghostty as a modifier-only key event, so link hover state refreshes and a cmd+click on an already-hovered file path opens the editor without requiring mouse movement.
""")
struct SurfaceFlagsChangedTests {

    // Virtual keycodes for modifier keys (HIToolbox/Events.h).
    private static let capsLock: UInt16 = 0x39
    private static let leftShift: UInt16 = 0x38
    private static let rightShift: UInt16 = 0x3C
    private static let leftControl: UInt16 = 0x3B
    private static let rightControl: UInt16 = 0x3E
    private static let leftOption: UInt16 = 0x3A
    private static let rightOption: UInt16 = 0x3D
    private static let leftCommand: UInt16 = 0x37
    private static let rightCommand: UInt16 = 0x36

    // Device-side modifier bits carried in NSEvent.modifierFlags.rawValue
    // (IOKit NX_DEVICE* masks).
    private static let deviceLeftCommand: UInt = 0x08
    private static let deviceRightCommand: UInt = 0x10

    @Test("left ⌘ down is a press")
    func leftCommandPress() {
        let action = SurfaceNSView.modifierKeyAction(
            keyCode: Self.leftCommand,
            modifierFlags: NSEvent.ModifierFlags(
                rawValue: NSEvent.ModifierFlags.command.rawValue | Self.deviceLeftCommand
            )
        )
        #expect(action == GHOSTTY_ACTION_PRESS)
    }

    @Test("⌘ up is a release")
    func commandRelease() {
        // On release, the .command bit is gone from modifierFlags.
        let action = SurfaceNSView.modifierKeyAction(
            keyCode: Self.leftCommand,
            modifierFlags: []
        )
        #expect(action == GHOSTTY_ACTION_RELEASE)
    }

    @Test("right ⌘ up while left ⌘ still held is a release")
    func rightCommandReleaseWithLeftHeld() {
        // .command is still set (left side held), but the right-side device
        // bit is clear — upstream Ghostty treats this as a release.
        let action = SurfaceNSView.modifierKeyAction(
            keyCode: Self.rightCommand,
            modifierFlags: NSEvent.ModifierFlags(
                rawValue: NSEvent.ModifierFlags.command.rawValue | Self.deviceLeftCommand
            )
        )
        #expect(action == GHOSTTY_ACTION_RELEASE)
    }

    @Test("right ⌘ down reports a press via its device-side bit")
    func rightCommandPress() {
        let action = SurfaceNSView.modifierKeyAction(
            keyCode: Self.rightCommand,
            modifierFlags: NSEvent.ModifierFlags(
                rawValue: NSEvent.ModifierFlags.command.rawValue | Self.deviceRightCommand
            )
        )
        #expect(action == GHOSTTY_ACTION_PRESS)
    }

    @Test("shift down is a press")
    func shiftPress() {
        let action = SurfaceNSView.modifierKeyAction(
            keyCode: Self.leftShift,
            modifierFlags: .shift
        )
        #expect(action == GHOSTTY_ACTION_PRESS)
    }

    @Test("caps lock toggle on/off maps to press/release")
    func capsLockToggle() {
        #expect(SurfaceNSView.modifierKeyAction(
            keyCode: Self.capsLock,
            modifierFlags: .capsLock
        ) == GHOSTTY_ACTION_PRESS)
        #expect(SurfaceNSView.modifierKeyAction(
            keyCode: Self.capsLock,
            modifierFlags: []
        ) == GHOSTTY_ACTION_RELEASE)
    }

    @Test("non-modifier keycode is ignored")
    func nonModifierKeycodeIgnored() {
        // 0x00 is the 'a' key; flagsChanged should never dispatch for it.
        #expect(SurfaceNSView.modifierKeyAction(
            keyCode: 0x00,
            modifierFlags: .command
        ) == nil)
    }
}

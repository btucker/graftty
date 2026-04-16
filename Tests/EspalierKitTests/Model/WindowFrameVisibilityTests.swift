import Testing
import Foundation
import CoreGraphics

/// Mirror of `WindowFrameTracker.Coordinator.frameIsVisibleOnAnyScreen` logic
/// extracted so we can test it without AppKit. Keep the minOverlap constant
/// in sync with the implementation.
///
/// Because the tracker lives in the app target (which embeds AppKit/SwiftUI)
/// and test targets can't depend on executable targets, this test duplicates
/// the algorithm against synthetic screen rects. If the implementation's
/// constant changes, update `minOverlap` below and the implementation together.
@Suite("WindowFrame visibility logic")
struct WindowFrameVisibilityTests {

    /// Keep in sync with `WindowFrameTracker.Coordinator.frameIsVisibleOnAnyScreen`.
    static let minOverlap: CGFloat = 40

    /// Returns true if `frame` overlaps at least one of `screens` by at least
    /// `minOverlap` in each dimension.
    static func frameIsVisible(_ frame: CGRect, on screens: [CGRect]) -> Bool {
        for screen in screens {
            let intersection = screen.intersection(frame)
            if intersection.width >= minOverlap && intersection.height >= minOverlap {
                return true
            }
        }
        return false
    }

    @Test func frameFullyOnScreenIsVisible() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(Self.frameIsVisible(frame, on: [screen]))
    }

    @Test func frameEntirelyOffScreenIsInvisible() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = CGRect(x: 5000, y: 5000, width: 800, height: 600)
        #expect(!Self.frameIsVisible(frame, on: [screen]))
    }

    @Test func frameOverlappingByExactThresholdIsVisible() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // Frame origin is outside the screen, but 40×40 corner overlaps.
        let frame = CGRect(x: 1920 - 40, y: 1080 - 40, width: 800, height: 600)
        #expect(Self.frameIsVisible(frame, on: [screen]))
    }

    @Test func frameOverlappingByLessThanThresholdIsInvisible() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // Only 39×39 overlap; below the 40pt threshold.
        let frame = CGRect(x: 1920 - 39, y: 1080 - 39, width: 800, height: 600)
        #expect(!Self.frameIsVisible(frame, on: [screen]))
    }

    @Test func frameOnSecondaryDisplayIsVisibleWhenAttached() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let secondary = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let frame = CGRect(x: 2000, y: 100, width: 800, height: 600)
        #expect(Self.frameIsVisible(frame, on: [primary, secondary]))
    }

    @Test func frameOnDisconnectedDisplayIsInvisible() {
        // Classic "I saved my window on the external monitor, then unplugged
        // it" scenario — the saved frame is outside the primary screen.
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = CGRect(x: 2500, y: 500, width: 800, height: 600)
        #expect(!Self.frameIsVisible(frame, on: [primary]))
    }

    @Test func framePartiallyVisibleButTooNarrowHorizontallyIsInvisible() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // Only 10px wide intersection (width < 40), though tall enough.
        let frame = CGRect(x: 1920 - 10, y: 100, width: 800, height: 600)
        #expect(!Self.frameIsVisible(frame, on: [screen]))
    }
}

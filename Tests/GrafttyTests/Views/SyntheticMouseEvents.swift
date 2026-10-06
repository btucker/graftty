import AppKit
import Testing

extension NSEvent {
    /// A single-click left-button press or release at `location` (window
    /// coordinates) addressed to `window`, as AppKit would deliver one.
    @MainActor
    static func syntheticClick(_ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }
}

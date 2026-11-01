import AppKit
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
struct TerminalDrawerHitAreaTests {
    @Test("@spec LAYOUT-2.180: When the user clicks empty space in the terminal drawer bar, the application shall toggle the drawer, while clicks on its individual controls shall perform only their own actions.")
    func barGapsToggleWithoutInterceptingControls() async throws {
        _ = NSApplication.shared
        var toggles = 0, creations = 0
        let host = NSHostingView(rootView: HStack {
            Button("Terminal") { toggles += 1 }.frame(width: 80)
            Spacer()
            Button("+") { creations += 1 }.frame(width: 40)
        }.buttonStyle(.plain).frame(width: 400, height: 40).background(.gray)
            .terminalDrawerHitArea { toggles += 1 })
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 400, height: 40),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        func click(_ x: Double) async throws {
            let point = host.convert(NSPoint(x: x, y: 20), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(60))
        }
        try await click(200)
        #expect(toggles == 1)
        try await click(380)
        #expect(creations == 1)
        #expect(toggles == 1)
        try await click(40)
        #expect(toggles == 2)
    }
}

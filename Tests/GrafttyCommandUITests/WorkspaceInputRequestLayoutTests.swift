#if os(macOS)
import AppKit
import SwiftUI
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct WorkspaceInputRequestLayoutTests {
    @Test("@spec TERM-12.68: When an agent input request appears, changes, or clears on Mac or mobile, the application shall present a single-line banner below the pane controls with the full question available on selection, without changing the terminal's size or covering its recovery controls.", arguments: [CGSize(width: 380, height: 400), CGSize(width: 220, height: 128)])
    func inputRequestDoesNotResizeTerminal(size: CGSize) async throws {
        _ = NSApplication.shared
        let state = RequestState()
        let terminal = NSView()
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: Fixture(state: state, terminal: terminal).frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark).environment(\.accessibilityEnabled, true))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(50))
        let original = terminal.frame
        try #require(original.height == size.height - 32)
        for question in ["Pick an approach?", String(repeating: "A longer question that wraps onto another line. ", count: 5), nil] {
            state.question = question
            try #require(state.context.question == question)
            try await Task.sleep(for: .milliseconds(50))
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(terminal.frame == original, "Changing the question must not resize the terminal")
            #expect(state.bannerHeight <= 44)
            #expect(state.bannerHeight < terminal.bounds.height)
            if question == "Pick an approach?", size.width == 380, let directory = ProcessInfo.processInfo.environment["GRAFTTY_TEST_SCREENSHOT_DIR"] {
                let url = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("question-overlay.png"))
            }
        }
        if size.width == 380 {
            state.question = "Pick an approach?"
            try await Task.sleep(for: .milliseconds(50))
            let point = terminal.convert(NSPoint(x: terminal.bounds.width - 50,
                y: terminal.isFlipped ? 16 : terminal.bounds.height - 16), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(state.selection == "asking", "The visible Go to question button must receive a native click")
            let fullQuestion = "Full question \(UUID()): " + String(repeating: "Read this entire request before choosing. ", count: 8)
            state.question = fullQuestion
            try await Task.sleep(for: .milliseconds(50))
            let questionPoint = terminal.convert(NSPoint(x: 100,
                y: terminal.isFlipped ? 16 : terminal.bounds.height - 16), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: questionPoint, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            func questionIsOpen() -> Bool {
                NSApp.windows.contains { $0 !== window && $0.isVisible && accessibilityContains(fullQuestion, in: $0) }
            }
            for _ in 0..<50 where !questionIsOpen() { try await Task.sleep(for: .milliseconds(20)) }
            #expect(questionIsOpen(),
                "Selecting a truncated banner must open the complete question")
            #expect(terminal.frame == original)
            state.question = nil
            for _ in 0..<50 where questionIsOpen() { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!questionIsOpen(), "Clearing a request must dismiss its question popover")
        }
    }

    private func accessibilityContains(_ label: String, in element: NSObject) -> Bool {
        for name in ["accessibilityLabel", "accessibilityValue"] {
            let selector = NSSelectorFromString(name)
            if element.responds(to: selector), element.perform(selector)?.takeUnretainedValue() as? String == label { return true }
        }
        let childrenSelector = NSSelectorFromString("accessibilityChildren")
        guard element.responds(to: childrenSelector),
              let children = element.perform(childrenSelector)?.takeUnretainedValue() as? [NSObject] else { return false }
        return children.contains { accessibilityContains(label, in: $0) }
    }

    private final class RequestState: ObservableObject {
        @Published var question: String?
        @Published var selection: String?
        @Published var bannerHeight: CGFloat = 0
        var context: SidebarWorktreeContext {
            return SidebarWorktreeContext(worktree: .init(path: "/task", displayName: "Task", repoDisplayName: "Project",
                displayBranch: "task", state: .running, isMainCheckout: false, prBadge: nil, stats: nil,
                attentionText: nil, layout: .leaf(sessionName: "asking", title: "Claude", attentionText: question,
                    isBusy: false, attentionSource: .agentStop)))
        }
    }

    private struct Fixture: View {
        @ObservedObject var state: RequestState
        let terminal: NSView
        var body: some View {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Text("Claude").frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).frame(height: 32).background(Color.white.opacity(0.08))
                }
                TerminalProbe(view: terminal)
                    .overlay(alignment: .bottomLeading) {
                        Text("QUESTION-PROBE\n\nWhich implementation should I use?\n\n❯ 1. First option\n  2. Second option\n  3. Third option\n\nEnter to select")
                            .font(.system(.body, design: .monospaced)).padding(16)
                    }
                    .overlay(alignment: .top) {
                        WorkspaceInputRequest(context: state.context, selectedSession: "selected", onSelect: { state.selection = $0 })
                    }
                    .onPreferenceChange(WorkspaceInputRequestHeightKey.self) { state.bannerHeight = $0 }
                    .clipped()
            }
            .foregroundStyle(.white).background(Color(red: 0.09, green: 0.1, blue: 0.12))
        }
    }

    private struct TerminalProbe: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}
#endif

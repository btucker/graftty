import AppKit
import GrafttyKit
import GrafttyProtocol
import Testing
@testable import Graftty

@MainActor
struct VoiceDictationPreviewTests {
    @Test("@spec KEY-4.10: While provisional dictation exceeds the terminal pane width, the application shall wrap its preview within the pane, reflow it on resize, and keep terminal keyboard focus.")
    func longPreviewWrapsAndReflows() throws {
        _ = NSApplication.shared
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try #require(SurfaceHandle(
            terminalID: PaneSlotID(id: UUID()), app: fakeApp(),
            worktreePath: "/tmp/voice-preview-test", socketPath: "/tmp/graftty.sock",
            surfaceFactory: harness.factory
        ))
        let view = try #require(handle.view as? SurfaceNSView)
        view.surfaceOperations = .init(setSize: { _, _, _ in }, size: { _ in .zero }, refresh: { _ in })
        view.surfaceOperations.setFocus = { _, _ in }
        view.surfaceOperations.imeRect = { _ in .zero }
        var preedits: [String] = []
        view.surfaceOperations.preedit = { _, text in preedits.append(text) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { view.surface = nil; window.close() }
        window.contentView = view
        window.makeFirstResponder(view)
        let target = VoiceDictationTarget(handle: handle)
        let text = String(repeating: "a prompt that should wrap across several lines ", count: 12)
        target.preview(text)
        #expect(preedits.isEmpty)
        let overlay = try #require(view.subviews.compactMap { $0 as? VoiceDictationPreview }.first)
        let scrollView = try #require(overlay.subviews.compactMap { $0 as? NSScrollView }.first)
        let textView = try #require(scrollView.documentView as? NSTextView)
        #expect(textView.string == text)
        let manager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        manager.ensureLayout(for: container)
        let originalHeight = manager.usedRect(for: container).height
        #expect(originalHeight > manager.defaultLineHeight(for: try #require(textView.font)))
        #expect(view.bounds.contains(overlay.frame))
        #expect(window.firstResponder === view)
        #expect(overlay.hitTest(.zero) == nil)
        expectLastWordVisible(in: textView)

        view.setFrameSize(NSSize(width: 220, height: 240))
        view.layoutSubtreeIfNeeded()
        manager.ensureLayout(for: container)
        #expect(manager.usedRect(for: container).height > originalHeight)
        #expect(view.bounds.contains(overlay.frame))
        #expect(window.firstResponder === view)
        expectLastWordVisible(in: textView)
        target.preview("")
        #expect(overlay.superview == nil)

        target.preview("new speech")
        let field = NSTextField(frame: .zero)
        view.addSubview(field)
        window.makeFirstResponder(field)
        #expect(view.subviews.compactMap { $0 as? VoiceDictationPreview }.isEmpty)
    }

    @Test("The wrapping caption stays off the cursor row at the top, middle, and bottom of the pane",
          arguments: [CGFloat(-50), CGFloat(10), CGFloat(100), CGFloat(210), CGFloat(300)])
    func captionAvoidsPromptRow(cursorY: CGFloat) {
        let pane = NSRect(x: 0, y: 0, width: 360, height: 240)
        let cursor = NSRect(x: 24, y: cursorY, width: 8, height: 18)
        let preview = VoiceDictationPreview(frame: .zero)
        preview.update(String(repeating: "long provisional speech ", count: 12),
                       in: pane, cursorRect: cursor)
        #expect(!preview.isHidden)
        #expect(pane.contains(preview.frame))
        #expect(!preview.frame.intersects(cursor))
    }

    @Test("A pane without room for one padded text line hides the caption")
    func shortPaneDoesNotClipLatestLine() {
        let preview = VoiceDictationPreview(frame: .zero)
        preview.update("the latest words must stay readable",
                       in: NSRect(x: 0, y: 0, width: 360, height: 100),
                       cursorRect: NSRect(x: 24, y: 40, width: 8, height: 18))
        #expect(preview.isHidden)
    }

    private func expectLastWordVisible(in textView: NSTextView) {
        guard let manager = textView.layoutManager, let container = textView.textContainer else {
            Issue.record("Preview has no text layout")
            return
        }
        let glyphs = manager.glyphRange(forCharacterRange:
            NSRange(location: textView.string.utf16.count - 2, length: 1), actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        #expect(textView.visibleRect.contains(rect))
    }
}

import AppKit
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

@MainActor
struct InMemoryTerminalSessionViewportTests {
    /// One line per viewport row is the contract callers index by. A single
    /// read over the whole viewport unwraps a soft-wrapped row into the line
    /// above it, shifting every row below.
    @Test
    func `viewport text keeps one line per row across a soft wrap`() {
        let harness = ViewportHarness()
        defer { harness.tearDown() }
        guard let size = harness.surface.size(), size.columns > 0, size.rows > 2 else {
            Issue.record("surface reports no grid")
            return
        }

        let columns = Int(size.columns)
        harness.receive(String(repeating: "x", count: columns + 5) + "\r\nmain.swift")

        guard let text = harness.session.readViewportRowsText() else {
            Issue.record("viewport read failed")
            return
        }
        let lines = text.components(separatedBy: "\n").map { line in
            String(line.reversed().drop(while: { $0 == " " }).reversed())
        }
        #expect(lines.count == Int(size.rows))
        #expect(lines[0] == String(repeating: "x", count: columns))
        #expect(lines[1] == "xxxxx")
        #expect(lines[2] == "main.swift")
    }

    @Test("Viewport flow joins soft wraps while preserving hard blank rows")
    func flowJoinsWrapsAndPreservesBlankRows() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let size = try #require(harness.surface?.size())
        let prefix = String(repeating: "a", count: Int(size.columns) + 5)
        harness.receive(prefix + "\r\n\r\nhttps://one.example/same\r\nhttps://two.example/same")
        let text = try #require(harness.session.readViewportText())
        #expect(text.hasPrefix(prefix + "\n\nhttps://one.example/same\nhttps://two.example/same"))
        let rows = try #require(harness.session.readViewportRowsText()).components(separatedBy: "\n")
        #expect(rows.count == Int(size.rows))
        #expect(rows[0] == String(repeating: "a", count: Int(size.columns)))
        #expect(rows[1] == "aaaaa")
        #expect(rows[2].isEmpty)
        #expect(rows[3] == "https://one.example/same")
        #expect(rows[4] == "https://two.example/same")
    }

    @Test("Viewport flow anchors preserve duplicate words after soft wraps and wide characters")
    func flowAnchorMatchesTheNativeCellOffset() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let size = try #require(harness.surface?.size())
        let prefix = String(repeating: "a", count: Int(size.columns) + 5)
        harness.receive(prefix + "\r\n\r\n你好 cat cat")
        let text = try #require(harness.session.readViewportText())
        // Two wide characters, a space, 'cat', then a space: column nine.
        let offset = UInt32(size.columns) * 3 + 9
        let range = harness.session.viewportTextAnchorRange(word: "cat", cellOffset: offset, in: text)
        #expect(range == NSRange(location: prefix.utf16.count + 2 + 7, length: 3))
        #expect(harness.session.viewportTextAnchorRange(word: "cat", cellOffset: offset, in: "stale") == nil)
        #expect(harness.session.viewportTextAnchorRange(word: "other", cellOffset: offset, in: text) == nil)
        #expect(harness.session.viewportTextAnchorRange(
            word: "cat", cellOffset: offset, in: text, expectedColumns: UInt32(size.columns) + 1
        ) == nil)
    }

    @Test("A single-row viewport supplies native columns and a valid flow anchor")
    func singleRowFlowAnchorUsesNativeColumns() async throws {
        let replies = TeardownValues<Data>()
        let harness = ViewportHarness(write: { replies.append($0) })
        defer { harness.tearDown() }
        let size = try #require(harness.surface.size())
        harness.coordinator.viewSize = { (Double(size.widthPixels), Double(size.cellHeightPixels)) }
        harness.coordinator.fitToSize()
        let resized = try #require(harness.surface.size())
        try #require(resized.rows == 1)
        let bottomRight = "\u{1b}[1;\(resized.columns)R"
        for _ in 0..<100 where !replies.values.contains(where: { String(decoding: $0, as: UTF8.self).contains(bottomRight) }) {
            harness.session.receive("\u{1b}[999;999H\u{1b}[6n")
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(replies.values.contains(where: { String(decoding: $0, as: UTF8.self).contains(bottomRight) }))
        harness.receive("\u{1b}[H\u{1b}[2Jcat cat")
        let text = try #require(harness.session.readViewportText())
        #expect(harness.session.nativeViewportColumns() == UInt32(resized.columns))
        #expect(harness.session.viewportTextAnchorRange(word: "cat", cellOffset: 4, in: text) == NSRange(location: 4, length: 3))
    }

    /// Every title, pwd and command mark parsed goes into ghostty's 64-slot
    /// app mailbox, drained only by a main-thread tick. A main-thread caller
    /// that waits for parsing must keep ticking, or the 65th message parks
    /// the parser and the caller forever.
    @Test(.timeLimit(.minutes(1)))
    func `waitForPendingOutput on the main thread drains a mailbox-filling replay`() {
        let harness = ViewportHarness()
        defer { harness.tearDown() }

        let titles = (0 ..< 100).map { "\u{1B}]2;title \($0)\u{07}" }.joined()
        harness.session.receive(titles + "done")
        harness.session.waitForPendingOutput()

        let firstLine = harness.session.readViewportRowsText()?
            .components(separatedBy: "\n").first ?? ""
        #expect(firstLine.hasPrefix("done"))
    }

    /// `readViewportText()` MUST return `nil` (not crash) when no surface is
    /// attached. This is the canonical pre-surface / post-surface-teardown
    /// state — consumers may call `readViewportText` from any thread that
    /// holds a reference, and the contract is "nil means no surface."
    @Test
    func `read viewport text returns nil before surface attached`() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        #expect(session.readViewportText() == nil)
    }

    /// After clearing the surface, the read MUST go back to returning `nil`.
    /// Together with the test above this pins the surface-presence semantics
    /// of the public API.
    @Test
    func `read viewport text returns nil after surface cleared`() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        session.clearSurface(ifMatches: nil)
        #expect(session.readViewportText() == nil)
    }
}

/// An in-memory session behind a real macOS surface, so reads and waits go
/// through libghostty rather than a stand-in pointer.
@MainActor
private final class ViewportHarness {
    let session: InMemoryTerminalSession
    let coordinator = TerminalSurfaceCoordinator()
    private let platformView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))

    init(write: @escaping @Sendable (Data) -> Void = { _ in }) {
        session = InMemoryTerminalSession(write: write, resize: { _ in })
        platformView.wantsLayer = true
        coordinator.isAttached = { true }
        coordinator.scaleFactor = { 1 }
        coordinator.viewSize = { (800, 500) }
        coordinator.platformSetup = { [platformView] config in
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(
                macos: ghostty_platform_macos_s(
                    nsview: Unmanaged.passUnretained(platformView).toOpaque(),
                ),
            )
        }
        coordinator.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        coordinator.controller = TerminalController()
        precondition(coordinator.surface != nil, "surface must build for the harness")
    }

    var surface: TerminalSurface {
        coordinator.surface!
    }

    func tearDown() {
        coordinator.freeSurface()
    }

    func receive(_ text: String) {
        session.receive(Data(text.utf8))
        session.waitForPendingOutput()
    }
}

import Foundation
import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI
#if os(macOS)
import AppKit
#endif

@Suite("@spec CONTEXT-26: When Context history shows a peer message, the application shall show text that fits one line verbatim without running a model, otherwise show an on-device Apple Intelligence summary marked as generated when available, and otherwise show the truncated first sentence or line unmarked, generating each text at most once per process.")
struct PeerMessageGistTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        func record(_ text: String) { lock.withLock { texts.append(text) } }
        var all: [String] { lock.withLock { texts } }
    }

    private let long = "I checked the layout on both platforms. The sidebar width clamps correctly, and the history timeline now folds as expected."

    @Test func shortSingleLineTextIsVerbatimWithoutModel() async {
        let calls = Calls()
        let provider = PeerMessageGistProvider { calls.record($0); return "Summary" }
        let short = String(repeating: "x", count: 80)
        #expect(await provider.gist(for: short) == PeerMessageGist(text: short, isGenerated: false))
        #expect(await provider.gist(for: "  Done.  ") == PeerMessageGist(text: "Done.", isGenerated: false))
        #expect(calls.all.isEmpty)
    }

    @Test func longOrMultilineTextUsesGeneratedSummary() async {
        let provider = PeerMessageGistProvider { _ in "  Layout verified on both platforms.\nExtra line" }
        #expect(await provider.gist(for: long) == PeerMessageGist(text: "Layout verified on both platforms.", isGenerated: true))
        #expect(await provider.gist(for: "Line one\nLine two").isGenerated)
    }

    @Test func unavailableOrFailingModelFallsBackWithoutSparkle() async {
        struct Failure: Error {}
        for provider in [PeerMessageGistProvider { _ in nil }, PeerMessageGistProvider { _ in throw Failure() },
                         PeerMessageGistProvider { _ in "   " }] {
            #expect(await provider.gist(for: long) == PeerMessageGist(text: "I checked the layout on both platforms.", isGenerated: false))
            #expect(await provider.gist(for: "\nFirst line\nSecond line") == PeerMessageGist(text: "First line", isGenerated: false))
            let run = String(repeating: "word ", count: 40)
            let gist = await provider.gist(for: run)
            #expect(!gist.isGenerated)
            #expect(gist.text.count <= 80)
            #expect(gist.text.hasSuffix("…"))
        }
    }

    @Test func leadingListMarkerIsNotTheFirstSentence() {
        #expect(PeerMessageGist.immediate("1. Fixed the sidebar width.\n2. Checked the timeline.")
            == PeerMessageGist(text: "1. Fixed the sidebar width.", isGenerated: false))
    }

    @Test func unavailableModelIsAskedAgainLater() async {
        let calls = Calls()
        let provider = PeerMessageGistProvider { text in
            calls.record(text)
            return calls.all.count == 1 ? nil : "Gist"
        }
        #expect(await provider.gist(for: long) == PeerMessageGist.immediate(long))
        #expect(await provider.gist(for: long) == PeerMessageGist(text: "Gist", isGenerated: true))
        _ = await provider.gist(for: long)
        #expect(calls.all == [long, long], "A model that was not ready must not pin the fallback, but a generated gist is kept")
    }

    @Test func eachTextGeneratesAtMostOnce() async {
        let calls = Calls()
        let provider = PeerMessageGistProvider { text in
            calls.record(text)
            try await Task.sleep(for: .milliseconds(20))
            return "Gist"
        }
        await withTaskGroup(of: PeerMessageGist.self) { group in
            for _ in 0..<5 { group.addTask { await provider.gist(for: long) } }
            for await gist in group { #expect(gist.isGenerated) }
        }
        _ = await provider.gist(for: long)
        #expect(calls.all == [long])
    }

    #if os(macOS)
    @MainActor @Test func onlyGeneratedGistsCarryTheSparkle() async throws {
        let gist = "Checked the layout."
        func render(_ message: String, _ gists: PeerMessageGistProvider) async throws -> Data {
            var history = WorktreeHistory()
            history.record(.init(text: "<graftty-peer-message agent=\"/repo/layout#claude\">\(message)</graftty-peer-message>", at: Date(timeIntervalSince1970: 0)))
            let host = NSHostingView(rootView: WorktreeHistoryContent(timeline: .init(history: history, brief: nil), secondary: .secondary, gists: gists)
                .padding(20).frame(width: 320).fixedSize(horizontal: false, vertical: true))
            let window = NSWindow(contentRect: .init(origin: NSPoint(x: -10000, y: -10000), size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        let verbatim = try await render(gist, PeerMessageGistProvider { _ in nil })
        let fallback = try await render(gist + " " + long, PeerMessageGistProvider { _ in nil })
        // Its fallback equals the verbatim render, so only the generated gist's sparkle can differ.
        let generated = try await render(gist + " " + long, PeerMessageGistProvider { _ in gist })
        #expect(fallback == verbatim, "A fallback gist must render exactly like verbatim text")
        #expect(generated != verbatim, "A generated gist must carry the sparkle")
    }
    #endif

    @Test func cacheIsBounded() async {
        let calls = Calls()
        let provider = PeerMessageGistProvider(limit: 2) { calls.record($0); return "Gist" }
        let texts = (0..<3).map { "Message \($0)\nwith a second line" }
        for text in texts { _ = await provider.gist(for: text) }
        _ = await provider.gist(for: texts[2])
        _ = await provider.gist(for: texts[0])
        #expect(calls.all == texts + [texts[0]])
    }
}

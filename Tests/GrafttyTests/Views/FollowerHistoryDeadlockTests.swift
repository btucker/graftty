import AppKit
import GhosttyKit
import GrafttyProtocol
import Testing
import XCTest
@testable import Graftty

#if GRAFTTY_PAGED_HISTORY
struct FollowerHistoryDeadlockTests {
    @Test("@spec OWN-2.12: When a Mac follower replays history that fills the native app mailbox, the application shall keep main-thread mailbox processing available, render the latest history in order, and finish surface replacement and teardown safely.")
    func historyReplayMakesMailboxProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("child.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "GrafttyTests.FollowerHistoryDeadlockChild/testHistoryReplay",
                           Bundle(for: FollowerHistoryDeadlockChild.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["GRAFTTY_HISTORY_DEADLOCK_RESULT"] = directory.appendingPathComponent("completed").path
        child.environment = environment
        child.standardOutput = output
        child.standardError = output
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        let deadline = ContinuousClock.now + .seconds(20)
        while child.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            Issue.record("History replay blocked the isolated native probe for 20 seconds")
            return
        }
        let diagnostics = try String(contentsOf: log, encoding: .utf8)
        #expect(child.terminationReason == .exit && child.terminationStatus == 0,
                "Native probe failed: \(diagnostics)")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("completed").path))
    }
}

@MainActor
final class FollowerHistoryDeadlockChild: XCTestCase {
    func testHistoryReplay() async throws {
        guard let result = ProcessInfo.processInfo.environment["GRAFTTY_HISTORY_DEADLOCK_RESULT"] else {
            throw XCTSkip("Isolated native mailbox probe")
        }
        _ = NSApplication.shared
        XCTAssertEqual(ghosttyInitWithoutArguments(), 0)
        let app = GhosttyApp(config: GhosttyConfig()) { _, _ in true }
        let observer = GhosttyWakeupBridge.observe { app.tick() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1000, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let terminal = SurfaceNSView(frame: window.contentRect(forFrameRect: window.frame))
        func createSurface(_ view: NSView) -> ghostty_surface_t? {
            var config = ghostty_surface_config_new()
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
            config.scale_factor = window.backingScaleFactor
            config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
            config.receive_buffer = { _, _, _ in }
            config.receive_resize = { _, _, _, _, _ in }
            return ghostty_surface_new(app.app, &config)
        }
        let noiseView = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        noiseView.wantsLayer = true
        let noiseSurface = try XCTUnwrap(createSurface(noiseView))
        let noise = MacPagedSurface(noiseSurface)
        let noiseFinished = DispatchSemaphore(value: 0)
        let source = try XCTUnwrap(createSurface(terminal))
        terminal.surface = source
        let follower = MacFollowerTerminalView(terminalView: terminal, metrics: { ghostty_surface_size(source) },
                                               makeHistorySurface: { view, _ in createSurface(view) })
        window.contentView = follower
        window.orderBack(nil)
        defer {
            follower.followerGrid = nil
            follower.layout()
            window.contentView = nil
            window.close()
            terminal.surface = nil
            ghostty_surface_free(source)
            noise.close()
            ghostty_surface_free(noiseSurface)
            withExtendedLifetime(noiseView) {}
            withExtendedLifetime(app) {}
        }
        follower.followerGrid = try DisplayGrid(cols: 80, rows: 24)
        follower.layout()
        for _ in 0..<100 where !ghostty_surface_grid_matches(source, 80, 24) {
            app.tick()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(ghostty_surface_grid_matches(source, 80, 24))
        write(Data("\u{1b}]10;rgb:12/34/56\u{1b}\\\u{1b}]11;rgb:ab/cd/ef\u{1b}\\".utf8), to: source)
        app.tick()
        write(Data((0..<100).map { "history-\($0)\r\n" }.joined().utf8), to: source)
        // Wait for the first history frame before adding mailbox pressure.
        for _ in 0..<100 {
            app.tick()
            follower.updateScrollbar(.init(total: 101, offset: 77, len: 24))
            follower.layout()
            if let surface = follower.historySurfaceForTesting, viewportText(surface).contains("history-76") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(follower.historySurfaceForTesting.map { viewportText($0).contains("history-76") } == true)
        write(Data("\u{1b}]10;rgb:65/43/21\u{1b}\\\u{1b}]11;rgb:fe/dc/ba\u{1b}\\".utf8), to: source)
        app.tick()
        // A separate native parser fills the shared 64-slot app mailbox.
        // Keep it separate from source so read_history can acquire its mutex.
        DispatchQueue.global().async {
            noise.write(Data((0..<256).map { "\u{1b}]2;mailbox-\($0)\u{7}" }.joined().utf8))
            noiseFinished.signal()
        }
        XCTAssertEqual(noiseFinished.wait(timeout: .now() + 0.2), .timedOut,
                       "Title parsing must still be waiting for main to drain the mailbox")
        // read_history emits the source's dynamic OSC 10/11 defaults. The
        // first replay must return to main even while that mailbox is full.
        for row in 100..<300 {
            write(Data("history-\(row)\r\n".utf8), to: source)
            follower.updateScrollbar(.init(total: UInt64(row + 1), offset: UInt64(row - 23), len: 24))
            follower.layout()
        }
        for _ in 0..<200 {
            app.tick()
            follower.layout()
            if let history = follower.historySurfaceForTesting, viewportText(history).contains("history-276") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(noiseFinished.wait(timeout: .now() + 1), .success)
        let history = try XCTUnwrap(follower.historySurfaceForTesting)
        let text = viewportText(history)
        XCTAssertTrue(text.contains("history-276"), text)
        XCTAssertFalse(text.contains("history-299"), text)
        let penultimate = try XCTUnwrap(text.range(of: "history-275"))
        let last = try XCTUnwrap(text.range(of: "history-276"))
        XCTAssertLessThan(penultimate.lowerBound, last.lowerBound)
        // Retire a surface immediately after requesting another repaint.
        write(Data("replacement\r\n".utf8), to: source)
        follower.updateScrollbar(.init(total: 302, offset: 278, len: 24))
        follower.layout()
        follower.followerGrid = nil
        follower.layout()
        XCTAssertNil(follower.historySurfaceForTesting)
        follower.followerGrid = try DisplayGrid(cols: 80, rows: 24)
        follower.layout()
        for _ in 0..<100 {
            app.tick()
            follower.layout()
            if let surface = follower.historySurfaceForTesting, viewportText(surface).contains("history-277") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(follower.historySurfaceForTesting.map { viewportText($0).contains("history-277") } == true)
        // A single history write can itself exceed the mailbox capacity.
        // close must join that C call while processing messages, then reject
        // the completion that is still queued on main. A plain join hangs.
        let retirementView = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        retirementView.wantsLayer = true
        let retirementSurface = try XCTUnwrap(createSurface(retirementView))
        let writer = FollowerHistoryWriter(surface: retirementSurface)
        let colors = (0..<256).map { "\u{1b}]10;rgb:\(String(format: "%02x", $0))/34/56\u{7}" }.joined()
        writer.repaint(Data(colors.utf8)) { XCTFail("A retired repaint must not publish its completion") }
        writer.close()
        writer.close()
        withExtendedLifetime(retirementView) {}
        try await Task.sleep(for: .milliseconds(30))
        withExtendedLifetime(writer) {}
        try Data("completed".utf8).write(to: URL(fileURLWithPath: result))
    }

    private func write(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { bytes in
            ghostty_surface_write_buffer(surface, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt(bytes.count))
        }
    }

    private func viewportText(_ surface: ghostty_surface_t) -> String {
        let selection = ghostty_selection_s(
            top_left: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0), rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text else { return "" }
        return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self),
                                                   count: Int(text.text_len)), as: UTF8.self)
    }
}
#endif

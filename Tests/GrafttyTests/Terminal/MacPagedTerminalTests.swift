import AppKit
import Foundation
import GhosttyKit
@testable import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import Testing
@testable import Graftty

@MainActor
@Suite(.serialized)
struct MacPagedTerminalTests {
    @Test("@spec TERM-12.36: When a detached local Mac pane is mounted again, the application shall retain every history line, including history shorter than one viewport, through native paging or legacy replay.", .timeLimit(.minutes(1)), arguments: MacPagedTerminalRenderer.isSupported ? [false, true] : [true], [40, 10000])
    func mountedPaneRestoresDetachedHistory(legacy: Bool, lineCount: Int) async throws {
        let fixture = try await HistoryDaemon.make(lineCount: lineCount, redrawPrompt: legacy)
        defer { fixture.close() }
        _ = NSApplication.shared
        #expect(ghostty_init(0, nil) == 0)
        weak var mountedView: MacFollowerTerminalView?
        let app = GhosttyApp(config: GhosttyConfig()) { _, action in
            if action.tag == GHOSTTY_ACTION_SCROLLBAR {
                DispatchQueue.main.async { mountedView?.updateScrollbar(action.action.scrollbar) }
            }
            return true
        }
        var surfaceFactory = SurfaceHandleGhosttySurfaceFactory.live
        surfaceFactory.free = { surface in
            ghostty_surface_free(surface)
            withExtendedLifetime(app) {}
        }
        let handle = try #require(SurfaceHandle(
            terminalID: PaneSlotID(), app: app.app, worktreePath: fixture.launcher.zmxDir.path,
            socketPath: "/tmp/graftty-history-test.sock", zmxSpawnConfiguration: .init(
                sessionName: "history", argv: legacy ? [fixture.launcher.executable.path, "attach", "history"] : ["/nonexistent-graftty-legacy-attach"],
                env: fixture.launcher.subprocessEnv(from: ProcessInfo.processInfo.environment),
                workingDirectory: fixture.launcher.zmxDir, shellReadySignalAvailable: false
            ),
            surfaceFactory: surfaceFactory,
            zmxBackendFactory: { spawn, size, _, _ in
                HostManagedZmxBackend(spawnConfiguration: spawn, initialSize: size,
                    sessionFactory: { surface, configuration, initialSize in
                        if legacy {
                            return NativePtySession(surface: surface, argv: configuration.argv,
                                env: configuration.env, workingDirectory: configuration.workingDirectory,
                                initialSize: initialSize, spawnFailed: { _ in })
                        }
                        return MacPagedZmxSession(surface: surface, configuration: configuration, initialSize: initialSize)
                    })
            }
        ))
        let terminal = try #require(handle.view as? SurfaceNSView)
        let view = MacFollowerTerminalView(terminalView: terminal, metrics: { [weak handle] in
            handle?.queryGridSize() ?? ghostty_surface_size_s()
        })
        handle.followerPresentation = view
        mountedView = view
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        defer {
            handle.disconnectAttachment()
            window.orderOut(nil)
            window.contentView = nil
            withExtendedLifetime(app) {}
        }
        var restoredText = ""
        for expected in [String(format: "history-row-%06d", lineCount - 1), "live-after"] {
            if expected == "live-after" { #expect(handle.writeText("after\n")) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            repeat {
                view.layout()
                app.tick()
                var text = ghostty_text_s()
                let selection = ghostty_selection_s(
                    top_left: .init(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                    bottom_right: .init(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
                    rectangle: false)
                if ghostty_surface_read_text(handle.surface, selection, &text) {
                    restoredText = text.text.map { String(decoding: Data(bytes: $0, count: Int(text.text_len)), as: UTF8.self) } ?? ""
                    ghostty_surface_free_text(handle.surface, &text)
                }
                if restoredText.contains(expected),
                   !legacy || restoredText.contains("history-prompt> "),
                   handle.presentationGrid == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            #expect(restoredText.contains(expected))
            if legacy { #expect(restoredText.contains("history-prompt> ")) }
        }
        let rows = Set(restoredText.split(whereSeparator: \.isNewline).map(String.init))
        let missingRows = (0..<lineCount).filter { !rows.contains(String(format: "history-row-%06d", $0)) }
        #expect(missingRows.isEmpty, "Missing restored rows: \(missingRows.prefix(30))")
        #expect(handle.presentationGrid == nil)
    }

    #if GRAFTTY_PAGED_HISTORY
    @Test("@spec TERM-12.28: When an unloaded local Mac pane attaches to a paging-capable daemon, the default host-managed backend shall use native screen restoration and background history import without replaying history as terminal output.", .timeLimit(.minutes(1)))
    func defaultLocalBackendUsesPaging() async throws {
        let fixture = try await HistoryDaemon.make()
        defer { fixture.close() }
        let terminal = try NativeCanvas()
        defer { terminal.close() }
        let backend = HostManagedZmxBackend(spawnConfiguration: .init(
            // The paged path connects to the existing socket. Make a legacy
            // spawn impossible so replay cannot accidentally satisfy this test.
            sessionName: "history", argv: ["/nonexistent-graftty-legacy-attach"],
            env: fixture.launcher.subprocessEnv(from: ProcessInfo.processInfo.environment),
            workingDirectory: fixture.launcher.zmxDir, shellReadySignalAvailable: false
        ), initialSize: .init(cols: 80, rows: 24))
        defer { backend.close(); backend.releaseReceiveUserdataAfterSurfaceFree() }
        var checkpointGrid: DisplayGrid?
        var completed = false
        backend.bindAttachmentGrid { grid in
            if let grid { checkpointGrid = grid; terminal.prepareGrid(grid) }
            else { completed = true }
        }
        backend.markLayoutSettled()
        try backend.start(surface: terminal.raw)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while checkpointGrid == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try backend.write(Data("probe\r".utf8))
        while !completed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        while !terminal.text().contains("live-probe"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(checkpointGrid == (try DisplayGrid(cols: 80, rows: 24)))
        #expect(completed)
        #expect(terminal.text().contains("history-row-009999"))
        #expect(terminal.text().contains("live-probe"))
        #expect(terminal.firstHistoryRow().contains("history-row-000000"))
    }

    @Test("@spec TERM-12.1: When Graftty on Mac or mobile opens a terminal through a paging-capable attachment, the application shall restore the current screen and parser state with a bounded recent-history allowance before fetching older history, without serializing or transferring the complete retained history on the initial path.", .timeLimit(.minutes(1)))
    func nativeScreenAppearsBeforeHistoryAndDoesNotPageThroughIt() async throws {
        let fixture = try await HistoryDaemon.make()
        defer { fixture.close() }
        let stream = PagedZmxAttachEngine(config: .init(zmxExecutable: fixture.launcher.executable,
            zmxDir: fixture.launcher.zmxDir, sessionName: "history"))
        try await stream.start()
        defer { stream.close() }
        var events = stream.events.makeAsyncIterator()
        guard case .checkpoint(let checkpoint) = try #require(await events.next()) else {
            Issue.record("Expected a current-screen checkpoint"); return
        }
        #expect(checkpoint.ready.count < 128 * 1024)
        #expect(checkpoint.hasPrimaryHistory)

        let terminal = try NativeCanvas()
        defer { terminal.close() }
        let renderer = MacPagedTerminalRenderer(surface: terminal.access, prepareGrid: terminal.prepareGrid)
        try await renderer.install(checkpoint, generation: 1)
        let visible = terminal.text()
        #expect(visible.contains("history-row-009999"))
        #expect(!visible.contains("history-row-000000"))
        #expect(!terminal.firstHistoryRow().contains("history-row-000000"))

        var ordinal: UInt64 = 0
        var imported = 0
        while true {
            try await stream.requestHistory(.init(incarnation: checkpoint.incarnation, checkpointID: checkpoint.id,
                requestID: ordinal + 1, ordinal: ordinal, screen: 0))
            guard case .page(let page) = try #require(await events.next()) else {
                Issue.record("Expected the requested history page"); return
            }
            #expect(page.data.count <= PagedTerminalLimits.pageBytes)
            if !page.data.isEmpty {
                #expect(await renderer.appendHistory(page.data, screen: 0, generation: 1) == .applied)
                imported += 1
            }
            #expect(terminal.text() == visible, "Loading older history moved the visible screen")
            if page.complete { break }
            ordinal += 1
            try #require(ordinal < 200)
        }
        #expect(imported > 1)
        #expect(terminal.firstHistoryRow().contains("history-row-000000"))
        // Reflow to the actual pane width only after the imported range is whole.
        terminal.prepareGrid(try DisplayGrid(cols: 120, rows: 40))
        for _ in 0..<100 where !ghostty_surface_grid_matches(terminal.raw, 120, 40) {
            terminal.app.tick()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(terminal.text().contains("history-row-009999"))
        #expect(terminal.firstHistoryRow().contains("history-row-000000"))
    }

    @MainActor
    private final class NativeCanvas {
        let app: GhosttyApp
        let window: NSWindow
        let view: NSView
        let raw: ghostty_surface_t
        let access: MacPagedSurface
        private var ticker: Task<Void, Never>?

        init() throws {
            _ = NSApplication.shared
            #expect(ghostty_init(0, nil) == 0)
            app = GhosttyApp(config: GhosttyConfig()) { _, _ in true }
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.borderless], backing: .buffered, defer: false)
            view = NSView(frame: window.contentView!.bounds)
            window.contentView = view
            var config = ghostty_surface_config_new()
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
            config.scale_factor = Double(window.backingScaleFactor)
            config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
            config.receive_buffer = { _, _, _ in }
            config.receive_resize = { _, _, _, _, _ in }
            raw = try #require(ghostty_surface_new(app.app, &config))
            access = MacPagedSurface(raw)
            window.orderBack(nil)
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    self?.app.tick()
                    do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                }
            }
        }

        func prepareGrid(_ grid: DisplayGrid?) {
            guard let grid else { return }
            let size = ghostty_surface_size(raw)
            let width = Int(size.width_px) + (Int(grid.cols) - Int(size.columns)) * Int(size.cell_width_px)
            let height = Int(size.height_px) + (Int(grid.rows) - Int(size.rows)) * Int(size.cell_height_px)
            ghostty_surface_set_size(raw, UInt32(clamping: width), UInt32(clamping: height))
        }

        func text() -> String {
            var text = ghostty_text_s()
            let selection = ghostty_selection_s(
                top_left: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                bottom_right: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0), rectangle: false)
            guard ghostty_surface_read_text(raw, selection, &text) else { return "" }
            defer { ghostty_surface_free_text(raw, &text) }
            return text.text.map { String(decoding: Data(bytes: $0, count: Int(text.text_len)), as: UTF8.self) } ?? ""
        }

        func firstHistoryRow() -> String {
            var text = ghostty_text_s()
            guard ghostty_surface_read_history(raw, 1, 1, &text) else { return "" }
            defer { ghostty_surface_free_text(raw, &text) }
            return text.text.map { String(decoding: Data(bytes: $0, count: Int(text.text_len)), as: UTF8.self) } ?? ""
        }

        func close() {
            ticker?.cancel()
            access.close()
            window.orderOut(nil)
            ghostty_surface_free(raw)
            withExtendedLifetime(app) {}
        }
    }

    #endif

    private final class HistoryDaemon: @unchecked Sendable {
        let launcher: ZmxLauncher
        let seed: NativePtySession
        private let output: HistoryOutput

        private init(lineCount: Int, redrawPrompt: Bool) throws {
            output = HistoryOutput(marker: redrawPrompt ? "history-prompt> " : String(format: "history-row-%06d", lineCount - 1))
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let dir = URL(fileURLWithPath: "/private/tmp/mac-paging-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            launcher = ZmxLauncher(executable: root.appendingPathComponent("Resources/zmx-binary/zmx"), zmxDir: dir)
            // Keep the shell alive after producing the fixture; the client reader
            // drains the PTY so this setup cannot block on its output buffer.
            let output = output
            let prompt = redrawPrompt ? "printf '\\033]133;A;redraw=1\\007history-prompt> \\033]133;B\\007'; " : ""
            seed = NativePtySession(argv: [launcher.executable.path, "attach", "history", "/bin/sh", "-c",
                "i=0; while [ $i -lt \(lineCount) ]; do printf 'history-row-%06d\\n' $i; i=$((i+1)); done; \(prompt)while read value; do printf 'live-%s\\n' \"$value\"; done"],
                env: launcher.subprocessEnv(from: ProcessInfo.processInfo.environment),
                workingDirectory: dir, initialSize: .init(cols: 80, rows: 24),
                writeToSurface: { output.append($0) }, processExited: { _, _ in }, spawnFailed: { _ in })
        }

        static func make(lineCount: Int = 10000, redrawPrompt: Bool = false) async throws -> HistoryDaemon {
            let fixture = try HistoryDaemon(lineCount: lineCount, redrawPrompt: redrawPrompt)
            do {
                try fixture.seed.start()
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !fixture.output.finished {
                    guard ContinuousClock.now < deadline else { throw MacPagedTerminalRenderer.Error.gridUnavailable }
                    try await Task.sleep(for: .milliseconds(10))
                }
                fixture.seed.close()
                return fixture
            } catch { fixture.close(); throw error }
        }

        func close() {
            seed.close()
            launcher.kill(sessionName: "history")
            try? FileManager.default.removeItem(at: launcher.zmxDir)
        }
    }

    private final class HistoryOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private let marker: String
        init(marker: String) { self.marker = marker }
        func append(_ data: Data) { lock.withLock { bytes.append(data) } }
        var finished: Bool {
            lock.withLock { String(decoding: bytes, as: UTF8.self).contains(marker) }
        }
    }
}

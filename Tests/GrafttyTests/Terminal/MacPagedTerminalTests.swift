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
    @Test("@spec TERM-12.50: When a Mac terminal receives a live source-grid acknowledgment, the application shall update its parser grid without refitting the owner viewport or entering checkpoint-restore presentation.")
    func liveGridDoesNotRefitOwnerViewport() async throws {
        let terminal = try NativeCanvas()
        defer { terminal.close() }
        var preparations: [DisplayGrid?] = []
        let renderer = MacPagedTerminalRenderer(surface: terminal.access, prepareGrid: {
            preparations.append($0)
            terminal.prepareGrid($0)
        })
        let coordinator = PagedTerminalCoordinator(renderer: renderer, send: { _ in })
        let before = ghostty_surface_size(terminal.raw)
        let source = try DisplayGrid(cols: before.columns, rows: max(1, before.rows / 2))
        let applied = try await coordinator.handle(.grid(cols: source.cols, rows: source.rows))
        #expect(applied == source)
        #expect(preparations.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        let after = ghostty_surface_size(terminal.raw)
        #expect(after.width_px == before.width_px)
        #expect(after.height_px == before.height_px)
        #expect(ghostty_surface_grid_matches(terminal.raw, source.cols, source.rows))
        // Initial restoration still has to fit the checkpoint's physical grid.
        try await renderer.resize(cols: source.cols, rows: source.rows)
        #expect(preparations == [source])
    }

    @Test("@spec DIST-1.8: When the Mac terminal tests run with the committed dependency, the renderer shall support paging so native checkpoint and history tests execute.")
    func publishedDependencySupportsPaging() {
        #expect(MacPagedTerminalRenderer.isSupported)
    }

    @Test("@spec TERM-12.36: When a detached local Mac pane is mounted again, the application shall retain every history line, including history shorter than one viewport, through native paging or legacy replay.", .timeLimit(.minutes(1)), arguments: MacPagedTerminalRenderer.isSupported ? [false, true] : [true], [40, 10000])
    func mountedPaneRestoresDetachedHistory(legacy: Bool, lineCount: Int) async throws {
        try await restoreDetachedHistory(legacy: legacy, lineCount: lineCount)
    }

    @Test("@spec TERM-12.47: While a session's scrollback fits within libghostty's default 50,000,000-byte page budget, the zmx daemon shall retain every row, so a Mac pane reattaching to a 20,000-line session restores every line instead of only the newest 10,000,000 bytes of pages.", .timeLimit(.minutes(2)), .enabled(if: MacPagedTerminalRenderer.isSupported))
    func daemonRetainsLibghosttyDefaultScrollbackBudget() async throws {
        try await restoreDetachedHistory(legacy: false, lineCount: 20000)
    }

    private func restoreDetachedHistory(legacy: Bool, lineCount: Int) async throws {
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
        #expect(missingRows.isEmpty, "Missing \(missingRows.count) restored rows: \(missingRows.prefix(30))")
        #expect(handle.presentationGrid == nil)
    }

    #if GRAFTTY_PAGED_HISTORY
    @Test("@spec TERM-12.43: When retained history contains dense wide-character rows, the application shall transfer contiguous bounded pages on Mac and mobile without reporting a memory limit solely because a native page exceeds the transport budget, preserve identical retries, and continue scrolling and live output across checkpoint recovery.", .timeLimit(.minutes(1)))
    func denseWideHistoryPagesStayBoundedAndRecover() async throws {
        let lineCount = 2000
        let fixture = try await HistoryDaemon.make(lineCount: lineCount, wide: true)
        defer { fixture.close() }
        let stream = PagedZmxAttachEngine(config: .init(zmxExecutable: fixture.launcher.executable,
            zmxDir: fixture.launcher.zmxDir, sessionName: "history"))
        try await stream.start()
        defer { stream.close() }
        var events = stream.events.makeAsyncIterator()
        let terminal = try NativeCanvas()
        defer { terminal.close() }
        let renderer = MacPagedTerminalRenderer(surface: terminal.access, prepareGrid: terminal.prepareGrid)
        for generation in UInt64(1)...2 {
            if generation > 1 { try await stream.requestCheckpoint() }
            var freshCheckpoint: PagedTerminalCheckpoint?
            while let event = await events.next() {
                if case .checkpoint(let checkpoint) = event { freshCheckpoint = checkpoint; break }
                if case .output(let data) = event { terminal.access.write(data) }
            }
            let checkpoint = try #require(freshCheckpoint)
            try await renderer.install(checkpoint, generation: generation)
            var ordinal: UInt64 = 0
            while true {
                let request = PagedTerminalHistoryRequest(incarnation: checkpoint.incarnation,
                    checkpointID: checkpoint.id, requestID: ordinal + 1, ordinal: ordinal, screen: 0)
                try await stream.requestHistory(request)
                guard case .page(let page) = try #require(await events.next()) else {
                    Issue.record("Dense history must arrive as a bounded page, not a host limit refusal"); return
                }
                #expect(page.data.count <= PagedTerminalLimits.pageBytes)
                try await stream.requestHistory(request)
                #expect(await events.next() == .page(page))
                try #require(await renderer.appendHistory(page.data, screen: 0, generation: generation) == .applied)
                if page.complete { break }
                ordinal += 1
                try #require(ordinal < 200)
            }
            #expect(terminal.firstHistoryRow().contains("history-row-000000"))
            #expect(terminal.text().contains("history-row-001999"))
            let marker = "after-history-\(generation)"
            var receivedLiveResponse = false
            try await stream.send(Data("\(marker)\n".utf8))
            while let event = await events.next() {
                guard case .output(let data) = event else { continue }
                terminal.access.write(data)
                if terminal.text().contains("live-\(marker)") { receivedLiveResponse = true; break }
            }
            #expect(receivedLiveResponse)
        }
    }

    @Test("@spec TERM-12.45: When an older daemon refuses an oversized history page, the application shall report the host page limit without automatic retries and continue live terminal input and output.",
          .enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_HISTORY_LEGACY_ZMX"] != nil,
                   "The history CI scenario supplies the immutable graftty6 daemon"), .timeLimit(.minutes(1)))
    func oldDaemonPageRefusalPreservesLiveTerminal() async throws {
        let oldDaemon = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GRAFTTY_HISTORY_LEGACY_ZMX"]))
        let fixture = try await HistoryDaemon.make(lineCount: 2000, wide: true, executable: oldDaemon)
        defer { fixture.close() }
        let stream = PagedZmxAttachEngine(config: .init(zmxExecutable: fixture.launcher.executable,
            zmxDir: fixture.launcher.zmxDir, sessionName: "history"))
        try await stream.start()
        defer { stream.close() }
        var events = stream.events.makeAsyncIterator()
        let terminal = try NativeCanvas()
        defer { terminal.close() }
        let renderer = MacPagedTerminalRenderer(surface: terminal.access, prepareGrid: terminal.prepareGrid)
        var requests: [PagedTerminalRequest] = []
        let coordinator = PagedTerminalCoordinator(renderer: renderer) { request in
            requests.append(request)
            switch request {
            case .history(let page): try await stream.requestHistory(page)
            case .checkpoint: try await stream.requestCheckpoint()
            }
        }
        guard case .checkpoint(let checkpoint) = try #require(await events.next()) else {
            Issue.record("Expected old daemon checkpoint"); return
        }
        try await coordinator.handle(.checkpoint(checkpoint))
        await coordinator.loadIfNeeded(prefetch: true)
        guard case .unavailable(let refusal) = try #require(await events.next()) else {
            Issue.record("Expected graftty6 oversized-page refusal"); return
        }
        #expect(refusal.reason == .limit)
        try await coordinator.handle(.unavailable(refusal))
        #expect(coordinator.status == .pageTooLarge)
        await coordinator.loadIfNeeded(prefetch: true)
        await coordinator.retry()
        #expect(requests.count == 1)
        try await stream.send(Data("old-daemon-still-live\n".utf8))
        var receivedLiveResponse = false
        while let event = await events.next() {
            try await coordinator.handle(event)
            if case .output(let data) = event { terminal.access.write(data) }
            if terminal.text().contains("live-old-daemon-still-live") { receivedLiveResponse = true; break }
        }
        #expect(receivedLiveResponse)
        #expect(coordinator.status == .pageTooLarge)
        #expect(requests.count == 1)
        coordinator.disconnect()
    }

    @Test("@spec TERM-12.42: While a native Mac terminal consumes a paged source stream, the application shall preserve its parser grid and synchronized output across local viewport and font resizes, report source dimensions, and release the source grid before legacy fallback.", .timeLimit(.minutes(1)))
    func nativeParserGridFollowsOrderedSourceRatherThanPhysicalSize() async throws {
        let terminal = try NativeCanvas()
        defer { terminal.close() }
        let renderer = MacPagedTerminalRenderer(surface: terminal.access, prepareGrid: terminal.prepareGrid)
        try await renderer.resize(cols: 80, rows: 24)
        terminal.access.write(Data("\u{1b}[?2026h\u{1b}[?2048h".utf8))
        ghostty_surface_set_size(terminal.raw, 330, 400)
        let fontAction = "increase_font_size:1"
        _ = fontAction.withCString { ghostty_surface_binding_action(terminal.raw, $0, UInt(fontAction.utf8.count)) }
        // Drain Ghostty's 25ms native resize coalescer, including the font
        // event. Parser state must remain fixed while physical size changes.
        try await Task.sleep(for: .milliseconds(100))
        #expect(ghostty_surface_grid_matches(terminal.raw, 80, 24))
        terminal.access.write(Data("\u{1b}[?2026$p\u{1b}[18t".utf8))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !terminal.responses.contains("\u{1b}[8;24;80t"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(terminal.responses.contains("\u{1b}[?2026;1$y"))
        #expect(terminal.responses.contains("\u{1b}[8;24;80t"))
        let physical = ghostty_surface_size(terminal.raw)
        // The source acknowledges geometry already applied locally, so
        // presentation produces no second resize to mask a missing report.
        try await renderer.resize(cols: physical.columns, rows: physical.rows)
        let report = "\u{1b}[48;\(physical.rows);\(physical.columns);"
        while !terminal.responses.contains(report), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(terminal.responses.contains(report), "Mode 2048 must announce the acknowledged logical size")
        #expect(ghostty_surface_grid_matches(terminal.raw, physical.columns, physical.rows))
        let parserOnly = MacPagedTerminalRenderer(surface: terminal.access, prepareGrid: { _ in })
        try await parserOnly.resize(cols: physical.columns + 2, rows: physical.rows + 3)
        #expect(ghostty_surface_grid_matches(terminal.raw, physical.columns + 2, physical.rows + 3))
        terminal.access.write(Data("\u{1b}[18t".utf8))
        let pinnedReply = "\u{1b}[8;\(physical.rows + 3);\(physical.columns + 2)t"
        let pinnedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !terminal.responses.contains(pinnedReply), ContinuousClock.now < pinnedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(terminal.responses.contains(pinnedReply))
        let reportStart = terminal.responses.snapshot().count
        // Clear immediately after queuing a physical resize, before its
        // coalescer updates io.size. The first report must use parser state.
        ghostty_surface_set_size(terminal.raw, 310, 390)
        let fallback = ghostty_surface_size(terminal.raw)
        try await renderer.releaseSourceGrid()
        terminal.access.write(Data("\u{1b}[18t".utf8))
        let fallbackReply = "\u{1b}[8;\(fallback.rows);\(fallback.columns)t"
        let fallbackDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !String(decoding: terminal.responses.snapshot().dropFirst(reportStart), as: UTF8.self).contains(fallbackReply),
              ContinuousClock.now < fallbackDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reports = String(decoding: terminal.responses.snapshot().dropFirst(reportStart), as: UTF8.self)
        let firstReport = reports.range(of: "\u{1b}\\[48;[0-9]+;[0-9]+;", options: .regularExpression).map { String(reports[$0]) }
        #expect(firstReport == "\u{1b}[48;\(fallback.rows);\(fallback.columns);")
        #expect(ghostty_surface_grid_matches(terminal.raw, fallback.columns, fallback.rows))
    }

    @Test("@spec TERM-12.37: While a Mac terminal backfills history, the application shall preserve access to older pages when live output edits the active screen or reallocates its page storage.", .timeLimit(.minutes(1)), arguments: [false, true])
    func historySurvivesLiveScreenEdits(editRows: Bool) async throws {
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
        let terminal = try NativeCanvas()
        defer { terminal.close() }
        let renderer = MacPagedTerminalRenderer(surface: terminal.access, prepareGrid: terminal.prepareGrid)
        try await renderer.install(checkpoint, generation: 1)
        // Exceed the standard page's 128 styles to replace its allocation.
        // Its rows remain adjacent to the history that has not arrived yet.
        let styled = "\u{1b}7\u{1b}[H" + (0..<512).map {
            "\u{1b}[38;2;\($0 % 256);\($0 / 256);2mX"
        }.joined() + "\u{1b}[0m\u{1b}8"
        terminal.access.write(Data(styled.utf8))
        if editRows { terminal.access.write(Data("\u{1b}7\u{1b}[H\u{1b}[2L\u{1b}[M\u{1b}8".utf8)) }
        let visible = terminal.text()
        #expect(visible.contains(String(repeating: "X", count: 64)))
        var ordinal: UInt64 = 0
        while true {
            try await stream.requestHistory(.init(incarnation: checkpoint.incarnation, checkpointID: checkpoint.id,
                requestID: ordinal + 1, ordinal: ordinal, screen: 0))
            guard case .page(let page) = try #require(await events.next()) else {
                Issue.record("Expected the requested history page"); return
            }
            try #require(await renderer.appendHistory(page.data, screen: 0, generation: 1) == .applied)
            #expect(terminal.text() == visible)
            if page.complete { break }
            ordinal += 1
            try #require(ordinal < 200)
        }
        #expect(terminal.firstHistoryRow().contains("history-row-000000"))
    }

    @Test("@spec TERM-12.38: If live output resets a restored Mac terminal or explicitly erases its history, then the application shall reject pending older pages without restoring the discarded history.", .timeLimit(.minutes(1)), arguments: ["\u{1b}c", "\u{1b}[3J"])
    func discardedHistoryIsNotImported(invalidation: String) async throws {
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
        let terminal = try NativeCanvas()
        defer { terminal.close() }
        let renderer = MacPagedTerminalRenderer(surface: terminal.access, prepareGrid: terminal.prepareGrid)
        try await renderer.install(checkpoint, generation: 1)
        terminal.access.write(Data(invalidation.utf8))
        let visible = terminal.text()
        try await stream.requestHistory(.init(incarnation: checkpoint.incarnation, checkpointID: checkpoint.id,
            requestID: 1, ordinal: 0, screen: 0))
        guard case .page(let page) = try #require(await events.next()) else {
            Issue.record("Expected the requested history page"); return
        }
        #expect(await renderer.appendHistory(page.data, screen: 0, generation: 1) == .requiresRecovery)
        #expect(terminal.text() == visible)
        #expect(!terminal.firstHistoryRow().contains("history-row-000000"))
    }

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

    @Test("@spec TERM-12.1: When Graftty on Mac or mobile opens a terminal through a paging-capable attachment, the application shall restore the current screen and parser state with a bounded recent-history allowance before fetching older history, without serializing or transferring the complete retained history on the initial path.", .timeLimit(.minutes(1)), arguments: [false, true])
    func nativeScreenAppearsBeforeHistoryAndDoesNotPageThroughIt(reflowed: Bool) async throws {
        let fixture = try await HistoryDaemon.make(reflowed: reflowed)
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

    @Test("@spec TERM-12.39: When the Mac takes control of a restored paged terminal from mobile, the application shall resize to the Mac viewport and keep the terminal attachment available for input and live output.", .timeLimit(.minutes(1)))
    func takeControlKeepsRestoredAttachmentLive() async throws {
        let fixture = try await HistoryDaemon.make()
        defer { fixture.close() }
        let terminal = try NativeCanvas()
        defer { terminal.close() }
        let store = SessionDisplayOwnershipStore()
        let phone = DisplayClientID("phone")
        _ = store.attachClient(sessionName: "history", clientID: phone, kind: .ios,
                               role: .interactive, visible: true, grid: try DisplayGrid(cols: 80, rows: 24))
        _ = store.claimOwner(sessionName: "history", clientID: phone, kind: .ios,
                             grid: try DisplayGrid(cols: 80, rows: 24))
        let backend = HostManagedZmxBackend(spawnConfiguration: .init(
            sessionName: "history", argv: ["/nonexistent-graftty-legacy-attach"],
            env: fixture.launcher.subprocessEnv(from: ProcessInfo.processInfo.environment),
            workingDirectory: fixture.launcher.zmxDir, shellReadySignalAvailable: false
        ), initialSize: .init(cols: 80, rows: 24),
            ownership: HostManagedZmxOwnership(store: store, sessionName: "history", clientID: DisplayClientID("mac")))
        defer { backend.close(); backend.releaseReceiveUserdataAfterSurfaceFree() }
        var completed = false
        var failure: String?
        backend.bindAttachmentFailure { failure = $0 }
        backend.bindAttachmentGrid { grid in
            if let grid { terminal.prepareGrid(grid) }
            else { completed = true }
        }
        backend.bindSurfaceSync(currentWindowSize: { .init(cols: 165, rows: 79, xpixel: 2661, ypixel: 2714) }, requestRefresh: {})
        backend.markLayoutSettled()
        try backend.start(surface: terminal.raw)
        let deadline = ContinuousClock.now + .seconds(10)
        while !completed, failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(completed)
        #expect(failure == nil)
        #expect(store.snapshot(sessionName: "history").ownerClientID == phone)
        terminal.prepareGrid(try DisplayGrid(cols: 165, rows: 79))
        #expect(backend.takeControl())
        #expect(store.snapshot(sessionName: "history").ownerClientID == DisplayClientID("mac"))
        #expect(store.snapshot(sessionName: "history").grid == (try DisplayGrid(cols: 165, rows: 79)))
        try backend.write(Data("takeover-probe\r".utf8))
        while !terminal.text().contains("live-takeover-probe"), failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(failure == nil)
        #expect(terminal.text().contains("live-takeover-probe"))
    }

    @MainActor
    private final class NativeCanvas {
        let app: GhosttyApp
        let window: NSWindow
        let view: NSView
        let raw: ghostty_surface_t
        let access: MacPagedSurface
        let responses = HistoryOutput(marker: "unused-response-marker")
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
            config.receive_userdata = Unmanaged.passUnretained(responses).toOpaque()
            config.receive_buffer = { userdata, bytes, count in
                guard let userdata, let bytes, count > 0 else { return }
                Unmanaged<HistoryOutput>.fromOpaque(userdata).takeUnretainedValue().append(Data(bytes: bytes, count: Int(count)))
            }
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

        private init(lineCount: Int, redrawPrompt: Bool, wide: Bool, executable: URL?) throws {
            output = HistoryOutput(marker: redrawPrompt ? "history-prompt> " : String(format: "history-row-%06d", lineCount - 1))
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let dir = URL(fileURLWithPath: "/private/tmp/mac-paging-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            launcher = ZmxLauncher(executable: executable ?? root.appendingPathComponent("Resources/zmx-binary/zmx"), zmxDir: dir)
            // Keep the shell alive after producing the fixture; the client reader
            // drains the PTY so this setup cannot block on its output buffer.
            let output = output
            let prompt = redrawPrompt ? "printf '\\033]133;A;redraw=1\\007history-prompt> \\033]133;B\\007'; " : ""
            let historyLine = wide
                ? "🧪 history-row-%06d /workspace/project/src/components/HistoryPanel.swift:100"
                : "history-row-%06d"
            seed = NativePtySession(argv: [launcher.executable.path, "attach", "history", "/bin/sh", "-c",
                "i=0; while [ $i -lt \(lineCount) ]; do printf '\(historyLine)\\n' $i; i=$((i+1)); done; \(prompt)while read value; do printf 'live-%s\\n' \"$value\"; done"],
                env: launcher.subprocessEnv(from: ProcessInfo.processInfo.environment),
                workingDirectory: dir, initialSize: .init(cols: 80, rows: 24),
                writeToSurface: { output.append($0) }, processExited: { _, _ in }, spawnFailed: { _ in })
        }

        static func make(lineCount: Int = 10000, redrawPrompt: Bool = false, reflowed: Bool = false, wide: Bool = false, executable: URL? = nil) async throws -> HistoryDaemon {
            let fixture = try HistoryDaemon(lineCount: lineCount, redrawPrompt: redrawPrompt, wide: wide, executable: executable)
            do {
                try fixture.seed.start()
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !fixture.output.finished {
                    guard ContinuousClock.now < deadline else { throw MacPagedTerminalRenderer.Error.gridUnavailable }
                    try await Task.sleep(for: .milliseconds(10))
                }
                if reflowed {
                    try fixture.seed.resize(cols: 79, rows: 74)
                    try fixture.seed.write(Data("resized\n".utf8))
                    while !fixture.output.contains("live-resized") {
                        guard ContinuousClock.now < deadline else { throw MacPagedTerminalRenderer.Error.gridUnavailable }
                        try await Task.sleep(for: .milliseconds(10))
                    }
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
        func contains(_ text: String) -> Bool {
            lock.withLock { String(decoding: bytes, as: UTF8.self).contains(text) }
        }
        func snapshot() -> Data { lock.withLock { bytes } }
        var finished: Bool { contains(marker) }
    }
}

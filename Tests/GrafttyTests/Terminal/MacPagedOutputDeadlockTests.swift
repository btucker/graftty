import AppKit
import GhosttyKit
@testable import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import Testing
import XCTest
@testable import Graftty

#if GRAFTTY_PAGED_HISTORY
struct MacPagedOutputDeadlockTests {
    @Test("@spec TERM-12.56: When live output fills the native app mailbox in a Mac paged attachment, the application shall keep main available to drain messages and apply subsequent output and control events in order.")
    func remoteOutputMakesMailboxProgress() async throws {
        try await runChild("testRemoteOutput")
    }

    @Test func nativeKeyboardScrollLoadsOlderHistory() async throws {
        try await runChild("testRemoteKeyboard")
    }

    @Test("@spec TERM-12.65: When an initial remote Mac owner resize changes the checkpoint width before history is read, the application shall refresh that checkpoint at the new width and keep older rows reachable on scroll demand.")
    func initialOwnerResizePreservesHistory() async throws {
        try await runChild("testInitialOwnerResizeHistory")
    }

    @Test("@spec TERM-12.57: When a local Mac paged attachment receives title output that exceeds the native mailbox capacity, the application shall parse it off main and render its final output before reporting shell exit.")
    func localOutputMakesMailboxProgress() async throws {
        try await runChild("testLocalOutput")
    }

    @Test("@spec TERM-12.58: When a Mac remote attachment closes during native parsing, the application shall stop admitting surface calls, drain the mailbox while joining parsing, and reject cancelled or late output before the surface is freed.", arguments: ["testPagedRetirement", "testLegacyRetirement"])
    func retirementMakesMailboxProgress(method: String) async throws {
        try await runChild(method)
    }

    @Test("@spec TERM-12.59: When a Mac paged surface retires after native grid completion but before its renderer resumes, the application shall reject pending presentation callbacks.")
    func completedGridCannotPublishAfterRetirement() async throws {
        try await runChild("testGridCompletionRetirement")
    }

    private func runChild(_ method: String) async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/paged-output-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("child.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "GrafttyTests.MacPagedOutputDeadlockChild/\(method)",
                           Bundle(for: MacPagedOutputDeadlockChild.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["GRAFTTY_PAGED_OUTPUT_PROBE"] = directory.path
        child.environment = environment
        child.standardOutput = output
        child.standardError = output
        try child.run()
        var succeeded = false
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            // SIGKILL bypasses the child's defers. The parent owns the daemon
            // identity too, so a RED probe cannot leave a persistent shell.
            let launcher = ZmxLauncher(executable: PagedOutputProbePaths.executable,
                                      zmxDir: directory.appendingPathComponent("daemon"))
            launcher.kill(sessionName: "probe")
            try? FileManager.default.removeItem(at: launcher.zmxDir)
            if succeeded { try? FileManager.default.removeItem(at: directory) }
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while child.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if child.isRunning {
            // Capture the causal stack before killing the child. The sample
            // has its own deadline so a failing probe cannot hold the build lock.
            let sample = Process()
            sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sample.arguments = [String(child.processIdentifier), "1", "1", "-file", directory.appendingPathComponent("sample.txt").path]
            sample.standardOutput = output
            sample.standardError = output
            try sample.run()
            let sampleDeadline = ContinuousClock.now + .seconds(20)
            while sample.isRunning, ContinuousClock.now < sampleDeadline { try await Task.sleep(for: .milliseconds(20)) }
            if sample.isRunning { kill(sample.processIdentifier, SIGKILL) }
            kill(child.processIdentifier, SIGKILL)
            Issue.record("Native paged output blocked for 15 seconds; diagnostics: \(directory.path)")
            return
        }
        let diagnostics = try String(contentsOf: log, encoding: .utf8)
        #expect(child.terminationReason == .exit && child.terminationStatus == 0, "Native probe failed: \(diagnostics)")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("completed").path))
        succeeded = child.terminationReason == .exit && child.terminationStatus == 0
    }
}

@MainActor
final class MacPagedOutputDeadlockChild: XCTestCase {
    private func probeDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["GRAFTTY_PAGED_OUTPUT_PROBE"] else {
            throw XCTSkip("Isolated native paged output probe")
        }
        return URL(fileURLWithPath: directory)
    }

    private func complete(_ directory: URL) throws {
        try Data("completed".utf8).write(to: directory.appendingPathComponent("completed"))
    }

    func testInitialOwnerResizeHistory() async throws {
        let directory = try probeDirectory()
        let daemon = try await PagedOutputDaemon.make()
        defer { daemon.close() }
        let stream = PagedZmxAttachEngine(config: .init(zmxExecutable: daemon.launcher.executable,
            zmxDir: daemon.launcher.zmxDir, sessionName: "probe", workingDirectory: daemon.launcher.zmxDir))
        try await stream.start()
        defer { stream.close() }
        var events = stream.events.makeAsyncIterator()
        guard case .checkpoint(let checkpoint) = await events.next() else { XCTFail("Missing READY"); return }
        let client = PagedOutputProbeClient(control: true, onSend: { frame in
            guard case .text(let text) = frame, let request = try PagedTerminalEnvelope.parse(text).request else { return }
            switch request {
            case .checkpoint: try await stream.requestCheckpoint()
            case .history(let request): try await stream.requestHistory(request)
            }
        }, onResize: { cols, rows in try? stream.resize(windowSize: .init(cols: UInt16(cols), rows: UInt16(rows))) })
        let backend = RemoteTerminalSurfaceBackend(client: client)
        let canvas = try PagedOutputCanvas(configure: backend.configure)
        let ownerGrid = try DisplayGrid(cols: 120, rows: 24)
        backend.bindAttachmentGrid { canvas.prepareGrid($0 ?? ownerGrid) }
        backend.bindSurfaceSync(currentGridSize: { (120, 24) }, requestRefresh: {})
        defer { backend.close(); canvas.close(); backend.surfaceWasFreed() }
        var pages: [PagedTerminalPage] = []
        var checkpoints = 0
        let forward = Task { @MainActor in
            while let event = await events.next(), !Task.isCancelled {
                switch event {
                case .output(let bytes): client.deliver(.binary(bytes))
                case .ended: return
                default:
                    if case .page(let page) = event { pages.append(page) }
                    if case .checkpoint = event { checkpoints += 1 }
                    client.deliver(.paged(event))
                }
            }
        }
        defer { forward.cancel() }
        try backend.start(surface: canvas.surface)
        try await waitUntil { client.helloID != nil }
        let id = try XCTUnwrap(client.helloID)
        client.deliver(.text(WebControlEnvelope.ownership(try .init(sessionName: "probe",
            ownerClientID: id, ownerKind: .mac, grid: .init(cols: 80, rows: 24), epoch: 1, revision: 1)).encoded()))
        client.deliver(.paged(.checkpoint(checkpoint)))
        try await waitUntil { checkpoints == 1 }
        XCTAssertTrue(pages.isEmpty, "The initial rebase must not eagerly transfer history")
        for ordinal in 0..<100 {
            let action = "scroll_to_row:0"
            action.withCString { _ = ghostty_surface_binding_action(canvas.surface, $0, UInt(action.utf8.count)) }
            backend.historyViewportDidChange(requestHistory: true)
            try await waitUntil { pages.count > ordinal }
            if pages[ordinal].complete { break }
        }
        try await waitUntil { canvas.oldestHistoryRow().contains("seed-row-0") }
        XCTAssertEqual(ghostty_surface_size(canvas.surface).columns, 120)
        try complete(directory)
    }

    func testRemoteOutput() async throws { try await remoteOutput(keyboard: false) }
    func testRemoteKeyboard() async throws { try await remoteOutput(keyboard: true) }

    private func remoteOutput(keyboard: Bool) async throws {
        let directory = try probeDirectory()
        let daemon = try await PagedOutputDaemon.make()
        defer { daemon.close() }
        let stream = PagedZmxAttachEngine(config: .init(zmxExecutable: daemon.launcher.executable,
            zmxDir: daemon.launcher.zmxDir, sessionName: "probe", workingDirectory: daemon.launcher.zmxDir))
        try await stream.start()
        defer { stream.close() }
        var events = stream.events.makeAsyncIterator()
        guard case .checkpoint(let checkpoint) = await events.next() else { XCTFail("Missing READY"); return }
        let client = PagedOutputProbeClient()
        let backend = RemoteTerminalSurfaceBackend(client: client)
        let canvas = try PagedOutputCanvas(configure: backend.configure)
        backend.bindAttachmentGrid { canvas.prepareGrid($0) }
        defer { backend.close(); canvas.close(); backend.surfaceWasFreed() }
        try backend.start(surface: canvas.surface)
        // A checkpoint must fence the previous parser call as well as the
        // following VT, grid and PAGE imports. A fire-and-forget write fails.
        client.deliver(.binary(titleOutput + Data("discard-before-ready\r\n".utf8)))
        client.deliver(.text(try PagedTerminalEnvelope(event: .checkpoint(checkpoint)).encoded()))
        client.deliver(.binary(titleOutput + Data("before-grid\r\n".utf8)))
        client.deliver(.text(try PagedTerminalEnvelope(event: .grid(cols: 80, rows: 24)).encoded()))
        client.deliver(.binary(Data("after-grid\r\n".utf8)))
        try await waitUntil { client.receiveCount >= 6 }
        XCTAssertTrue(client.sentFrames.isEmpty, "Live output must not prefetch history")
        let visible = canvas.text()
        XCTAssertFalse(visible.contains("discard-before-ready"), visible)
        XCTAssertTrue(visible.contains("seed-row-999"), visible)
        let before = try XCTUnwrap(visible.range(of: "before-grid"))
        let after = try XCTUnwrap(visible.range(of: "after-grid"))
        XCTAssertLessThan(before.lowerBound, after.lowerBound)
        XCTAssertFalse(canvas.oldestHistoryRow().contains("seed-row-0"))
        let keyboardView = SurfaceNSView()
        keyboardView.surface = canvas.surface
        keyboardView.historyScrollChords = { canvas.historyChords }
        keyboardView.historyScrollNotifier = { backend.historyViewportDidChange(requestHistory: true) }
        canvas.setScrollNotification { Task { @MainActor in backend.historyViewportDidChange(requestHistory: false) } }
        defer { keyboardView.surface = nil }
        let home = String(UnicodeScalar(NSHomeFunctionKey)!)
        let keyEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: canvas.window.windowNumber,
            context: nil, characters: home, charactersIgnoringModifiers: home, isARepeat: false, keyCode: 115))
        XCTAssertEqual(GhosttyTriggerAdapter.chord(from: keyEvent), .init(key: "home", modifiers: .command))
        var received = 6
        for ordinal in 0..<100 {
            if keyboard {
                keyboardView.keyDown(with: keyEvent)
            } else {
                let scroll = "scroll_to_row:0"
                scroll.withCString { _ = ghostty_surface_binding_action(canvas.surface, $0, UInt(scroll.utf8.count)) }
                backend.historyViewportDidChange(requestHistory: true)
            }
            try await waitUntil { client.sentFrames.count > ordinal }
            guard case .text(let text) = client.sentFrames[ordinal],
                  case .history(let request)? = try PagedTerminalEnvelope.parse(text).request else {
                XCTFail("Missing history request"); return
            }
            try await stream.requestHistory(request)
            guard case .page(let page) = await events.next() else { XCTFail("Missing PAGE"); return }
            XCTAssertFalse(page.data.isEmpty)
            client.deliver(.binary(titleOutput))
            client.deliver(.text(try PagedTerminalEnvelope(event: .page(page)).encoded()))
            client.deliver(.binary(Data("after-page\r\n".utf8)))
            received += 3
            try await waitUntil { client.receiveCount >= received }
            if page.complete { break }
        }
        XCTAssertTrue(canvas.oldestHistoryRow().contains("seed-row-0"))
        // History demand now scrolls the native viewport. Return to the live
        // screen before checking the output that arrived during page imports.
        let bottom = "scroll_to_bottom"
        XCTAssertTrue(bottom.withCString { ghostty_surface_binding_action(canvas.surface, $0, UInt(bottom.utf8.count)) })
        try await waitUntil { canvas.text().contains("after-page") }
        XCTAssertTrue(canvas.text().contains("after-grid"), canvas.text())
        XCTAssertEqual(canvas.titles.last, "paged-title-255")
        // A distinct grid must apply before the following VT cursor query.
        // At 40 columns, x at column 40 wraps Y to row 2, column 2.
        client.deliver(.text(try PagedTerminalEnvelope(event: .grid(cols: 40, rows: 24)).encoded()))
        client.deliver(.binary(Data("\u{1b}[2J\u{1b}[H\u{1b}[40GxY\u{1b}[6n".utf8)))
        try await waitUntil { client.sentFrames.contains(.binary(Data("\u{1b}[2;2R".utf8))) }
        XCTAssertTrue(ghostty_surface_grid_matches(canvas.surface, 40, 24))
        try complete(directory)
    }

    func testLocalOutput() async throws {
        let directory = try probeDirectory()
        let daemon = try await PagedOutputDaemon.make()
        defer { daemon.close() }
        let canvas = try PagedOutputCanvas()
        let session = MacPagedZmxSession(surface: canvas.surface, configuration: .init(
            sessionName: "probe", argv: [daemon.launcher.executable.path, "attach", "probe"],
            env: daemon.launcher.subprocessEnv(from: ProcessInfo.processInfo.environment),
            workingDirectory: daemon.launcher.zmxDir, shellReadySignalAvailable: false), initialSize: .init(cols: 80, rows: 24))
        session.bindAttachmentGrid { canvas.prepareGrid($0) }
        session.bindAttachmentFailure { XCTFail($0) }
        defer { session.close(); canvas.close() }
        try session.start()
        let started = await session.waitForStartup()
        XCTAssertTrue(started)
        try session.write(Data("flood\n".utf8))
        // The shell waits for another input after its final bytes so reading
        // text is safe only once the last title reaches main via app.tick.
        try await waitUntil { canvas.titles.last == "paged-title-255" }
        try await waitUntil { canvas.text().contains("local-output-finished") }
        try session.write(Data("exit\n".utf8))
        try await waitUntil { ghostty_surface_process_exited(canvas.surface) }
        XCTAssertTrue(canvas.text().contains("local-output-finished"))
        try complete(directory)
    }

    func testPagedRetirement() async throws { try await retirement(paged: true) }
    func testLegacyRetirement() async throws { try await retirement(paged: false) }

    func testGridCompletionRetirement() async throws {
        let directory = try probeDirectory()
        let canvas = try PagedOutputCanvas()
        defer { canvas.close() }
        let owner = PagedSurfaceOwner()
        let access = MacPagedSurface(canvas.surface, scheduleOnMain: { work in
            DispatchQueue.main.async {
                work()
                // Finish C, then retire in the same main turn, before the
                // renderer continuation has a chance to publish its grid.
                owner.access?.close()
            }
        })
        owner.access = access
        let renderer = MacPagedTerminalRenderer(surface: access, prepareGrid: { _ in
            XCTFail("A retired native grid must not publish presentation")
        })
        do {
            try await renderer.resize(cols: 80, rows: 24)
            XCTFail("A retired renderer operation must fail")
        } catch { }
        access.close()
        try complete(directory)
    }

    private func retirement(paged: Bool) async throws {
        let directory = try probeDirectory()
        let entered = DispatchSemaphore(value: 0)
        let parse = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let client = PagedOutputProbeClient(paged: paged)
        var renderer: MacPagedTerminalRenderer?
        let backend = RemoteTerminalSurfaceBackend(client: client, writeBuffer: { surface, bytes in
            XCTAssertFalse(Thread.isMainThread)
            entered.signal()
            XCTAssertEqual(parse.wait(timeout: .now() + 3), .success)
            bytes.withUnsafeBytes {
                ghostty_surface_write_buffer(surface, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt($0.count))
            }
            finished.signal()
        }, pagedRendererFactory: { access, prepare in
            let value = MacPagedTerminalRenderer(surface: access, prepareGrid: prepare)
            renderer = value
            return value
        })
        let canvas = try PagedOutputCanvas(configure: backend.configure)
        var refreshes = 0
        backend.bindSurfaceSync(currentGridSize: { nil }, requestRefresh: { refreshes += 1 })
        try backend.start(surface: canvas.surface)
        client.deliver(.binary(titleOutput))
        try await waitUntil { entered.wait(timeout: .now()) == .success }
        let control = Task { @MainActor in
            try await renderer?.setSourceGrid(cols: 91, rows: 31)
        }
        await Task.yield()
        control.cancel()
        parse.signal()
        // Hold main until the real parser fills the 64-slot mailbox. A plain
        // close barrier or a polling read waiting on its Swift lock hangs.
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        XCTAssertFalse(renderer?.isNearHistoryTop(screen: 0, generation: 1) ?? false)
        // Unlike the host's Swift calls lock, the pinned native parser drops
        // its renderer mutex before waiting on a full app mailbox.
        XCTAssertTrue(ghostty_surface_grid_matches(canvas.surface,
            ghostty_surface_size(canvas.surface).columns, ghostty_surface_size(canvas.surface).rows))
        var history = ghostty_text_s()
        _ = ghostty_surface_read_history(canvas.surface, 1, 1, &history)
        ghostty_surface_free_text(canvas.surface, &history)
        backend.close()
        backend.close()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        canvas.close()
        backend.surfaceWasFreed()
        _ = await control.result
        client.deliver(.binary(titleOutput))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(client.receiveCount, 1, "A retired receive must not read another frame")
        XCTAssertEqual(refreshes, 0, "A retired write must not publish a refresh")
        XCTAssertEqual(entered.wait(timeout: .now()), .timedOut, "Late output must not reach freed native memory")
        try complete(directory)
    }

    private var titleOutput: Data {
        Data((0..<256).map { "\u{1b}]2;paged-title-\($0)\u{7}" }.joined().utf8)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now >= deadline { throw ProbeTimeout() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum PagedOutputProbePaths {
    static var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/zmx-binary/zmx")
    }
}

private struct ProbeTimeout: Error {}

@MainActor
private final class PagedSurfaceOwner {
    var access: MacPagedSurface?
}

@MainActor
private final class PagedOutputCanvas {
    let app: GhosttyApp
    let window: NSWindow
    let view: NSView
    let surface: ghostty_surface_t
    private var observer: NSObjectProtocol?
    private let actions: PagedOutputActions
    var titles: [String] { actions.titles }
    let historyChords: [ShortcutChord]
    func setScrollNotification(_ callback: @escaping @Sendable () -> Void) { actions.setScrollNotification(callback) }

    init(configure: (inout ghostty_surface_config_s) -> Void = { config in
        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_buffer = { _, _, _ in }
        config.receive_resize = { _, _, _, _, _ in }
    }) throws {
        _ = NSApplication.shared
        XCTAssertEqual(ghostty_init(0, nil), 0)
        let actions = PagedOutputActions()
        self.actions = actions
        let nativeConfig = GhosttyConfig()
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".conf")
        try Data("keybind = super+home=scroll_to_top\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        ghostty_config_load_file(nativeConfig.config, file.path)
        ghostty_config_finalize(nativeConfig.config)
        historyChords = Array(GhosttyKeybindBridge(resolver: GhosttyTriggerAdapter.resolver(config: nativeConfig.config)).historyChords.values)
        app = GhosttyApp(config: nativeConfig) { _, action in actions.record(action); return true }
        window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 800, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = NSView(frame: window.contentView!.bounds)
        view.wantsLayer = true
        window.contentView = view
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        config.scale_factor = window.backingScaleFactor
        configure(&config)
        surface = try XCTUnwrap(ghostty_surface_new(app.app, &config))
        observer = GhosttyWakeupBridge.observe { [app] in app.tick() }
        window.orderBack(nil)
    }

    func prepareGrid(_ grid: DisplayGrid?) {
        guard let grid else { return }
        let size = ghostty_surface_size(surface)
        let width = Int(size.width_px) + (Int(grid.cols) - Int(size.columns)) * Int(size.cell_width_px)
        let height = Int(size.height_px) + (Int(grid.rows) - Int(size.rows)) * Int(size.cell_height_px)
        ghostty_surface_set_size(surface, UInt32(clamping: width), UInt32(clamping: height))
    }

    func oldestHistoryRow() -> String {
        var text = ghostty_text_s()
        guard ghostty_surface_read_history(surface, 1, 1, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return text.text.map { String(decoding: Data(bytes: $0, count: Int(text.text_len)), as: UTF8.self) } ?? ""
    }

    func text() -> String {
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0), rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return text.text.map { String(decoding: Data(bytes: $0, count: Int(text.text_len)), as: UTF8.self) } ?? ""
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        ghostty_surface_free(surface)
        window.close()
        withExtendedLifetime(app) {}
    }
}

private final class PagedOutputActions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var scrollNotification: (@Sendable () -> Void)?
    func setScrollNotification(_ callback: @escaping @Sendable () -> Void) { lock.withLock { scrollNotification = callback } }
    var titles: [String] { lock.withLock { values } }
    func record(_ action: ghostty_action_s) {
        if action.tag == GHOSTTY_ACTION_SCROLLBAR { lock.withLock { scrollNotification }?() }
        if action.tag == GHOSTTY_ACTION_SET_TITLE, let title = action.action.set_title.title {
            let value = String(cString: title)
            lock.withLock { values.append(value) }
        }
    }
}

@MainActor
private final class PagedOutputDaemon {
    let launcher: ZmxLauncher
    private let seed: NativePtySession
    private let output = PagedOutputSeed()

    private init() throws {
        let parent = try XCTUnwrap(ProcessInfo.processInfo.environment["GRAFTTY_PAGED_OUTPUT_PROBE"])
        let directory = URL(fileURLWithPath: parent).appendingPathComponent("daemon")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        launcher = ZmxLauncher(executable: PagedOutputProbePaths.executable, zmxDir: directory)
        let output = output
        let shell = "i=0; while [ $i -lt 1000 ]; do printf 'seed-row-%s\\n' $i; i=$((i+1)); done; printf 'seed-ready\\n'; while read value; do if [ \"$value\" = exit ]; then exit 0; fi; i=0; while [ $i -lt 256 ]; do printf '\\033]2;paged-title-%s\\007' $i; i=$((i+1)); done; printf 'local-output-finished\\n'; done"
        seed = NativePtySession(argv: [launcher.executable.path, "attach", "probe", "/bin/sh", "-c", shell],
            env: launcher.subprocessEnv(from: ProcessInfo.processInfo.environment), workingDirectory: directory,
            initialSize: .init(cols: 80, rows: 24), writeToSurface: { bytes in
                output.append(bytes)
            }, processExited: { _, _ in }, spawnFailed: { _ in })
    }

    static func make() async throws -> PagedOutputDaemon {
        let daemon = try PagedOutputDaemon()
        do {
            try daemon.seed.start()
            let deadline = ContinuousClock.now + .seconds(5)
            while !daemon.output.isReady {
                if ContinuousClock.now >= deadline { throw ProbeTimeout() }
                try await Task.sleep(for: .milliseconds(5))
            }
            daemon.seed.close()
            return daemon
        } catch { daemon.close(); throw error }
    }

    func close() {
        seed.close()
        launcher.kill(sessionName: "probe")
        try? FileManager.default.removeItem(at: launcher.zmxDir)
    }
}

private final class PagedOutputSeed: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    var isReady: Bool { lock.withLock { String(decoding: bytes, as: UTF8.self).contains("seed-ready") } }
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
}

private final class PagedOutputProbeClient: WebSocketClient, @unchecked Sendable {
    let supportsPagedHistory: Bool
    let supportsWebControlTextFrames: Bool
    private let onSend: (@Sendable (WebSocketFrame) async throws -> Void)?
    private let onResize: (@Sendable (Int, Int) async -> Void)?
    private var hello: DisplayClientID?
    var helloID: DisplayClientID? { lock.withLock { hello } }
    init(paged: Bool = true, control: Bool = false,
         onSend: (@Sendable (WebSocketFrame) async throws -> Void)? = nil,
         onResize: (@Sendable (Int, Int) async -> Void)? = nil) {
        supportsPagedHistory = paged
        supportsWebControlTextFrames = control
        self.onSend = onSend
        self.onResize = onResize
    }
    func sendHello(clientID: DisplayClientID, kind: DisplayClientKind, role: DisplayClientRole,
                   visible: Bool, cols: Int, rows: Int) async { lock.withLock { hello = clientID } }
    func ownerResize(clientID: DisplayClientID, epoch: UInt64, cols: Int, rows: Int) async {
        await onResize?(cols, rows)
    }
    private let lock = NSLock()
    private var frames: [WebSocketFrame] = []
    private var waiter: CheckedContinuation<WebSocketFrame, Error>?
    private var closed = false
    private var receives = 0
    private var sent: [WebSocketFrame] = []
    var sentFrames: [WebSocketFrame] { lock.withLock { sent } }
    var receiveCount: Int { lock.withLock { receives } }
    func send(_ frame: WebSocketFrame) async throws {
        lock.withLock { sent.append(frame) }
        try await onSend?(frame)
    }
    func receive() async throws -> WebSocketFrame {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            receives += 1
            if closed { lock.unlock(); continuation.resume(throwing: CancellationError()) }
            else if !frames.isEmpty { let frame = frames.removeFirst(); lock.unlock(); continuation.resume(returning: frame) }
            else { waiter = continuation; lock.unlock() }
        }
    }
    func deliver(_ frame: WebSocketFrame) {
        lock.lock()
        let next = waiter
        waiter = nil
        if next == nil { frames.append(frame) }
        lock.unlock()
        next?.resume(returning: frame)
    }
    func close() {
        lock.lock()
        closed = true
        let next = waiter
        waiter = nil
        lock.unlock()
        next?.resume(throwing: CancellationError())
    }
}
#endif

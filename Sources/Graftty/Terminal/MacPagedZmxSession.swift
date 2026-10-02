import Foundation
import os
import GhosttyKit
import GrafttyKit
import GrafttyProtocol

/// Tries screen-first attachment to an existing daemon. A new shell or an old
/// daemon still uses the normal PTY spawn, before any snapshot is installed.
final class MacPagedZmxSession: HostManagedZmxSession, @unchecked Sendable {
    private enum Command { case input(Data), resize(PtyProcess.WindowSize), restored }
    private let lock = NSLock()
    private let surface: MacPagedSurface
    private let configuration: ZmxSpawnConfiguration
    private var fallback: NativePtySession?
    private let commands: AsyncStream<Command>
    private let commandSink: AsyncStream<Command>.Continuation
    private var task: Task<Void, Never>?
    private var engine: PagedZmxAttachEngine?
    private var closed = false
    private var started = false
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var restored = false
    private var failed = false
    private var startupResult: Bool?
    private var startupWaiters: [CheckedContinuation<Bool, Never>] = []
    private var attachmentFailure: (String) -> Void = { _ in }
    private var prepareGrid: (DisplayGrid?) -> Void = { _ in }

    init(surface: ghostty_surface_t, configuration: ZmxSpawnConfiguration, initialSize: PtyProcess.WindowSize?) {
        self.surface = MacPagedSurface(surface)
        self.configuration = configuration
        let pair = AsyncStream<Command>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        commands = pair.stream
        commandSink = pair.continuation
        if let initialSize { commandSink.yield(.resize(initialSize)) }
        fallback = NativePtySession(argv: configuration.argv, env: configuration.env,
            workingDirectory: configuration.workingDirectory, initialSize: initialSize,
            writeToSurface: { [weak self] in self?.surface.write($0) },
            processExited: { [weak self] _, status in
                // NativePtySession holds its I/O lock during this callback.
                // Querying the daemon here would also block pane teardown.
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.legacyAttachmentExited(status: status)
                }
            },
            spawnFailed: { [weak self] in self?.reportFailure("Could not attach to the terminal: \($0)") })
    }

    func bindAttachmentFailure(_ handler: @escaping (String) -> Void) {
        lock.withLock { attachmentFailure = handler }
    }

    func bindAttachmentGrid(_ prepareGrid: @escaping (DisplayGrid?) -> Void) {
        lock.withLock { self.prepareGrid = prepareGrid }
    }

    func start() throws {
        try lock.withLock {
            guard !closed else { throw NativePtySession.Error.closed }
            guard !started else { throw NativePtySession.Error.alreadyStarted }
            started = true
            startedAt = ProcessInfo.processInfo.systemUptime
            task = Task { @MainActor [weak self] in await self?.run() }
        }
    }

    func waitForStartup() async -> Bool {
        await withCheckedContinuation { continuation in
            let result = lock.withLock { () -> Bool? in
                if let startupResult { return startupResult }
                startupWaiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(returning: result) }
        }
    }

    private func completeStartup(_ result: Bool) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            guard startupResult == nil else { return [] }
            startupResult = result
            let waiters = startupWaiters
            startupWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: result) }
    }

    @MainActor
    private func run() async {
        defer { commandSink.finish() }
        guard !lock.withLock({ closed }) else { return }
        guard MacPagedTerminalRenderer.isSupported else {
            await runLegacy()
            return
        }
        let config = configuration
        let stream = PagedZmxAttachEngine(config: .init(
            zmxExecutable: URL(fileURLWithPath: config.argv[0]),
            zmxDir: URL(fileURLWithPath: config.env["ZMX_DIR"] ?? ""),
            sessionName: config.sessionName, workingDirectory: config.workingDirectory
        ))
        let active = lock.withLock { () -> Bool in
            guard !closed else { return false }
            engine = stream
            return true
        }
        guard active else { return }
        do { try await stream.start() }
        catch {
            guard !Task.isCancelled, !lock.withLock({ closed }) else { return }
            // Negotiation failed before any bytes reached the renderer.
            await runLegacy()
            return
        }
        guard !Task.isCancelled else { await stream.close(); return }

        let prepare = lock.withLock { prepareGrid }
        let renderer = MacPagedTerminalRenderer(surface: surface, prepareGrid: prepare)
        let attachment = MacPagedAttachment(renderer: renderer, finishGrid: { [weak self] in
            prepare(nil)
            // Completion is durable even when startup input fills the queue.
            // The marker only wakes an otherwise idle sender.
            self?.lock.withLock { self?.restored = true }
            self?.commandSink.yield(.restored)
        }) { request in
            switch request {
            case .history(let page): try await stream.requestHistory(page)
            case .checkpoint: try await stream.requestCheckpoint()
            }
        }
        var events = stream.events.makeAsyncIterator()
        do {
            guard let first = await events.next(), case .checkpoint = first else {
                throw MacPagedTerminalRenderer.Error.invalidSnapshot
            }
            try await attachment.handle(first)
        } catch {
            attachment.close()
            await stream.close()
            guard !Task.isCancelled, !lock.withLock({ closed }) else { return }
            prepare(nil)
            await runLegacy()
            return
        }
        if configuration.startupReceipt == nil { completeStartup(true) }
        else { Task { @MainActor [weak self] in await self?.acknowledgeLegacyStartup() } }
        let sender = Task {
            var pendingSize: PtyProcess.WindowSize?
            for await command in commands {
                guard !Task.isCancelled else { return }
                do {
                    let restored = lock.withLock { self.restored }
                    if restored, let size = pendingSize {
                        try stream.resize(windowSize: size)
                        pendingSize = nil
                    }
                    switch command {
                    case .input(let data): try await stream.send(data)
                    case .resize(let size):
                        if !restored { pendingSize = size }
                        else { try stream.resize(windowSize: size) }
                    case .restored:
                        break
                    }
                } catch {
                    reportFailure("Terminal connection failed: \(error)")
                    await stream.close()
                    return
                }
            }
        }
        defer { sender.cancel(); attachment.close() }
        var receivedExit = false
        do {
            while let event = await events.next() {
                try Task.checkCancellation()
                switch event {
                case .output(let bytes): surface.write(bytes)
                case .ended(let status):
                    receivedExit = true
                    reportExit(status: status)
                    await stream.close()
                    return
                default: try await attachment.handle(event)
                }
            }
        } catch {
            // Never mix a legacy replay into an installed checkpoint.
            if !Task.isCancelled { receivedExit = true; reportFailure("Terminal restoration failed: \(error)") }
        }
        if !receivedExit, !Task.isCancelled { reportFailure("Terminal connection was interrupted.") }
        await stream.close()
    }

    func write(_ data: Data) throws { try enqueue(.input(data)) }
    func resize(cols: UInt16, rows: UInt16) throws {
        try resize(windowSize: .init(cols: cols, rows: rows))
    }
    func resize(windowSize: PtyProcess.WindowSize) throws { try enqueue(.resize(windowSize)) }

    private func enqueue(_ command: Command) throws {
        try lock.withLock {
            guard !closed else { throw NativePtySession.Error.closed }
            guard !failed else { throw NativePtySession.Error.notStarted }
            switch commandSink.yield(command) {
            case .enqueued: break
            case .dropped, .terminated: throw NativePtySession.Error.notStarted
            @unknown default: throw NativePtySession.Error.notStarted
            }
        }
    }

    @MainActor
    private func runLegacy() async {
        guard let fallback else { return }
        do {
            lock.withLock { startedAt = ProcessInfo.processInfo.systemUptime }
            try fallback.start()
            Task { @MainActor [weak self] in await self?.acknowledgeLegacyStartup() }
            for await command in commands {
                guard !Task.isCancelled, !lock.withLock({ failed }) else { break }
                switch command {
                case .input(let data): try fallback.write(data)
                case .resize(let size): try fallback.resize(windowSize: size)
                case .restored: break
                }
            }
        } catch { reportFailure("Terminal connection failed: \(error)") }
    }

    @MainActor
    private func acknowledgeLegacyStartup() async {
        let socket = URL(fileURLWithPath: configuration.env["ZMX_DIR"] ?? "")
            .appendingPathComponent(configuration.sessionName).path
        let deadline = ContinuousClock.now + .seconds(configuration.startupReceipt == nil ? 5 : 300)
        while !lock.withLock({ closed || failed || startupResult != nil }) {
            let accepted: Bool
            if let receipt = configuration.startupReceipt {
                accepted = FileManager.default.fileExists(atPath: receipt.path)
            } else if FileManager.default.fileExists(atPath: socket) {
                let launcher = ZmxLauncher(executable: URL(fileURLWithPath: configuration.argv[0]),
                    zmxDir: URL(fileURLWithPath: configuration.env["ZMX_DIR"] ?? ""))
                let name = configuration.sessionName
                accepted = (try? await OffMainIO.run {
                    try launcher.listSessions().contains(name)
                }) == true
            } else {
                accepted = false
            }
            if accepted {
                completeStartup(true)
                return
            }
            guard ContinuousClock.now < deadline else {
                completeStartup(false)
                return
            }
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { completeStartup(false); return }
        }
    }

    private func legacyAttachmentExited(status: Int32?) {
        guard !lock.withLock({ closed }) else { return }
        // The short-lived attach process can exit while the daemon and shell
        // are still running. Only a confirmed missing daemon is a shell exit.
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: configuration.argv[0]),
            zmxDir: URL(fileURLWithPath: configuration.env["ZMX_DIR"] ?? ""))
        // Legacy zmx attach returns success for a completed shell, including
        // a shell that exits nonzero. A failed attach can leave no daemon too.
        if status == 0, launcher.isSessionMissing(configuration.sessionName) {
            reportExit(status: 0)
        } else {
            reportFailure("Terminal attachment ended. Reconnect to resume the session.")
        }
    }

    private func reportFailure(_ message: String) {
        completeStartup(false)
        let handler = lock.withLock { () -> ((String) -> Void)? in
            guard !closed, !failed else { return nil }
            failed = true
            return attachmentFailure
        }
        guard let handler else { return }
        commandSink.finish()
        Logger(subsystem: "com.graftty.app", category: "terminal-attachment")
            .error("\(self.configuration.sessionName, privacy: .public): \(message, privacy: .public)")
        handler(message)
    }

    private func reportExit(status: Int32) {
        completeStartup(false)
        let elapsed = lock.withLock { ProcessInfo.processInfo.systemUptime - startedAt }
        let milliseconds = UInt64(max(0, elapsed) * 1_000)
        surface.withSurface { ghostty_surface_process_exit($0, UInt32(clamping: status), milliseconds) }
    }

    func close() {
        completeStartup(false)
        let current = lock.withLock { () -> (Task<Void, Never>?, PagedZmxAttachEngine?) in
            closed = true
            commandSink.finish()
            let current = (task, engine)
            task = nil
            engine = nil
            return current
        }
        surface.close()
        current.0?.cancel()
        current.1?.close()
        fallback?.close()
    }

    deinit { close() }
}

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
    private var activeStartupReceipt: URL?
    private let initialSize: PtyProcess.WindowSize?
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
    private let startupTimeout: Duration
    private var startupDeadline: ContinuousClock.Instant?
    private var attachmentFailure: (String) -> Void = { _ in }
    private var prepareGrid: (DisplayGrid?) -> Void = { _ in }

    init(surface: ghostty_surface_t, configuration: ZmxSpawnConfiguration, initialSize: PtyProcess.WindowSize?, startupTimeout: Duration? = nil) {
        self.surface = MacPagedSurface(surface)
        self.configuration = configuration
        self.activeStartupReceipt = configuration.startupReceipt
        self.initialSize = initialSize
        self.startupTimeout = startupTimeout ?? .seconds(configuration.startupReceipt == nil ? 20 : 300)
        let pair = AsyncStream<Command>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        commands = pair.stream
        commandSink = pair.continuation
        if let initialSize { commandSink.yield(.resize(initialSize)) }
    }

    private func makeLegacySession(env: [String: String], initialSize: PtyProcess.WindowSize?) -> NativePtySession {
        NativePtySession(argv: configuration.argv, env: env,
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
            startupDeadline = ContinuousClock.now + startupTimeout
            task = Task { @MainActor [weak self] in await self?.run() }
        }
    }

    func waitForStartup() async -> Bool {
        while !Task.isCancelled {
            let (result, deadline) = lock.withLock { (startupResult, startupDeadline) }
            if let result { return result }
            guard let deadline else { return false }
            guard ContinuousClock.now < deadline else {
                reportFailure("Terminal startup timed out. Reconnect to resume the session.", onlyDuringStartup: true)
                return lock.withLock { startupResult ?? false }
            }
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return false }
        }
        return false
    }

    private func completeStartup(_ result: Bool) {
        lock.withLock {
            if startupResult == nil { startupResult = result }
        }
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
        defer { attachment.close() }
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
        // Paging attaches only to an existing daemon. Its checkpoint proves
        // attachment; that shell cannot consume this renderer's new receipt.
        let startupCheck: Task<Void, Never>?
        if configuration.runsInitialCommand {
            startupCheck = Task { @MainActor [weak self] in
                guard let self else { return }
                if await self.acceptExistingStartupCommand() { self.completeStartup(true) }
                else { await stream.close() }
            }
        } else {
            completeStartup(true)
            startupCheck = nil
        }
        defer { startupCheck?.cancel() }
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
        defer { sender.cancel() }
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
        do {
            // Old daemons cannot negotiate paging, but still accept attach.
            // Confirm existence before spawning so a fresh shell must prove
            // acceptance with its receipt rather than mere daemon presence.
            let launcher = ZmxLauncher(executable: URL(fileURLWithPath: configuration.argv[0]),
                zmxDir: URL(fileURLWithPath: configuration.env["ZMX_DIR"] ?? ""))
            let name = configuration.sessionName
            let existing = try await OffMainIO.run {
                try launcher.listSessions().contains(name)
            }
            guard !Task.isCancelled, !lock.withLock({ closed || failed }) else { return }
            if existing, !(await acceptExistingStartupCommand()) { return }
            var env = configuration.env
            if existing || configuration.startupReceipt.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                // If the daemon exits before attach, its replacement must not
                // replay a command already accepted by the previous shell.
                env.removeValue(forKey: "GRAFTTY_INITIAL_COMMAND")
                env.removeValue(forKey: "GRAFTTY_STARTUP_RECEIPT")
            }
            let fallback = makeLegacySession(env: env, initialSize: initialSize)
            let active = lock.withLock {
                guard !closed, !failed else { return false }
                self.fallback = fallback
                activeStartupReceipt = env["GRAFTTY_STARTUP_RECEIPT"].map { URL(fileURLWithPath: $0) }
                startedAt = ProcessInfo.processInfo.systemUptime
                return true
            }
            guard active else { fallback.close(); return }
            try fallback.start()
            let requiresReceipt = env["GRAFTTY_STARTUP_RECEIPT"] != nil
            Task { @MainActor [weak self] in await self?.acknowledgeLegacyStartup(requiresReceipt: requiresReceipt) }
            for await command in commands {
                guard !Task.isCancelled, !lock.withLock({ failed }) else { break }
                switch command {
                case .input(let data): try fallback.write(data)
                case .resize(let size): try fallback.resize(windowSize: size)
                case .restored: break
                }
            }
        } catch { reportFailure("Terminal connection failed: \(error). Reconnect to resume the session.") }
    }

    /// Attaching cannot deliver a new shell-init command to an existing
    /// daemon. A prior receipt proves that command was already consumed.
    @MainActor
    private func acceptExistingStartupCommand() async -> Bool {
        guard configuration.runsInitialCommand else { return true }
        let deadline = min(lock.withLock { startupDeadline } ?? ContinuousClock.now,
            ContinuousClock.now + .seconds(5))
        while !Task.isCancelled, !lock.withLock({ closed || failed }) {
            if let receipt = configuration.startupReceipt,
               FileManager.default.fileExists(atPath: receipt.path) { return true }
            guard ContinuousClock.now < deadline else { break }
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return false }
        }
        reportFailure("Existing terminal has not accepted the launch command. Reconnect to resume its session.", onlyDuringStartup: true)
        return false
    }

    @MainActor
    private func acknowledgeLegacyStartup(requiresReceipt: Bool) async {
        let socket = URL(fileURLWithPath: configuration.env["ZMX_DIR"] ?? "")
            .appendingPathComponent(configuration.sessionName).path
        guard let deadline = lock.withLock({ startupDeadline }) else { return }
        while !lock.withLock({ closed || failed || startupResult != nil }) {
            let accepted: Bool
            if requiresReceipt, let receipt = configuration.startupReceipt {
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
                reportFailure("Terminal startup timed out. Reconnect to resume the session.", onlyDuringStartup: true)
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

    private func reportFailure(_ message: String, onlyDuringStartup: Bool = false) {
        let handler = lock.withLock { () -> ((String) -> Void)? in
            guard !closed, !failed else { return nil }
            guard !onlyDuringStartup || startupResult == nil else { return nil }
            if startupResult == nil { startupResult = false }
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
        // A short command may exit before the receipt poll gets scheduled.
        // Establish acceptance before pane teardown removes the receipt.
        completeStartup(lock.withLock { activeStartupReceipt }.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false)
        let elapsed = lock.withLock { ProcessInfo.processInfo.systemUptime - startedAt }
        let milliseconds = UInt64(max(0, elapsed) * 1_000)
        surface.withSurface { ghostty_surface_process_exit($0, UInt32(clamping: status), milliseconds) }
    }

    func close() {
        completeStartup(false)
        let current = lock.withLock { () -> (Task<Void, Never>?, PagedZmxAttachEngine?, NativePtySession?) in
            closed = true
            commandSink.finish()
            let current = (task, engine, fallback)
            task = nil
            engine = nil
            fallback = nil
            return current
        }
        surface.close()
        current.0?.cancel()
        current.1?.close()
        current.2?.close()
    }

    deinit { close() }
}

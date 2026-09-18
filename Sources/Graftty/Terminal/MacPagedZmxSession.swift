import Foundation
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
    private let fallback: NativePtySession
    private let commands: AsyncStream<Command>
    private let commandSink: AsyncStream<Command>.Continuation
    private var task: Task<Void, Never>?
    private var engine: PagedZmxAttachEngine?
    private var closed = false
    private var started = false
    private var restored = false
    private var prepareGrid: (DisplayGrid?) -> Void = { _ in }

    init(surface: ghostty_surface_t, configuration: ZmxSpawnConfiguration, initialSize: PtyProcess.WindowSize?) {
        self.surface = MacPagedSurface(surface)
        self.configuration = configuration
        fallback = NativePtySession(surface: surface, argv: configuration.argv, env: configuration.env,
            workingDirectory: configuration.workingDirectory, initialSize: initialSize, spawnFailed: { _ in })
        let pair = AsyncStream<Command>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        commands = pair.stream
        commandSink = pair.continuation
        if let initialSize { commandSink.yield(.resize(initialSize)) }
    }

    func bindAttachmentGrid(_ prepareGrid: @escaping (DisplayGrid?) -> Void) {
        lock.withLock { self.prepareGrid = prepareGrid }
    }

    func start() throws {
        try lock.withLock {
            guard !closed else { throw NativePtySession.Error.closed }
            guard !started else { throw NativePtySession.Error.alreadyStarted }
            started = true
            task = Task { @MainActor [weak self] in await self?.run() }
        }
    }

    @MainActor
    private func run() async {
        defer { commandSink.finish() }
        guard !lock.withLock({ closed }) else { return }
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
                default: try await attachment.handle(event)
                }
            }
        } catch {
            // Never mix a legacy replay into an installed checkpoint.
            if !Task.isCancelled { receivedExit = true; reportExit() }
        }
        if !receivedExit, !Task.isCancelled { reportExit() }
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
            try fallback.start()
            for await command in commands {
                guard !Task.isCancelled else { break }
                switch command {
                case .input(let data): try fallback.write(data)
                case .resize(let size): try fallback.resize(windowSize: size)
                case .restored: break
                }
            }
        } catch { reportExit() }
    }

    private func reportExit(status: Int32 = 1) {
        surface.withSurface { ghostty_surface_process_exit($0, UInt32(clamping: status), 0) }
    }

    func close() {
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
        fallback.close()
    }

    deinit { close() }
}

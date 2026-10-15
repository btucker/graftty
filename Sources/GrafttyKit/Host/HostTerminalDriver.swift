import Foundation

@MainActor
public protocol HostTerminalDriver: AnyObject {
    func sessions() async throws -> Set<String>
    func start(_ configuration: ZmxSpawnConfiguration) async throws
    func kill(_ session: String) async throws
    func send(_ text: String, to session: String) async throws
    func show(_ session: String, lines: Int) async throws -> String
    func detachAll()
}

/// Keeps a draining attach client until shutdown; closing it leaves the zmx
/// daemon and shell alive. Each SSH viewer creates its own attach engine.
@MainActor
public final class ZmxHostTerminalDriver: HostTerminalDriver {
    private let launcher: ZmxLauncher
    private var engines: [String: ZmxAttachEngine] = [:]

    public init(launcher: ZmxLauncher) { self.launcher = launcher }

    public func sessions() async throws -> Set<String> {
        let launcher = launcher
        return try await Task.detached { try launcher.listSessions() }.value
    }

    public func start(_ configuration: ZmxSpawnConfiguration) async throws {
        if engines[configuration.sessionName] != nil { return }
        let engine = ZmxAttachEngine(config: .init(zmxExecutable: launcher.executable,
            zmxDir: launcher.zmxDir, sessionName: configuration.sessionName,
            workingDirectory: configuration.workingDirectory, spawnConfiguration: configuration))
        // Consume headless output without retaining history in an AsyncStream.
        engine.onPTYData = { _ in }
        try await Task.detached { try engine.start() }.value
        do {
            // PTY spawn alone is not a successful daemon startup. Bound the
            // check so a bad shell/zmx executable produces a useful failure.
            let deadline = Date().addingTimeInterval(5)
            while !(try await sessions()).contains(configuration.sessionName) {
                guard Date() < deadline else { throw HostRuntimeError.invalid("zmx session did not start") }
                try await Task.sleep(for: .milliseconds(50))
            }
            engines[configuration.sessionName] = engine
        } catch {
            await engine.close()
            throw error
        }
    }

    public func kill(_ session: String) async throws {
        await engines.removeValue(forKey: session)?.close()
        let launcher = launcher
        let result = try await Task.detached {
            try ZmxRunner.captureAll(executable: launcher.executable, args: ["kill", "--force", session],
                env: launcher.subprocessEnv(from: ProcessInfo.processInfo.environment), timeout: 2)
        }.value
        let remaining = try await sessions()
        guard result.exitCode == 0 || !remaining.contains(session) else {
            throw HostRuntimeError.invalid(result.stderr)
        }
    }

    public func send(_ text: String, to session: String) async throws {
        let launcher = launcher
        try await Task.detached { try launcher.send(sessionName: session, text: text) }.value
    }

    public func show(_ session: String, lines: Int) async throws -> String {
        let launcher = launcher
        return try await Task.detached {
            let result = try ZmxRunner.captureAll(executable: launcher.executable,
                args: ["history", session], env: launcher.subprocessEnv(from: ProcessInfo.processInfo.environment), timeout: 2)
            guard result.exitCode == 0 else { throw HostRuntimeError.invalid(result.stderr) }
            return ScrollbackTail.tail(result.stdout, lines: lines)
        }.value
    }

    public func detachAll() {
        for engine in engines.values { let close: () -> Void = engine.close; close() }
        engines.removeAll()
    }
}

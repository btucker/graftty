import Foundation
import Testing
@testable import GrafttyKit

/// Engine-level tests for the PTY-backed attach engine shared by `/ws`
/// (via the `WebSession` adapter) and the SSH-over-WebRTC `terminal`
/// channel (directly, as a `TerminalByteStream`). `WebSessionTests`
/// covers the callback-based surface end-to-end through the adapter;
/// these tests exercise the engine directly, with emphasis on the
/// `TerminalByteStream` conformance the SSH path now relies on.
@Suite("ZmxAttachEngine")
struct ZmxAttachEngineTests {

    private static func makeTempDir(prefix: String = "zmx-attach-engine") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func writeScript(_ body: String, to url: URL) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Fake "zmx" whose `attach` subcommand just execs `cat`, echoing
    /// whatever it reads on the PTY back out. Stands in for the real
    /// `zmx attach` for round-trip tests that don't care about session
    /// semantics, only PTY plumbing.
    private static func makeEchoZmx(in dir: URL) throws -> URL {
        let script = dir.appendingPathComponent("zmx")
        try writeScript("#!/bin/sh\nexec cat\n", to: script)
        return script
    }

    /// Fake "zmx" that reports the PTY's winsize (via `stty size`, which
    /// reads `TIOCGWINSZ` on its controlling terminal) after a short
    /// delay, then stays alive so the parent has time to resize before
    /// the read. Used to prove `resize` reaches the real PTY master.
    private static func makeSizeReportingZmx(in dir: URL) throws -> URL {
        let script = dir.appendingPathComponent("zmx")
        try writeScript("#!/bin/sh\nsleep 0.2; stty size; sleep 1\n", to: script)
        return script
    }

    /// Fake "zmx" that exits immediately — the "instantly-dying child"
    /// case TERM-11.5's registry balance must survive.
    private static func makeInstantExitZmx(in dir: URL) throws -> URL {
        let script = dir.appendingPathComponent("zmx")
        try writeScript("#!/bin/sh\nexit 0\n", to: script)
        return script
    }

    /// Fake "zmx" that traps SIGTERM and records receipt, then sleeps —
    /// mirrors `WebSessionTests.makeFakeZmx` for the SIGTERM-on-close
    /// assertion. Writes `startedFile` before installing the trap so a
    /// caller can wait for the trap to be armed before sending SIGTERM —
    /// without that handshake, a SIGTERM delivered mid-exec (before the
    /// shell has reached the `trap` builtin) terminates the process under
    /// the default disposition and the trap body never runs.
    private static func makeSleepingZmx(in dir: URL, startedFile: URL, termFile: URL) throws -> URL {
        let script = dir.appendingPathComponent("zmx")
        try writeScript("""
        #!/bin/sh
        trap 'printf TERM > \(shellQuoted(termFile.path)); exit 0' TERM
        printf started > \(shellQuoted(startedFile.path))
        while :; do sleep 0.05; done
        """, to: script)
        return script
    }

    private static func waitForFile(_ url: URL, timeout: TimeInterval = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func makeEngine(zmxExecutable: URL, zmxDir: URL, sessionName: String) -> ZmxAttachEngine {
        ZmxAttachEngine(config: ZmxAttachEngine.Config(
            zmxExecutable: zmxExecutable,
            zmxDir: zmxDir,
            sessionName: sessionName
        ))
    }

    // MARK: - TerminalByteStream round trip

    @Test func spawnAndEchoRoundTripThroughTerminalByteStream() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeZmx = try Self.makeEchoZmx(in: dir)
        let zmxDir = dir.appendingPathComponent("zmx-state", isDirectory: true)
        try FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)

        let engine = Self.makeEngine(zmxExecutable: fakeZmx, zmxDir: zmxDir, sessionName: "echo-test")
        try engine.start()
        defer { engine.close() }

        // Exercise the TerminalByteStream surface (not the WebSession
        // callback surface) — this is what TerminalChannelHandler uses.
        try await engine.send(Data("hi\n".utf8))

        var iterator = engine.inboundBytes.makeAsyncIterator()
        var collected = Data()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !String(data: collected, encoding: .utf8)!.contains("hi") {
            guard let chunk = await iterator.next() else { break }
            collected.append(chunk)
        }
        #expect(String(data: collected, encoding: .utf8)?.contains("hi") == true,
                "expected echoed 'hi' on inboundBytes; got \(collected.count) bytes")
    }

    // MARK: - Close semantics

    @Test func closeSendsSIGTERMAndFinishesInboundBytes() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let startedFile = dir.appendingPathComponent("started.txt")
        let termFile = dir.appendingPathComponent("term.txt")
        let fakeZmx = try Self.makeSleepingZmx(in: dir, startedFile: startedFile, termFile: termFile)
        let zmxDir = dir.appendingPathComponent("zmx-state", isDirectory: true)
        try FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)

        let engine = Self.makeEngine(zmxExecutable: fakeZmx, zmxDir: zmxDir, sessionName: "close-test")
        try engine.start()
        // Wait for the trap to be armed (see makeSleepingZmx) before
        // sending SIGTERM, or the signal can arrive during exec and kill
        // the child under the default disposition before it ever runs.
        #expect(Self.waitForFile(startedFile))

        await engine.close()

        #expect(Self.waitForFile(termFile), "expected SIGTERM to reach the attach child")
        let termText = try String(contentsOf: termFile, encoding: .utf8)
        #expect(termText == "TERM")

        // TerminalByteStream.close() contract: inboundBytes must finish
        // synchronously with close() returning, so a `for await` consumer
        // (TerminalChannelHandler) exits its loop rather than hanging.
        var iterator = engine.inboundBytes.makeAsyncIterator()
        let next = await iterator.next()
        #expect(next == nil)
    }

    // MARK: - Resize reaches the real PTY (the headline upgrade over ZmxAttachStream's ENOTTY no-op)

    @Test func resizeChangesRealPTYWinsize() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeZmx = try Self.makeSizeReportingZmx(in: dir)
        let zmxDir = dir.appendingPathComponent("zmx-state", isDirectory: true)
        try FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)

        let engine = Self.makeEngine(zmxExecutable: fakeZmx, zmxDir: zmxDir, sessionName: "resize-test")
        try engine.start()
        defer { engine.close() }

        // Exercise the TerminalByteStream resize(cols:rows:) async entry
        // point — the one SSH's `window-change` handling drives. Before
        // this engine existed, ZmxAttachStream's equivalent ioctl'd a
        // pipe fd and silently no-op'd (ENOTTY); here it must reach the
        // real PTY master before the child's `stty size` reads it.
        await engine.resize(cols: 42, rows: 13)

        var iterator = engine.inboundBytes.makeAsyncIterator()
        var collected = Data()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(String(data: collected, encoding: .utf8) ?? "").contains("13 42") {
            guard let chunk = await iterator.next() else { break }
            collected.append(chunk)
        }
        #expect(String(data: collected, encoding: .utf8)?.contains("13 42") == true,
                "expected 'stty size' to report the resized dimensions; got \(collected.count) bytes: \(String(data: collected, encoding: .utf8) ?? "<non-utf8>")")
    }

    // MARK: - Registry attach/detach balance (TERM-11.5), ported from the
    // deleted ZmxAttachStreamRegistryTests.

    @Test func registersAttachOnStartAndDetachesExactlyOnceOnClose() throws {
        let dir = try Self.makeTempDir(prefix: "zmx-attach-engine-registry")
        defer { try? FileManager.default.removeItem(at: dir) }
        let startedFile = dir.appendingPathComponent("started.txt")
        let termFile = dir.appendingPathComponent("term.txt")
        let fakeZmx = try Self.makeSleepingZmx(in: dir, startedFile: startedFile, termFile: termFile)
        let zmxDir = dir.appendingPathComponent("zmx-state", isDirectory: true)
        try FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)

        let registry = RemoteAttachmentRegistry()
        let engine = Self.makeEngine(zmxExecutable: fakeZmx, zmxDir: zmxDir, sessionName: "reg-test")
        engine.attachmentRegistry = registry

        try engine.start()
        #expect(registry.isRemoteAttached(sessionName: "reg-test"))

        engine.close()
        #expect(!registry.isRemoteAttached(sessionName: "reg-test"))

        // close() is idempotent — a second call must not double-detach.
        // An extra attach stands in for another remote client; a
        // double-detach would wrongly drop the count to zero.
        registry.attach(sessionName: "reg-test")
        engine.close()
        #expect(registry.isRemoteAttached(sessionName: "reg-test"))
    }

    /// TERM-11.5's instantly-dying-child case. `ZmxAttachStream`
    /// (Process+Pipe) raced its registry `attach()` against the async
    /// GCD readability handler's EOF-triggered `close()`, since `attach()`
    /// ran *after* `process.run()` returned while the handler could already
    /// be firing on another thread. `ZmxAttachEngine.start()` calls
    /// `attachmentRegistry?.attach(...)` immediately after a successful
    /// `PtyProcess.spawn` and strictly *before* the reader thread is
    /// created (`startReaderThread()` runs after), so the reader can never
    /// observe EOF before the attach is registered — this test pins that
    /// ordering so a future refactor can't reintroduce the race.
    @Test func instantlyDyingChildStillBalancesRegistryAttachDetach() throws {
        let dir = try Self.makeTempDir(prefix: "zmx-attach-engine-instant-death")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeZmx = try Self.makeInstantExitZmx(in: dir)
        let zmxDir = dir.appendingPathComponent("zmx-state", isDirectory: true)
        try FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)

        let registry = RemoteAttachmentRegistry()
        let engine = Self.makeEngine(zmxExecutable: fakeZmx, zmxDir: zmxDir, sessionName: "instant-death-test")
        engine.attachmentRegistry = registry

        let exited = DispatchSemaphore(value: 0)
        engine.onExit = { exited.signal() }

        try engine.start()
        // A successful spawn always registers, regardless of how fast the
        // child dies afterward.
        #expect(registry.isRemoteAttached(sessionName: "instant-death-test"))

        // Let the reader thread observe EOF from the already-dead child.
        #expect(exited.wait(timeout: .now() + 2) == .success)
        // Still attached: onExit alone does not detach — only close() does.
        #expect(registry.isRemoteAttached(sessionName: "instant-death-test"))

        engine.close()
        #expect(!registry.isRemoteAttached(sessionName: "instant-death-test"))

        // Idempotent close, same double-attach probe as above.
        registry.attach(sessionName: "instant-death-test")
        engine.close()
        #expect(registry.isRemoteAttached(sessionName: "instant-death-test"))
    }
}

import Testing
import Foundation
import Darwin
@testable import GrafttyKit

/// End-to-end coverage for the native host-managed zmx attach model.
///
/// These tests intentionally spawn `zmx attach` through `PtyProcess.spawn`
/// with argv/env, mirroring the native host-managed path. They must not use
/// `attachCommand`, `sh -c`, or any initial-input bootstrap.
@Suite("Zmx — native host-managed attach integration", .serialized)
struct ZmxNativeHostManagedIntegrationTests {

    struct PtyAttach {
        let pid: pid_t
        let masterFd: Int32

        func write(_ string: String) throws {
            try SocketIO.writeAll(fd: masterFd, string: string)
        }

        func readAvailable() -> String {
            var bytes = [UInt8](repeating: 0, count: 4096)
            var output = ""
            while true {
                let count = bytes.withUnsafeMutableBytes { raw in
                    Darwin.read(masterFd, raw.baseAddress!, raw.count)
                }
                if count <= 0 { break }
                output += String(decoding: bytes.prefix(count), as: UTF8.self)
            }
            return output
        }

        func terminate(signal: Int32 = SIGTERM) {
            _ = Darwin.kill(pid, signal)

            var status: Int32 = 0
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || result == -1 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }

            if waitpid(pid, &status, WNOHANG) == 0 {
                _ = Darwin.kill(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
            }

            Darwin.close(masterFd)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func hostManagedAttachCreatesSession() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            let attach = try Self.spawnHostManagedAttach(
                launcher: launcher,
                sessionName: session
            )
            defer {
                attach.terminate()
                launcher.kill(sessionName: session)
            }

            try Self.waitForSession(launcher: launcher, name: session, timeout: 5.0)
            #expect(try launcher.listSessions().contains(session))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cleanClientCloseLeavesDaemonListed() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            let attach = try Self.spawnHostManagedAttach(
                launcher: launcher,
                sessionName: session
            )
            var attachRunning = true
            defer {
                if attachRunning { attach.terminate() }
                launcher.kill(sessionName: session)
            }

            try Self.waitForSession(launcher: launcher, name: session, timeout: 5.0)
            attach.terminate(signal: SIGTERM)
            attachRunning = false

            try Self.waitForSession(launcher: launcher, name: session, timeout: 2.0)
            #expect(try launcher.listSessions().contains(session))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func detachedLiveSessionAcceptsSendAndExposesHistory() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            let lhs = Int.random(in: 100_000...400_000)
            let rhs = Int.random(in: 100_000...400_000)
            let marker = "DETACHED_RESULT_\(lhs + rhs)"
            let attach = try Self.spawnHostManagedAttach(
                launcher: launcher,
                sessionName: session
            )
            var attachRunning = true
            defer {
                if attachRunning { attach.terminate() }
                launcher.kill(sessionName: session)
            }

            try Self.waitForAttachReady(attach)
            attach.terminate(signal: SIGTERM)
            attachRunning = false
            try Self.waitForSession(launcher: launcher, name: session, timeout: 2.0)

            try launcher.send(
                sessionName: session,
                // The expected marker is computed by the shell and is not
                // present in the echoed command line. This prevents history
                // from satisfying the assertion before zmx actually
                // delivers and executes the input.
                text: "printf 'DETACHED_RESULT_%s\\n' \"$((\(lhs) + \(rhs)))\"\r"
            )

            let history = try Self.waitForHistory(
                launcher: launcher,
                sessionName: session,
                marker: marker,
                timeout: 5.0
            )
            #expect(
                history.contains(marker),
                "zmx history did not expose input sent to detached session; got: \(history)"
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func reattachRestoresMarker() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            let state = "STATE_\(UUID().uuidString.prefix(8))"
            let output = "OUTPUT_\(UUID().uuidString.prefix(8))"

            let first = try Self.spawnHostManagedAttach(
                launcher: launcher,
                sessionName: session
            )
            var firstRunning = true
            defer {
                if firstRunning { first.terminate() }
                launcher.kill(sessionName: session)
            }
            try Self.waitForAttachReady(first)
            try first.write("stty -echo\n")
            Thread.sleep(forTimeInterval: 0.2)
            _ = first.readAvailable()

            try first.write("export ZMX_HOST_MARKER=\(state)\nprintf '\(output)\\n'\n")
            let live = Self.readUntil(marker: output, from: first, deadline: 5.0)
            #expect(live.contains(output), "marker never appeared before detach; got: \(live)")
            first.terminate()
            firstRunning = false

            try Self.waitForSession(launcher: launcher, name: session, timeout: 2.0)

            let second = try Self.spawnHostManagedAttach(
                launcher: launcher,
                sessionName: session
            )
            defer { second.terminate() }

            let replay = Self.readUntil(marker: output, from: second, deadline: 5.0)
            #expect(replay.contains(output), "reattach did not replay prior output; got: \(replay)")

            try second.write("printf 'STATE_CHECK:%s\\n' \"$ZMX_HOST_MARKER\"\n")
            let stateCheck = Self.readUntil(
                marker: "STATE_CHECK:\(state)",
                from: second,
                deadline: 5.0
            )
            #expect(
                stateCheck.contains("STATE_CHECK:\(state)"),
                "reattach did not preserve shell state; got: \(stateCheck)"
            )
        }
    }

    @Test("""
    @spec ZMX-9.5: When a snapshot-capable bundled `zmx` client attaches to a current daemon, the daemon shall send a `GHOSTSNP` binary snapshot before subsequent live PTY output. If stdout is a PTY, then the client shall disable output processing so the line discipline cannot rewrite snapshot bytes.
    """, .timeLimit(.minutes(1)))
    func reattachNegotiatesRawSnapshotTransport() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            let first = try Self.spawnHostManagedAttach(
                launcher: launcher,
                sessionName: session
            )
            var firstRunning = true
            defer {
                if firstRunning { first.terminate() }
                launcher.kill(sessionName: session)
            }

            try Self.waitForAttachReady(first)
            try first.write("printf '__SNAPSHOT_BASE_%s__\\n' READY\n")
            let base = Self.readUntil(
                marker: "__SNAPSHOT_BASE_READY__",
                from: first,
                deadline: 5.0
            )
            #expect(base.contains("__SNAPSHOT_BASE_READY__"))
            first.terminate()
            firstRunning = false
            try Self.waitForSession(launcher: launcher, name: session, timeout: 2.0)

            let snapshot = try Self.spawnSnapshotAttach(
                launcher: launcher,
                sessionName: session
            )
            defer { snapshot.terminate() }

            let output = Self.readUntil(marker: "GHOSTSNP", from: snapshot, deadline: 5.0)
            #expect(output.contains("GHOSTSNP"), "snapshot attach did not emit an envelope")

            var attributes = termios()
            #expect(tcgetattr(snapshot.masterFd, &attributes) == 0)
            #expect(attributes.c_oflag & tcflag_t(OPOST) == 0)

            try snapshot.write("printf '__SNAPSHOT_LIVE_%s__\\n' READY\n")
            let live = Self.readUntil(
                marker: "__SNAPSHOT_LIVE_READY__",
                from: snapshot,
                deadline: 5.0
            )
            #expect(live.contains("__SNAPSHOT_LIVE_READY__"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func firstSnapshotAttachStartsWithEnvelope() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            let snapshot = try Self.spawnSnapshotAttach(
                launcher: launcher,
                sessionName: session
            )
            defer {
                snapshot.terminate()
                launcher.kill(sessionName: session)
            }

            let output = Self.readUntil(marker: "GHOSTSNP", from: snapshot, deadline: 5.0)
            #expect(output.hasPrefix("GHOSTSNP"), "snapshot stream had a text prefix: \(output)")

            try snapshot.write("printf '__FIRST_SNAPSHOT_LIVE_%s__\\n' READY\n")
            let live = Self.readUntil(
                marker: "__FIRST_SNAPSHOT_LIVE_READY__",
                from: snapshot,
                deadline: 5.0
            )
            #expect(live.contains("__FIRST_SNAPSHOT_LIVE_READY__"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitKillRemovesDaemon() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            let attach = try Self.spawnHostManagedAttach(
                launcher: launcher,
                sessionName: session
            )
            defer { attach.terminate() }

            try Self.waitForSession(launcher: launcher, name: session, timeout: 5.0)
            launcher.kill(sessionName: session)
            try Self.waitForSessionRemoval(launcher: launcher, name: session, timeout: 3.0)
            #expect(!(try launcher.listSessions()).contains(session))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func inheritedZMXSessionDoesNotHijackTarget() throws {
        try Self.withScopedZmxDir { launcher in
            let leaked = launcher.sessionName(for: UUID())
            let target = launcher.sessionName(for: UUID())

            let leakedAttach = try Self.spawnHostManagedAttach(
                launcher: launcher,
                sessionName: leaked
            )
            defer {
                leakedAttach.terminate()
                launcher.kill(sessionName: leaked)
                launcher.kill(sessionName: target)
            }
            try Self.waitForSession(launcher: launcher, name: leaked, timeout: 5.0)

            var inheritedEnv = ProcessInfo.processInfo.environment
            inheritedEnv["ZMX_SESSION"] = leaked
            let targetAttach = try Self.spawnHostManagedAttach(
                launcher: launcher,
                sessionName: target,
                baseEnv: inheritedEnv
            )
            defer { targetAttach.terminate() }

            try Self.waitForSession(launcher: launcher, name: target, timeout: 5.0)
            let sessions = try launcher.listSessions()
            #expect(sessions.contains(leaked))
            #expect(
                sessions.contains(target),
                "inherited ZMX_SESSION hijacked attach away from \(target); sessions: \(sessions)"
            )
        }
    }

    // MARK: - Helpers

    static func withScopedZmxDir<T>(_ body: (ZmxLauncher) throws -> T) throws -> T {
        let zmx = try #require(
            ZmxSurvivalIntegrationTests.vendoredZmx(),
            "zmx binary not vendored — run scripts/bump-zmx.sh"
        )
        let zmxDir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("zmx-\(UUID().uuidString.prefix(8))", isDirectory: true)
        guard zmxDir.path.hasPrefix("/tmp/zmx-") else {
            Issue.record("unsafe ZMX_DIR \(zmxDir.path)")
            throw NSError(
                domain: "ZmxNativeHostManagedIntegrationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "unsafe ZMX_DIR \(zmxDir.path)"]
            )
        }

        try FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)
        let launcher = ZmxLauncher(executable: zmx, zmxDir: zmxDir)
        defer {
            if let names = try? launcher.listSessions() {
                for name in names {
                    launcher.kill(sessionName: name)
                }
            }
            try? FileManager.default.removeItem(at: zmxDir)
        }
        return try body(launcher)
    }

    static func spawnHostManagedAttach(
        launcher: ZmxLauncher,
        sessionName: String,
        baseEnv: [String: String] = ProcessInfo.processInfo.environment,
        userShell: String = "/bin/sh"
    ) throws -> PtyAttach {
        var env = launcher.subprocessEnv(from: baseEnv)
        env["SHELL"] = userShell
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"

        let spawned = try PtyProcess.spawn(
            argv: launcher.attachArgv(sessionName: sessionName, userShell: userShell),
            env: env,
            initialSize: (cols: 80, rows: 24)
        )

        let flags = fcntl(spawned.masterFD, F_GETFL)
        _ = fcntl(spawned.masterFD, F_SETFL, flags | O_NONBLOCK)

        return PtyAttach(pid: spawned.pid, masterFd: spawned.masterFD)
    }

    static func spawnSnapshotAttach(
        launcher: ZmxLauncher,
        sessionName: String,
        baseEnv: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> PtyAttach {
        var env = launcher.subprocessEnv(from: baseEnv)
        env["SHELL"] = "/bin/sh"
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"

        let spawned = try PtyProcess.spawn(
            argv: [launcher.executable.path, "attach", "--snapshot", sessionName],
            env: env,
            initialSize: (cols: 80, rows: 24)
        )

        let flags = fcntl(spawned.masterFD, F_GETFL)
        _ = fcntl(spawned.masterFD, F_SETFL, flags | O_NONBLOCK)
        return PtyAttach(pid: spawned.pid, masterFd: spawned.masterFD)
    }

    static func waitForAttachReady(_ attach: PtyAttach) throws {
        let output = readUntil(marker: "\u{001B}[2J", from: attach, deadline: 5.0)
        if !output.contains("\u{001B}[2J") {
            throw NSError(
                domain: "ZmxNativeHostManagedIntegrationTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "zmx attach did not become ready; got: \(output)"]
            )
        }
    }

    static func waitForSession(
        launcher: ZmxLauncher,
        name: String,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let sessions = try? launcher.listSessions(), sessions.contains(name) {
                return
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw NSError(
            domain: "ZmxNativeHostManagedIntegrationTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "session \(name) did not appear within \(timeout)s"]
        )
    }

    static func waitForSessionRemoval(
        launcher: ZmxLauncher,
        name: String,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let sessions = try? launcher.listSessions(), !sessions.contains(name) {
                return
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        let sessions = (try? launcher.listSessions()) ?? []
        throw NSError(
            domain: "ZmxNativeHostManagedIntegrationTests",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "session \(name) still listed after \(timeout)s; sessions: \(sessions)"]
        )
    }

    static func waitForHistory(
        launcher: ZmxLauncher,
        sessionName: String,
        marker: String,
        timeout: TimeInterval
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = ""
        while Date() < deadline {
            let result = try ZmxRunner.captureAll(
                executable: launcher.executable,
                args: ["history", sessionName],
                env: launcher.subprocessEnv(from: ProcessInfo.processInfo.environment),
                timeout: 2.0
            )
            if result.exitCode == 0 {
                latest = result.stdout
                if latest.contains(marker) {
                    return latest
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return latest
    }

    static func readUntil(
        marker: String,
        from attach: PtyAttach,
        deadline: TimeInterval
    ) -> String {
        var output = ""
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            let chunk = attach.readAvailable()
            if !chunk.isEmpty {
                output += chunk
                if output.contains(marker) { return output }
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return output
    }
}

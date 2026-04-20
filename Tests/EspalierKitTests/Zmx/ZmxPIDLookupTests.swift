import Testing
import Foundation
@testable import EspalierKit

@Suite("ZmxPIDLookup — parse session log for current shell PID")
struct ZmxPIDLookupTests {

    // The zmx daemon writes one log per session under
    // ~/Library/Application Support/Espalier/zmx/logs/<session>.log.
    // Every time zmx spawns the inner shell (first attach that creates
    // the session, or any future respawn), it emits a line shaped
    // like `[<ts>] [info] (default): pty spawned session=<name> pid=<N>`.
    //
    // We want the LAST such line so stale PIDs from earlier respawns
    // don't shadow the currently-running shell.

    @Test func returnsPIDFromSingleSpawnLine() throws {
        let log = """
        [1776448410787] [info] (default): pty spawned session=espalier-13dafaa9 pid=79730
        [1776448410787] [info] (default): daemon started session=espalier-13dafaa9 pty_fd=6
        """
        let pid = ZmxPIDLookup.shellPID(fromLogContents: log, sessionName: "espalier-13dafaa9")
        #expect(pid == 79730)
    }

    @Test func returnsLatestPIDWhenMultipleSpawnLines() throws {
        // If the session has been respawned (which zmx can do internally
        // or the user can force via kill + reattach), later pid=… lines
        // supersede earlier ones. Picking the newest avoids pointing at
        // a dead PID.
        let log = """
        [1000] [info] (default): pty spawned session=espalier-13dafaa9 pid=11111
        [2000] [info] (default): daemon exited session=espalier-13dafaa9
        [3000] [info] (default): pty spawned session=espalier-13dafaa9 pid=22222
        """
        let pid = ZmxPIDLookup.shellPID(fromLogContents: log, sessionName: "espalier-13dafaa9")
        #expect(pid == 22222)
    }

    @Test func ignoresSpawnLinesForOtherSessions() throws {
        // zmx does NOT commingle sessions in a single log file (each
        // session has its own file), but defensive matching on the
        // session name makes this robust to future format changes
        // and keeps test fixtures from accidentally false-positive
        // matching.
        let log = """
        [1000] [info] (default): pty spawned session=espalier-other pid=99999
        [2000] [info] (default): pty spawned session=espalier-13dafaa9 pid=22222
        """
        let pid = ZmxPIDLookup.shellPID(fromLogContents: log, sessionName: "espalier-13dafaa9")
        #expect(pid == 22222)
    }

    @Test func returnsNilWhenNoSpawnLines() throws {
        // Can happen legitimately: brand-new session that hasn't been
        // created yet, or a log file that was truncated by log rotation.
        // Callers handle nil as "unknown PID, skip poll this tick".
        let log = """
        [1000] [info] (default): some other message
        [2000] [info] (default): more chatter
        """
        let pid = ZmxPIDLookup.shellPID(fromLogContents: log, sessionName: "espalier-13dafaa9")
        #expect(pid == nil)
    }

    @Test func returnsNilForEmptyLog() throws {
        let pid = ZmxPIDLookup.shellPID(fromLogContents: "", sessionName: "espalier-13dafaa9")
        #expect(pid == nil)
    }

    @Test func ignoresLinesWithMalformedPIDs() throws {
        // Non-numeric pid= values (shouldn't happen, but defensive).
        let log = """
        [1000] [info] (default): pty spawned session=espalier-13dafaa9 pid=not-a-number
        """
        let pid = ZmxPIDLookup.shellPID(fromLogContents: log, sessionName: "espalier-13dafaa9")
        #expect(pid == nil)
    }

    @Test func readsPIDFromLogFileOnDisk() throws {
        // End-to-end against a real temp file — the common caller path.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmx-pid-lookup-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try """
        [123] [info] (default): pty spawned session=espalier-abcdef01 pid=4242
        """.write(to: tmp, atomically: true, encoding: .utf8)

        let pid = ZmxPIDLookup.shellPID(
            logFile: tmp,
            sessionName: "espalier-abcdef01"
        )
        #expect(pid == 4242)
    }

    @Test func returnsNilWhenLogFileMissing() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmx-does-not-exist-\(UUID().uuidString).log")
        let pid = ZmxPIDLookup.shellPID(
            logFile: tmp,
            sessionName: "espalier-anything"
        )
        #expect(pid == nil)
    }

    @Test func readsRotatedLogWhenCurrentHasNoSpawnLine() throws {
        // Regression: zmx rotates `<session>.log` → `<session>.log.old`
        // once the file reaches its size threshold (empirically ~5MB).
        // The most recent `pty spawned session=… pid=N` line can live in
        // the rotated file while the post-rotation `.log` is still too
        // fresh to contain any spawn line. Before the fix, `shellPID`
        // only consulted `.log`, so after rotation the PID lookup went
        // silent for the remaining lifetime of the session — and the
        // PID-based cwd lookup (PWD-1.1, used by the right-click "Move
        // to current worktree" menu) stopped finding a PID to query.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmx-rotation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let current = dir.appendingPathComponent("espalier-session.log")
        let rotated = dir.appendingPathComponent("espalier-session.log.old")

        try """
        [100] [info] (default): pty spawned session=espalier-session pid=4242
        [200] [info] (default): serialize terminal state
        """.write(to: rotated, atomically: true, encoding: .utf8)

        try """
        [300] [info] (default): client connected fd=8 total=1
        [400] [info] (default): sending ipc message tag=Output
        """.write(to: current, atomically: true, encoding: .utf8)

        let pid = ZmxPIDLookup.shellPID(logFile: current, sessionName: "espalier-session")
        #expect(pid == 4242)
    }

    @Test func currentLogSpawnLineWinsOverRotated() throws {
        // If the session respawned after rotation, the post-rotation
        // `.log` holds the newer spawn line. Prefer it over the stale
        // pid still sitting in `.log.old`.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmx-rotation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let current = dir.appendingPathComponent("espalier-session.log")
        let rotated = dir.appendingPathComponent("espalier-session.log.old")

        try """
        [100] [info] (default): pty spawned session=espalier-session pid=1111
        """.write(to: rotated, atomically: true, encoding: .utf8)

        try """
        [300] [info] (default): pty spawned session=espalier-session pid=2222
        """.write(to: current, atomically: true, encoding: .utf8)

        let pid = ZmxPIDLookup.shellPID(logFile: current, sessionName: "espalier-session")
        #expect(pid == 2222)
    }
}

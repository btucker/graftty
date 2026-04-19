import Testing
import Foundation
@testable import EspalierKit

// Process cwd is process-wide, so `reflectsCwdChange` mutating it races
// with `readsOwnProcessCwd` when swift-testing runs suite tests in
// parallel (intermittently green locally, flaky in CI).
@Suite("PIDCwdReader — proc_pidinfo wrapper", .serialized)
struct PIDCwdReaderTests {

    // We read /proc-equivalent state on macOS via libproc's
    // `proc_pidinfo(PROC_PIDVNODEPATHINFO)`. The most direct way to
    // test this without spawning a child is to read our OWN cwd and
    // compare against `FileManager.currentDirectoryPath`.

    @Test func readsOwnProcessCwd() throws {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let cwd = PIDCwdReader.cwd(ofPID: ownPID)
        // realpath the expected path — macOS `/tmp` is a symlink to
        // `/private/tmp`, so whichever `FileManager` and libproc
        // return need to agree under resolved form.
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        let actual = cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        #expect(actual == expected)
    }

    @Test func returnsNilForNonexistentPID() throws {
        // PID 0 is never a real process (kernel idle). Ensures the
        // wrapper returns nil on proc_pidinfo's rc=0 "not found"
        // rather than crashing or returning garbage.
        let cwd = PIDCwdReader.cwd(ofPID: 0)
        #expect(cwd == nil)
    }

    @Test func reflectsCwdChange() throws {
        // Change our own cwd and confirm the reader sees the new
        // value — locks in that we're genuinely round-tripping
        // through the kernel each call and not caching.
        let fm = FileManager.default
        let original = fm.currentDirectoryPath
        defer { _ = fm.changeCurrentDirectoryPath(original) }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pid-cwd-reader-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        #expect(fm.changeCurrentDirectoryPath(tmp.path))

        let observed = PIDCwdReader.cwd(ofPID: ProcessInfo.processInfo.processIdentifier)
        let expected = tmp.resolvingSymlinksInPath().path
        let actual = observed.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        #expect(actual == expected)
    }
}

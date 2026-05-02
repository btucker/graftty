import Testing
import Foundation
@testable import GrafttyKit

@Suite("WebSession")
struct WebSessionTests {

    @Test func attachProcessStartsInConfiguredWorktreeDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-session-cwd-\(UUID().uuidString)", isDirectory: true)
        let worktree = root.appendingPathComponent("repo/.worktrees/feature", isDirectory: true)
        let zmxDir = root.appendingPathComponent("zmx", isDirectory: true)
        let fakeZmx = root.appendingPathComponent("zmx-fake")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expectedCwds = [worktree.path, "/private\(worktree.path)"]

        try """
        #!/bin/sh
        printf 'cwd:%s\\n' "$PWD"
        sleep 1
        """.write(to: fakeZmx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeZmx.path)

        let session = WebSession(config: WebSession.Config(
            zmxExecutable: fakeZmx,
            zmxDir: zmxDir,
            sessionName: "graftty-test",
            workingDirectory: worktree
        ))
        let lock = NSLock()
        var output = Data()
        let sawCwd = DispatchSemaphore(value: 0)
        session.onPTYData = { data in
            lock.lock()
            output.append(data)
            let text = String(data: output, encoding: .utf8) ?? ""
            lock.unlock()
            if expectedCwds.contains(where: { text.contains("cwd:\($0)") }) {
                sawCwd.signal()
            }
        }
        try session.start()
        defer { session.close() }

        let result = sawCwd.wait(timeout: .now() + 3)
        lock.lock()
        let text = String(data: output, encoding: .utf8) ?? ""
        lock.unlock()
        #expect(result == .success, "expected fake zmx to start in \(expectedCwds), got output: \(text)")
    }
}

import Foundation

/// Shared fixture helpers for tests that spawn a fake `zmx` PTY child
/// process (`ZmxAttachEngineTests`, `WebSessionTests`) — both suites drive
/// the same `PtyProcess.spawn`-backed plumbing and previously carried
/// identical private copies of these three helpers.
enum PTYFixtureTestSupport {
    static func makeTempDir(prefix: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func waitForFile(_ url: URL, timeout: TimeInterval = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

import Foundation
@testable import GrafttyKit

/// Records delayed actions. Waiting observes a scheduled action, and the
/// three-second bound only reports a missing action as a test failure.
final class ManualSubprocessScheduler: @unchecked Sendable {
    struct Action: Sendable {
        let seconds: TimeInterval
        let run: @Sendable () -> Void
    }

    private let condition = NSCondition()
    private var pending: [Action] = []
    private var finishing = false

    var scheduler: SubprocessScheduler {
        SubprocessScheduler { [self] seconds, action in
            condition.lock()
            let runNow = finishing
            if !runNow { pending.append(Action(seconds: seconds, run: action)) }
            condition.signal()
            condition.unlock()
            if runNow { action() }
        }
    }

    /// Clean up owned children even if readiness fails or launch happens late.
    /// Future timeout/escalation actions also run immediately after teardown.
    func finish() {
        condition.lock()
        finishing = true
        let actions = pending
        pending.removeAll()
        condition.unlock()
        for action in actions { action.run() }
    }

    func nextAction() async -> Action? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                defer { condition.unlock() }
                let deadline = Date().addingTimeInterval(3)
                while pending.isEmpty {
                    guard condition.wait(until: deadline) else {
                        continuation.resume(returning: nil)
                        return
                    }
                }
                continuation.resume(returning: pending.removeFirst())
            }
        }
    }

    func pendingAction() -> Action? {
        condition.lock()
        defer { condition.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }
}

/// A shell blocks in a builtin FIFO read until the test sends a signal.
/// There are no sleeping grandchildren or elapsed-time exit paths.
final class SubprocessTestChild: Sendable {
    let root: URL
    private let ready: URL
    private let blocked: Int32

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-child-\(UUID())")
        ready = root.appendingPathComponent("ready")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard mkfifo(ready.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        let input = root.appendingPathComponent("input")
        guard mkfifo(input.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        blocked = open(input.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard blocked >= 0 else { throw POSIXError(.EIO) }
    }

    func arguments(ignoreTerminate: Bool = false) -> [String] {
        let trap = ignoreTerminate ? "trap '' TERM; " : ""
        return ["-c", trap + "exec 3< \"$2\"; echo $$ > \"$1\"; read -r line <&3", "sh", ready.path, root.appendingPathComponent("input").path]
    }

    func readyPID() async -> pid_t? {
        let ready = self.ready
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let fd = open(ready.path, O_RDONLY | O_NONBLOCK)
                guard fd >= 0 else { continuation.resume(returning: nil); return }
                defer { close(fd) }
                var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&event, 1, 3000) > 0, event.revents & Int16(POLLIN) != 0 else {
                    continuation.resume(returning: nil); return
                }
                var data = [UInt8](repeating: 0, count: 64)
                let count = read(fd, &data, data.count)
                let text = count > 0 ? String(decoding: data.prefix(count), as: UTF8.self) : ""
                continuation.resume(returning: pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    func finish() {
        // The child opens input before reporting ready. Release that builtin
        // read even when the timeout or SIGKILL behavior is deliberately broken.
        var newline: UInt8 = 10
        _ = write(blocked, &newline, 1)
        close(blocked)
        try? FileManager.default.removeItem(at: root)
    }
}

/// Bounds observation of child exit without supplying the exit mechanism.
/// Callers stop or unblock their own child in defer if an exit is missing.
func subprocessResult<Value: Sendable>(_ task: Task<Value, Error>) async throws -> Result<Value, Error> {
    let done = DispatchSemaphore(value: 0)
    let observer = Task {
        let result = await task.result
        done.signal()
        return result
    }
    let completed = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: done.wait(timeout: .now() + 3) == .success)
        }
    }
    guard completed else { throw SubprocessTestFailure.missingExit }
    return await observer.value
}

private enum SubprocessTestFailure: Error { case missingExit }

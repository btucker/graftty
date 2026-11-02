import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import GrafttyTunnel
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct DuplexGitRelayTests {
    @Test("@spec TEST-1.15: When the native Git relay fixture transfers objects, the test harness shall keep blocking subprocess I/O off cooperative workers and preserve the pushed objects and receiver result.", .timeLimit(.minutes(1)))
    func nativeGitPushTransfersObjectsAndReceiverResult() async throws {
        try await nativeGitFixture()
    }

    @Test("@spec TEST-1.17: When a Git relay fixture transfer fails or is cancelled, the test harness shall close its channels and stop both subprocess groups before joining the sender, and reap both subprocesses before returning.", .timeLimit(.minutes(1)), arguments: [Interruption.authorization, .cancellation, .deadline, .senderFailure])
    func interruptedTransferCleansUp(_ interruption: Interruption) async throws {
        // Cancellation belongs to this child task, not the Swift Testing caller.
        let pending = Task { try await nativeGitFixture(interruption: interruption) }
        switch interruption {
        case .cancellation:
            await #expect(throws: CancellationError.self) { try await pending.value }
        case .deadline:
            await #expect(throws: DuplexByteRelay.Failure.deadlineExceeded) { try await pending.value }
        case .authorization:
            await #expect(throws: GitFailure.rejected) { try await pending.value }
        case .senderFailure:
            await #expect(throws: GitRelayFixtureFailure.exit(1, "git")) { try await pending.value }
        }
    }

    enum Interruption: Sendable { case authorization, cancellation, deadline, senderFailure }

    private func nativeGitFixture(interruption: Interruption? = nil) async throws {
        let root = URL(fileURLWithPath: "/tmp/graftty-git-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The repository's test scripts require Python. Check before launching
        // receive-pack so a minimal build image fails instead of waiting for a
        // connector that could never start.
        _ = try await command(["python3", "--version"], root: root)
        let source = root.appendingPathComponent("source")
        let replica = root.appendingPathComponent("replica.git")
        _ = try await git(["init", "--initial-branch=main", source.path], root: root)
        _ = try await git(["init", "--bare", replica.path], root: root)
        // Poorly compressible content forces many pipe and network reads.
        var random: UInt32 = 0x12345678
        let payload = Data((0..<(2 * 1024 * 1024)).map { _ in
            random ^= random << 13; random ^= random >> 17; random ^= random << 5
            return UInt8(truncatingIfNeeded: random)
        })
        try payload.write(to: source.appendingPathComponent("payload.bin"))
        _ = try await git(["-C", source.path, "add", "payload.bin"], root: root)
        _ = try await git(["-C", source.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                     "-c", "commit.gpgsign=false", "commit", "-m", "fixture"], root: root)

        // Git's existing remote-ext transport connects to the relay. This fixture
        // adapter only joins stdio to a Unix socket; Git owns the pack protocol.
        let helper = root.appendingPathComponent("connect.py")
        try """
        import socket, sys, threading
        peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        peer.connect(sys.argv[1])
        def upload():
            while True:
                chunk = sys.stdin.buffer.read1(65536)
                if not chunk: break
                peer.sendall(chunk)
            peer.shutdown(socket.SHUT_WR)
        threading.Thread(target=upload, daemon=True).start()
        while True:
            chunk = peer.recv(65536)
            if not chunk: break
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
        """.write(to: helper, atomically: true, encoding: .utf8)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            try await transfer(group: group, root: root, source: source, replica: replica, helper: helper, interruption: interruption)
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        let expected = try await git(["-C", source.path, "rev-parse", "HEAD"], root: root)
        #expect(try await git(["--git-dir", replica.path, "rev-parse", "refs/heads/main"], root: root) == expected)
        #expect(try await git(["--git-dir", replica.path, "cat-file", "blob", "refs/heads/main:payload.bin"], root: root) == payload)
        _ = try await git(["--git-dir", replica.path, "fsck", "--strict"], root: root)
    }

    @Test("@spec TEST-1.16: When a Git relay fixture command is cancelled, the test harness shall stop its subprocess and close its output before returning cancellation.", .timeLimit(.minutes(1)))
    func cancellationStopsBlockedCommand() async throws {
        let root = URL(fileURLWithPath: "/tmp/graftty-git-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        #expect(mkfifo(ready.path, 0o600) == 0)
        let blocked = root.appendingPathComponent("blocked")
        #expect(mkfifo(blocked.path, 0o600) == 0)
        let gate = open(blocked.path, O_RDWR | O_NONBLOCK)
        defer { close(gate) }
        let process = GitRelayFixtureProcess(["sh", "-c",
            "trap '' TERM; sh -c 'echo $$ > \"$1\"; read line < \"$2\"' child \"$1\" \"$2\" & wait",
            "fixture", ready.path, blocked.path], root: root)
        let outputDescriptor = process.output.fileHandleForReading.fileDescriptor
        let watchdogFired = DispatchSemaphore(value: 0)
        let watchdog = DispatchWorkItem { watchdogFired.signal(); process.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        let pending = Task { try await process.result() }
        defer {
            watchdog.cancel()
            pending.cancel()
            process.stop()
        }
        let pid: Int32 = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let fd = open(ready.path, O_RDONLY | O_NONBLOCK)
                defer { close(fd) }
                var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&event, 1, 3000) > 0 else {
                    continuation.resume(throwing: GitFailure.connectionTimedOut)
                    return
                }
                var bytes = [UInt8](repeating: 0, count: 64)
                let count = read(fd, &bytes, bytes.count)
                let text = String(decoding: bytes.prefix(max(0, count)), as: UTF8.self)
                guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    continuation.resume(throwing: GitFailure.connectionTimedOut)
                    return
                }
                continuation.resume(returning: pid)
            }
        }
        let leader = try #require(process.processID)
        #expect(pid != leader)
        #expect(getpgid(pid) == leader)
        pending.cancel()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        // A surviving descendant would keep stdout open and require the watchdog.
        #expect(watchdogFired.wait(timeout: .now()) == .timedOut)
        #expect(kill(leader, 0) == -1 && errno == ESRCH)
        #expect(fcntl(outputDescriptor, F_GETFD) == -1 && errno == EBADF)
    }

    private func transfer(group: MultiThreadedEventLoopGroup, root: URL, source: URL, replica: URL, helper: URL,
                          interruption: Interruption?) async throws {
        let socket = root.appendingPathComponent("git.sock").path
        let connected = PendingConnection(loop: group.next())
        let connectionDeadline = group.next().scheduleTask(in: .seconds(5)) {
            connected.complete(.failure(GitFailure.connectionTimedOut))
        }
        defer { connectionDeadline.cancel() }
        let listener = try await ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 32 * 1024))
            .childChannelInitializer { channel in
                DuplexByteRelay.prepare(channel).map { connected.complete(.success($0)) }.flatMapErrorThrowing {
                    connected.complete(.failure($0))
                    throw $0
                }
            }.bind(unixDomainSocketPath: socket).get()
        let receiver = GitRelayFixtureProcess(["git", "receive-pack", replica.path], root: root, duplex: true)
        let sender = GitRelayFixtureProcess(interruption == .senderFailure ? ["git", "invalid-fixture-command"] :
            ["git", "-C", source.path, "-c", "protocol.ext.allow=always", "push", "--porcelain",
             "ext::python3 \(helper.path) \(socket)", "HEAD:refs/heads/main"], root: root)
        var pipe: Channel?
        var sending: Task<Data, any Error>?
        let result: Result<Void, any Error>
        do {
            try await withTaskCancellationHandler {
                try await relayFixtureIO { try receiver.start() }
                let (reader, writer) = try await relayFixtureIO { try receiver.relayDescriptors() }
                let prepared = group.next().makePromise(of: DuplexByteRelay.Endpoint.self)
                pipe = try await NIOPipeBootstrap(group: group)
                    .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 32 * 1024))
                    .channelInitializer { channel in
                        let ready = DuplexByteRelay.prepare(channel)
                        ready.cascade(to: prepared)
                        return ready.map { _ in }
                    }.takingOwnershipOfDescriptors(input: reader, output: writer).get()
                let parent = try await prepared.futureResult.get()
                let task = Task {
                    do { return try await sender.result() }
                    catch {
                        connected.complete(.failure(error))
                        throw error
                    }
                }
                sending = task
                let worker = try await connected.promise.futureResult.get()
                connectionDeadline.cancel()
                if interruption == .cancellation { withUnsafeCurrentTask { $0?.cancel() } }
                try await DuplexByteRelay.run(worker, parent,
                    deadline: interruption == .deadline ? .now : .now.advanced(by: .seconds(20)),
                    authorize: { if interruption == .authorization { throw GitFailure.rejected } })
                let data = try await task.value
                #expect(String(decoding: data, as: UTF8.self).contains("[new branch]"))
                let status = try await relayFixtureIO { try receiver.wait() }
                #expect(status == 0)
            } onCancel: {
                connected.stop()
                DispatchQueue.global().async {
                    receiver.stop()
                    sender.stop()
                }
            }
            result = .success(())
        } catch {
            result = .failure(error)
        }
        // Stop producers and close NIO's duplicate descriptors before joining.
        // This also covers failures before connection establishment or pipe setup.
        connected.stop()
        pipe?.close(promise: nil)
        listener.close(promise: nil)
        try await relayFixtureIO {
            receiver.stop()
            sender.stop()
        }
        if let pipe { try? await pipe.closeFuture.get() }
        try? await listener.closeFuture.get()
        if let sending { _ = await sending.result }
        _ = try await relayFixtureIO { try receiver.wait() }
        if let pid = receiver.processID { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
        if let pid = sender.processID { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
        #expect(pipe?.isActive != true)
        #expect(!listener.isActive)
        try result.get()
    }
}

private func git(_ arguments: [String], root: URL) async throws -> Data {
    try await command(["git"] + arguments, root: root)
}

private func command(_ arguments: [String], root: URL) async throws -> Data {
    try await GitRelayFixtureProcess(arguments, root: root).result()
}

private enum GitFailure: Error { case connectionTimedOut, rejected }

private final class PendingConnection: @unchecked Sendable {
    let promise: EventLoopPromise<DuplexByteRelay.Endpoint>
    private let lock = NSLock()
    private var completed = false
    private var endpoint: DuplexByteRelay.Endpoint?
    init(loop: EventLoop) { promise = loop.makePromise() }
    func stop() {
        complete(.failure(CancellationError()))
        lock.withLock { endpoint }?.channel.close(promise: nil)
    }
    func complete(_ result: Result<DuplexByteRelay.Endpoint, any Error>) {
        let accepted = lock.withLock {
            guard !completed else { return false }
            completed = true
            if case .success(let endpoint) = result { self.endpoint = endpoint }
            return true
        }
        if accepted { promise.completeWith(result) }
        else if case .success(let endpoint) = result { endpoint.channel.close(promise: nil) }
    }
}

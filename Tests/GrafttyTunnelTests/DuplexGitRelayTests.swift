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
    @Test(.timeLimit(.minutes(1)))
    func nativeGitPushTransfersObjectsAndReceiverResult() async throws {
        let root = URL(fileURLWithPath: "/tmp/graftty-git-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let replica = root.appendingPathComponent("replica.git")
        _ = try git(["init", "--initial-branch=main", source.path], root: root)
        _ = try git(["init", "--bare", replica.path], root: root)
        // Poorly compressible content forces many pipe and network reads.
        var random: UInt32 = 0x12345678
        let payload = Data((0..<(2 * 1024 * 1024)).map { _ in
            random ^= random << 13; random ^= random >> 17; random ^= random << 5
            return UInt8(truncatingIfNeeded: random)
        })
        try payload.write(to: source.appendingPathComponent("payload.bin"))
        _ = try git(["-C", source.path, "add", "payload.bin"], root: root)
        _ = try git(["-C", source.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
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
            try await transfer(group: group, root: root, source: source, replica: replica, helper: helper)
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        let expected = try git(["-C", source.path, "rev-parse", "HEAD"], root: root)
        #expect(try git(["--git-dir", replica.path, "rev-parse", "refs/heads/main"], root: root) == expected)
        #expect(try git(["--git-dir", replica.path, "cat-file", "blob", "refs/heads/main:payload.bin"], root: root) == payload)
        _ = try git(["--git-dir", replica.path, "fsck", "--strict"], root: root)
    }

    private func transfer(group: MultiThreadedEventLoopGroup, root: URL, source: URL, replica: URL, helper: URL) async throws {
        let socket = root.appendingPathComponent("git.sock").path
        let connected = group.next().makePromise(of: DuplexByteRelay.Endpoint.self)
        let listener = try await ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 32 * 1024))
            .childChannelInitializer { channel in
                DuplexByteRelay.prepare(channel).map { connected.succeed($0) }
            }.bind(unixDomainSocketPath: socket).get()
        defer { listener.close(promise: nil) }
        let receiver = Process()
        receiver.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        receiver.arguments = ["git", "receive-pack", replica.path]
        receiver.environment = environment(root: root)
        let input = Pipe(), output = Pipe()
        receiver.standardInput = input
        receiver.standardOutput = output
        receiver.standardError = FileHandle.nullDevice
        try receiver.run()
        defer {
            if receiver.isRunning { receiver.terminate() }
            receiver.waitUntilExit()
        }
        let reader = fcntl(output.fileHandleForReading.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard reader >= 0 else { throw POSIXError(.EBADF) }
        let writer = fcntl(input.fileHandleForWriting.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard writer >= 0 else { close(reader); throw POSIXError(.EBADF) }
        // Only NIO owns the duplicate pipe ends. Keeping the original input open
        // would prevent receive-pack from observing forwarded EOF.
        try output.fileHandleForReading.close()
        try input.fileHandleForWriting.close()
        let prepared = group.next().makePromise(of: DuplexByteRelay.Endpoint.self)
        let pipe = try await NIOPipeBootstrap(group: group)
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 32 * 1024))
            .channelInitializer { channel in
                DuplexByteRelay.prepare(channel).map { prepared.succeed($0) }
            }.takingOwnershipOfDescriptors(input: reader, output: writer).get()
        defer { pipe.close(promise: nil) }
        let parent = try await prepared.futureResult.get()
        let sender = Task.detached {
            try git(["-C", source.path, "-c", "protocol.ext.allow=always", "push", "--porcelain",
                     "ext::python3 \(helper.path) \(socket)", "HEAD:refs/heads/main"], root: root)
        }
        let worker = try await connected.futureResult.get()
        do {
            try await DuplexByteRelay.run(worker, parent, deadline: .now.advanced(by: .seconds(20)), authorize: {})
            let result = try await sender.value
            #expect(String(decoding: result, as: UTF8.self).contains("[new branch]"))
            receiver.waitUntilExit()
            #expect(receiver.terminationStatus == 0)
            try await listener.close().get()
        } catch {
            worker.channel.close(promise: nil)
            pipe.close(promise: nil)
            _ = try? await sender.value
            throw error
        }
    }
}

private func environment(root: URL) -> [String: String] {
    ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": root.path,
     "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
}

private func git(_ arguments: [String], root: URL) throws -> Data {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.environment = environment(root: root)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw GitFailure.exit(process.terminationStatus) }
    return data
}

private enum GitFailure: Error { case exit(Int32) }

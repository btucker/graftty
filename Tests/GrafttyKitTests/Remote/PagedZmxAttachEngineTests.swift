import Foundation
import Darwin
import Testing
import GrafttyProtocol
@testable import GrafttyKit

struct PagedZmxAttachEngineTests {
    @Test("@spec TERM-12.11: When a mobile client requests paged attachment, the application shall negotiate support before accepting a bounded current-screen checkpoint and keep live output separate from requested history.")
    func wireSeparatesCheckpointLiveAndHistory() throws {
        var ready = Data()
        ready.appendLE(UInt64(9)); ready.appendLE(UInt64(7))
        ready.appendLE(UInt16(80)); ready.appendLE(UInt16(24))
        ready.append(contentsOf: [1, 0, 0, 0]); ready.append(Data("GHOSTSNP".utf8))
        guard case .checkpoint(let checkpoint) = try PagedZmxWire.event(tag: 27, payload: ready) else {
            Issue.record("Missing checkpoint"); return
        }
        #expect(checkpoint.hasPrimaryHistory)
        #expect(checkpoint.cols == 80)
        #expect(try PagedZmxWire.event(tag: 1, payload: Data("live".utf8)) == .output(Data("live".utf8)))
        let request = PagedTerminalHistoryRequest(incarnation: 9, checkpointID: 7, requestID: 2, ordinal: 0, screen: 0)
        var page = PagedZmxWire.history(request)
        page.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0]); page.append(Data([4, 5]))
        guard case .page(let result) = try PagedZmxWire.event(tag: 29, payload: page) else {
            Issue.record("Missing page"); return
        }
        #expect(result.request == request)
        #expect(result.complete)
        #expect(result.data == Data([4, 5]))
    }

    @Test func frozenHeaderAndCapabilityNegotiation() throws {
        let frame = PagedZmxWire.frame(tag: 26, payload: Data([42]))
        #expect(frame == Data([26, 1, 0, 0, 0, 0, 0, 0, 42]))
        #expect(!PagedZmxWire.supportsPaging(Data([3, 0, 0, 0, 0, 0, 0, 0])))
        #expect(PagedZmxWire.supportsPaging(Data([8, 0, 0, 0, 0, 0, 0, 0])))
        #expect(try PagedZmxWire.event(tag: 3, payload: Data()) == nil)
        #expect(try PagedZmxWire.event(tag: 32, payload: Data([7, 0, 0, 0])) == .ended(7))
        #expect(throws: PagedZmxAttachEngine.Error.self) { try PagedZmxWire.event(tag: 27, payload: Data()) }
        #expect(throws: PagedZmxAttachEngine.Error.self) {
            try PagedZmxWire.event(tag: 29, payload: Data(repeating: 0, count: PagedTerminalLimits.pageBytes + 49))
        }
    }
}

private final class FakePagedDaemon: @unchecked Sendable {
    let directory: URL
    let descriptor: Int32
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var failure: String?
    var error: String? { lock.withLock { failure } }

    init(body: @escaping @Sendable (Int32) throws -> Void) throws {
        directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("paged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PagedZmxAttachEngine.Error.socket(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(directory.appendingPathComponent("session").path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, listen(descriptor, 1) == 0 else { throw PagedZmxAttachEngine.Error.socket(errno) }
        let fd = descriptor
        Thread.detachNewThread { [self] in
            defer { done.signal() }
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
            do { try body(client) }
            catch { lock.withLock { failure = String(describing: error) } }
        }
    }
    func finish() {
        _ = shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        _ = done.wait(timeout: .now() + 4)
        try? FileManager.default.removeItem(at: directory)
    }
    func waitUntilDone() async -> Bool {
        await withCheckedContinuation { result in
            DispatchQueue.global().async { [self] in
                let completed = done.wait(timeout: .now() + 5) == .success
                if completed { done.signal() }
                result.resume(returning: completed)
            }
        }
    }
    static func send(_ fd: Int32, tag: UInt8, payload: Data) throws {
        let bytes = PagedZmxWire.frame(tag: tag, payload: payload)
        try bytes.withUnsafeBytes { try SocketIO.writeAll(fd: fd, bytes: $0.bindMemory(to: UInt8.self).baseAddress!, count: bytes.count) }
    }
    static func receive(_ fd: Int32) throws -> (UInt8, Data) {
        let header = try read(fd, count: 8)
        let count = (0..<4).reduce(0) { $0 | Int(header[$1 + 1]) << ($1 * 8) }
        guard count <= 1024 * 1024 else { throw PagedZmxAttachEngine.Error.invalidFrame }
        return (header[0], try read(fd, count: count))
    }
    static func read(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            guard n > 0 else { throw PagedZmxAttachEngine.Error.closed }
            offset += n
        }
        return data
    }

    static func negotiate(_ fd: Int32) throws {
        try send(fd, tag: 23, payload: Data([8, 0, 0, 0, 0, 0, 0, 0]))
        #expect(try receive(fd).0 == 23)
        let (tag, codec) = try receive(fd)
        #expect(tag == 26)
        #expect(String(decoding: codec, as: UTF8.self) == PagedTerminalLimits.codec)
        var ready = Data()
        ready.appendLE(UInt64(9)); ready.appendLE(UInt64(7))
        ready.appendLE(UInt16(80)); ready.appendLE(UInt16(24))
        ready.append(contentsOf: [1, 0, 0, 0]); ready.append(Data("GHOSTSNP".utf8))
        try send(fd, tag: 27, payload: ready)
    }
}

extension PagedZmxAttachEngineTests {
    @Test("@spec TERM-12.15: When zmx requests a paged client's size after transferring leadership, the application shall resend its latest explicitly requested grid without resizing a passive attachment.")
    func leadershipResizeRequestUsesLatestRequestedGrid() async throws {
        let request = PagedTerminalHistoryRequest(incarnation: 9, checkpointID: 7, requestID: 1, ordinal: 0, screen: 0)
        let daemon = try FakePagedDaemon { fd in
            try FakePagedDaemon.negotiate(fd)
            // A passive attachment has no requested owner grid to send.
            try FakePagedDaemon.send(fd, tag: 2, payload: Data())
            try FakePagedDaemon.send(fd, tag: 1, payload: Data("passive".utf8))
            #expect(try FakePagedDaemon.receive(fd).0 == 28)
            // zmx ignores these resizes while another client is its leader.
            #expect(try FakePagedDaemon.receive(fd).1 == Data([30, 0, 100, 0]))
            #expect(try FakePagedDaemon.receive(fd).1 == Data([40, 0, 120, 0]))
            #expect(try FakePagedDaemon.receive(fd).0 == 0)
            try FakePagedDaemon.send(fd, tag: 2, payload: Data())
            let reply = try FakePagedDaemon.receive(fd)
            #expect(reply.0 == 2)
            #expect(reply.1 == Data([40, 0, 120, 0]))
            try FakePagedDaemon.send(fd, tag: 1, payload: Data("resized".utf8))
        }
        defer { daemon.finish() }
        let engine = PagedZmxAttachEngine(config: .init(zmxExecutable: URL(fileURLWithPath: "/unused"), zmxDir: daemon.directory, sessionName: "session"))
        defer { engine.close() }
        try await engine.start()
        var iterator = engine.events.makeAsyncIterator()
        _ = await iterator.next()
        #expect(await iterator.next() == .output(Data("passive".utf8)))
        try await engine.requestHistory(request)
        engine.resize(cols: UInt16(100), rows: UInt16(30))
        engine.resize(cols: UInt16(120), rows: UInt16(40))
        try await engine.send(Data("a".utf8))
        #expect(await iterator.next() == .output(Data("resized".utf8)))
        #expect(daemon.error == nil)
    }

    @Test("@spec TERM-12.19: When a paged attachment receives repeated requests for the same grid, the application shall send one resize until the grid changes, while still answering explicit daemon size requests.")
    func repeatedGridDoesNotEchoDaemonResize() async throws {
        let daemon = try FakePagedDaemon { fd in
            try FakePagedDaemon.negotiate(fd)
            #expect(try FakePagedDaemon.receive(fd).0 == 2)
            try FakePagedDaemon.send(fd, tag: 31, payload: Data([30, 0, 100, 0]))
            // The next frame must be the history request, not a resize echo.
            #expect(try FakePagedDaemon.receive(fd).0 == 28)
            try FakePagedDaemon.send(fd, tag: 2, payload: Data())
            let reply = try FakePagedDaemon.receive(fd)
            #expect(reply.0 == 2)
            #expect(reply.1 == Data([30, 0, 100, 0]))
        }
        defer { daemon.finish() }
        let engine = PagedZmxAttachEngine(config: .init(zmxExecutable: URL(fileURLWithPath: "/unused"), zmxDir: daemon.directory, sessionName: "session"))
        defer { engine.close() }
        try await engine.start()
        var iterator = engine.events.makeAsyncIterator()
        _ = await iterator.next()
        engine.resize(cols: UInt16(100), rows: UInt16(30))
        #expect(await iterator.next() == .grid(cols: 100, rows: 30))
        engine.resize(cols: UInt16(100), rows: UInt16(30))
        try await engine.requestHistory(.init(incarnation: 9, checkpointID: 7, requestID: 1, ordinal: 0, screen: 0))
        #expect(await daemon.waitUntilDone())
        #expect(daemon.error == nil)
    }

    @Test("@spec TERM-12.16: If a paged terminal socket write fails after sending part of an IPC frame, then the application shall close that attachment before sending another frame.")
    func partialFrameWriteFailureClosesAttachment() async throws {
        let sendFinished = DispatchSemaphore(value: 0)
        let payload = Data(repeating: 0x61, count: 2 * 1024 * 1024)
        let daemon = try FakePagedDaemon { fd in
            try FakePagedDaemon.negotiate(fd)
            // Hold back reads until SO_SNDTIMEO interrupts the large frame.
            #expect(sendFinished.wait(timeout: .now() + 15) == .success)
            var bytesRead = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count == 0 { break }
                guard count > 0 else { throw PagedZmxAttachEngine.Error.socket(errno) }
                bytesRead += count
            }
            #expect(bytesRead > 8)
            #expect(bytesRead < payload.count + 8)
        }
        defer { daemon.finish() }
        let engine = PagedZmxAttachEngine(config: .init(zmxExecutable: URL(fileURLWithPath: "/unused"), zmxDir: daemon.directory, sessionName: "session"))
        defer { engine.close() }
        try await engine.start()
        var iterator = engine.events.makeAsyncIterator()
        _ = await iterator.next()
        do {
            try await engine.send(payload)
            Issue.record("Expected a partial frame write timeout")
        } catch SocketIO.WriteError.writeFailed(let code) {
            #expect(code == EAGAIN || code == EWOULDBLOCK)
        }
        sendFinished.signal()
        // Wait for the peer's drain to prove the engine sent EOF, not just a
        // receive-stream completion while leaving the framed socket writable.
        #expect(await daemon.waitUntilDone())
        #expect(daemon.error == nil)
        #expect(await iterator.next() == nil)
        do {
            try await engine.send(Data("next".utf8))
            Issue.record("Closed framed transport accepted another write")
        } catch PagedZmxAttachEngine.Error.closed { }
    }

    @Test func oldDaemonRejectedBeforePagedAttach() async throws {
        let daemon = try FakePagedDaemon { fd in
            try FakePagedDaemon.send(fd, tag: 23, payload: Data([3, 0, 0, 0, 0, 0, 0, 0]))
            let (tag, _) = try FakePagedDaemon.receive(fd)
            #expect(tag == 23)
            var byte: UInt8 = 0
            #expect(Darwin.read(fd, &byte, 1) == 0)
        }
        defer { daemon.finish() }
        let engine = PagedZmxAttachEngine(config: .init(zmxExecutable: URL(fileURLWithPath: "/unused"), zmxDir: daemon.directory, sessionName: "session"))
        do { try await engine.start(); Issue.record("Old daemon unexpectedly accepted") }
        catch PagedZmxAttachEngine.Error.unsupported { }
        await engine.close()
    }

    @Test func socketEngineDeliversReadyLiveAndRequestedPage() async throws {
        let request = PagedTerminalHistoryRequest(incarnation: 9, checkpointID: 7, requestID: 1, ordinal: 0, screen: 0)
        let daemon = try FakePagedDaemon { fd in
            try FakePagedDaemon.send(fd, tag: 23, payload: Data([8, 0, 0, 0, 0, 0, 0, 0]))
            #expect(try FakePagedDaemon.receive(fd).0 == 23)
            let (tag, codec) = try FakePagedDaemon.receive(fd)
            #expect(tag == 26)
            #expect(String(decoding: codec, as: UTF8.self) == PagedTerminalLimits.codec)
            var ready = Data()
            ready.appendLE(UInt64(9)); ready.appendLE(UInt64(7))
            ready.appendLE(UInt16(80)); ready.appendLE(UInt16(24))
            ready.append(contentsOf: [1, 0, 0, 0]); ready.append(Data("GHOSTSNP".utf8))
            try FakePagedDaemon.send(fd, tag: 27, payload: ready)
            try FakePagedDaemon.send(fd, tag: 1, payload: Data("live".utf8))
            try FakePagedDaemon.send(fd, tag: 31, payload: Data([30, 0, 100, 0]))
            try FakePagedDaemon.send(fd, tag: 1, payload: Data("after-resize".utf8))
            let history = try FakePagedDaemon.receive(fd)
            #expect(history.0 == 28)
            #expect(history.1 == PagedZmxWire.history(request))
            var page = history.1
            page.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0]); page.append(Data([42]))
            try FakePagedDaemon.send(fd, tag: 29, payload: page)
        }
        defer { daemon.finish() }
        let engine = PagedZmxAttachEngine(config: .init(zmxExecutable: URL(fileURLWithPath: "/unused"), zmxDir: daemon.directory, sessionName: "session"))
        try await engine.start()
        var iterator = engine.events.makeAsyncIterator()
        guard case .checkpoint(let checkpoint) = await iterator.next() else { Issue.record("No checkpoint"); return }
        #expect(checkpoint.cols == 80)
        #expect(await iterator.next() == .output(Data("live".utf8)))
        #expect(await iterator.next() == .grid(cols: 100, rows: 30))
        #expect(await iterator.next() == .output(Data("after-resize".utf8)))
        try await engine.requestHistory(request)
        guard case .page(let page) = await iterator.next() else { Issue.record("No page"); return }
        #expect(page.request == request)
        #expect(page.data == Data([42]))
        await engine.close()
        #expect(daemon.error == nil)
    }
}

import CryptoKit
import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing
@testable import GrafttyRemoteClient

@Suite("SSH terminal backpressure over encrypted channels", .timeLimit(.minutes(1)))
struct SSHTerminalBackpressureTests {
    enum AttachmentAbort: CaseIterable, Sendable { case close, cancellation }
    enum AttachmentPhase: CaseIterable, Sendable, Equatable { case childConfirmation, shellFactory }

    @Test("@spec REMOTE-9.15: When an SSH terminal attachment closes or is canceled before shell acknowledgement, the application shall fail the pending connection and close its child channel without disconnecting the shared transport.", arguments: AttachmentAbort.allCases, AttachmentPhase.allCases)
    func attachmentAbortCompletesBeforeShellAcknowledgement(abort: AttachmentAbort, phase: AttachmentPhase) async throws {
        let fixture = try await SSHBackpressureFixture.make(stalling: phase)
        do {
            switch abort {
            case .close: fixture.client.close()
            case .cancellation: fixture.cancelConnection()
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while (fixture.probe.connection.value == nil || (phase == .shellFactory && !fixture.probe.childClosed)),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            // Inspect before releasing the factory. Releasing it during cleanup
            // lets the old acknowledgement-only implementation finish safely.
            #expect(fixture.probe.connection.value != nil)
            if phase == .shellFactory { #expect(fixture.probe.childClosed) }
            #expect(fixture.clientParent.isActive)
            #expect(fixture.serverParent.isActive)
            fixture.releaseAttach()
            try await fixture.wait(for: "aborted connection completion") {
                fixture.probe.connection.value != nil
            }
            switch try #require(fixture.probe.connection.value) {
            case .success: Issue.record("An aborted terminal attachment connected successfully")
            case .failure(let error):
                if case .cancellation = abort { #expect(error is CancellationError) }
            }
            fixture.client.close()
            // Before OPEN_CONFIRMATION, the client cannot address the server's
            // channel ID. The late confirmed child must close after release.
            try await fixture.wait(for: "aborted server child cleanup") { fixture.probe.childClosed }
            if phase == .shellFactory {
                try await fixture.wait(for: "deferred factory cleanup") { fixture.stream.wasClosed }
            }
            #expect(fixture.clientParent.isActive)
            #expect(fixture.serverParent.isActive)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    // MARK: - Slow-consumer probes (bounded numeric reports only)

    /// Paused consumer with sibling traffic. Measures the terminal's disposition
    /// without asserting a pacing mechanism, so it can run on any revision.
    private static let probesEnabled = ProcessInfo.processInfo.environment["GRAFTTY_TERMINAL_FLOW_PROBES"] != nil

    @Test(.enabled(if: probesEnabled), .timeLimit(.minutes(2)))
    func probePausedConsumer() async throws {
        let total = 32 * 1024 * 1024
        let fixture = try await SSHBackpressureFixture.make(sibling: true)
        do {
            let producer = fixture.stream.produce(total: total)
            defer { producer.cancel() }
            // Pause: nothing reads the primary terminal for this window.
            var peakBuffered = 0
            var echoes: [Double] = []
            let start = ContinuousClock.now
            while start.duration(to: .now) < .seconds(4), !fixture.probe.childClosed {
                peakBuffered = max(peakBuffered, fixture.client.bufferedByteCountForTesting)
                echoes.append(try await fixture.siblingEcho())
            }
            let disconnected = fixture.probe.childClosed
            let pushedWhilePaused = fixture.stream.pushedBytes
            var report = ProbeReport(
                scenario: "pausedConsumer", disconnected: disconnected,
                producerBytesWhilePaused: pushedWhilePaused, peakReceiveBufferBytes: peakBuffered,
                siblingEchoP95Milliseconds: percentile(echoes, 0.95), siblingEchoSamples: echoes.count
            )
            if !disconnected {
                // Resume. Every byte must arrive once, in order.
                report.deliveredIntact = try await fixture.drainPrimary(expected: total)
                report.disconnectedAfterResume = fixture.probe.childClosed
            }
            print("[terminal-flow] \(try report.json())")
            #expect(fixture.clientParent.isActive)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    /// Slow consumer. Reports how many VT bytes precede a control frame the
    /// host sends after the slow consumer has built its largest backlog.
    @Test(.enabled(if: probesEnabled), .timeLimit(.minutes(2)))
    func probeControlLagBehindOutput() async throws {
        let fixture = try await SSHBackpressureFixture.make(sibling: true)
        do {
            await fixture.client.sendHello(clientID: DisplayClientID("primary"), kind: .ios, role: .interactive, visible: true, cols: 80, rows: 24)
            try await fixture.expectControlFrame()
            let total = 64 * 1024 * 1024
            let producer = fixture.stream.produce(total: total)
            defer { producer.cancel() }
            // Consumer stays paused until the source stops advancing or overflow.
            try await fixture.waitForSourceToStop()
            let last = fixture.stream.pushedBytes
            let buffered = fixture.client.bufferedByteCountForTesting
            let disconnected = fixture.probe.childClosed
            var lag: Int?
            var deliveredBeforeControl = 0
            if !disconnected {
                // Ownership changes while the primary's output is blocked.
                await fixture.sibling.sendHello(clientID: DisplayClientID("sibling"), kind: .ios, role: .interactive, visible: true, cols: 80, rows: 24)
                await fixture.sibling.takeControl(clientID: DisplayClientID("sibling"), kind: .ios, cols: 90, rows: 30)
                reading: while true {
                    switch try await fixture.client.receive() {
                    case .binary(let bytes): deliveredBeforeControl += bytes.count
                    case .paged: throw PagedTerminalEnvelope.Error.invalid
                    case .text(let text):
                        // The host rewrites client IDs, so identify the takeover by its grid.
                        if case .ownership(let snapshot)? = try? WebControlEnvelope.parse(Data(text.utf8)),
                           snapshot.grid.cols == 90 { lag = deliveredBeforeControl; break reading }
                    }
                    if deliveredBeforeControl > total { break }
                }
            }
            print("[terminal-flow] \(try ProbeReport(scenario: "controlLag", disconnected: disconnected, producerBytesWhilePaused: last, peakReceiveBufferBytes: buffered, siblingEchoP95Milliseconds: nil, siblingEchoSamples: 0, controlLagBytes: lag).json())")
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    /// Adds RTT inside the harness, then reports a keeping-up consumer's rate,
    /// and how late a takeover reaches a consumer limited to `consumerRate`.
    /// SCTP retransmits lost packets, so at this layer loss appears as delay.
    @Test(.enabled(if: probesEnabled), .timeLimit(.minutes(3)), arguments: [true, false], [0, 25, 100])
    func probeDelayedLink(negotiated: Bool, oneWayMilliseconds: Int) async throws {
        try await measureDelayedLink(windowBytes: negotiated ? TerminalOutputCredit.clientWindowBytes : nil,
                                     oneWayMilliseconds: oneWayMilliseconds)
    }

    @Test(.enabled(if: probesEnabled), .timeLimit(.minutes(3)), arguments: [128, 256, 1024], [0, 25, 100])
    func probeWindowTradeoff(kibibytes: Int, oneWayMilliseconds: Int) async throws {
        try await measureDelayedLink(windowBytes: kibibytes * 1024, oneWayMilliseconds: oneWayMilliseconds)
    }

    private func measureDelayedLink(windowBytes: Int?, oneWayMilliseconds: Int) async throws {
        let fixture = try await SSHBackpressureFixture.make(
            sibling: true, negotiatesOutputWindow: windowBytes != nil, oneWayDelay: .milliseconds(oneWayMilliseconds),
            windowBytes: windowBytes ?? TerminalOutputCredit.clientWindowBytes
        )
        do {
            await fixture.client.sendHello(clientID: DisplayClientID("primary"), kind: .ios, role: .interactive, visible: true, cols: 80, rows: 24)
            try await fixture.expectControlFrame()
            let keepingUp = 8 * 1024 * 1024
            let throughputStart = ContinuousClock.now
            let producer = fixture.stream.produce(total: keepingUp)
            #expect(try await fixture.drainPrimary(expected: keepingUp))
            await producer.value
            let elapsed = throughputStart.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18

            // Slow consumer: a backlog first, then a takeover behind it.
            let consumerRate = 2 * 1024 * 1024
            let slow = fixture.stream.produce(total: 32 * 1024 * 1024, startingAt: keepingUp)
            defer { slow.cancel() }
            try await fixture.waitForSourceToStop()
            let takeoverStart = ContinuousClock.now
            await fixture.sibling.sendHello(clientID: DisplayClientID("sibling"), kind: .ios, role: .interactive, visible: true, cols: 80, rows: 24)
            await fixture.sibling.takeControl(clientID: DisplayClientID("sibling"), kind: .ios, cols: 90, rows: 30)
            var ahead = 0
            reading: while true {
                switch try await fixture.client.receive() {
                case .binary(let bytes):
                    ahead += bytes.count
                    try await Task.sleep(for: .seconds(Double(bytes.count) / Double(consumerRate)))
                case .paged: throw PagedTerminalEnvelope.Error.invalid
                case .text(let text):
                    if case .ownership(let snapshot)? = try? WebControlEnvelope.parse(Data(text.utf8)),
                       snapshot.grid.cols == 90 { break reading }
                }
            }
            let lag = takeoverStart.duration(to: .now).components
            print("[terminal-flow] {\"scenario\":\"delayedLink\",\"windowBytes\":\(windowBytes ?? 0),\"oneWayMilliseconds\":\(oneWayMilliseconds),\"keepingUpMegabytesPerSecond\":\(Double(keepingUp) / 1_048_576 / seconds),\"consumerBytesPerSecond\":\(consumerRate),\"bytesAheadOfTakeover\":\(ahead),\"takeoverSeconds\":\(Double(lag.seconds) + Double(lag.attoseconds) / 1e18)}")
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    private func percentile(_ samples: [Double], _ fraction: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)]
    }

    @Test("@spec REMOTE-9.17: While an SSH terminal consumer has not taken its received output, the application shall stop reading that channel so SSH flow control pauses the host, keeping the terminal attached and delivering every byte in order once the consumer resumes.")
    func stalledViewerPausesHostAndResumesInOrder() async throws {
        let total = 48 * 1024 * 1024
        let fixture = try await SSHBackpressureFixture.make(sibling: true)
        do {
            let producer = fixture.stream.produce(total: total)
            defer { producer.cancel() }
            try await fixture.waitForSourceToStop()
            #expect(!fixture.probe.childClosed)
            #expect(fixture.stream.pushedBytes < total)
            // A sibling on the same SSH connection is unaffected.
            _ = try await fixture.siblingEcho()
            #expect(try await fixture.drainPrimary(expected: total))
            #expect(!fixture.probe.childClosed)
            #expect(fixture.clientParent.isActive)
            #expect(fixture.serverParent.isActive)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test("@spec REMOTE-9.19: While a terminal client has negotiated an output window, the host shall hold back terminal bytes beyond that window of unconsumed output, so ownership, takeover and recovery messages reach the client behind no more than that window.")
    func negotiatedWindowKeepsControlAheadOfBlockedOutput() async throws {
        let fixture = try await SSHBackpressureFixture.make(sibling: true)
        do {
            await fixture.client.sendHello(clientID: DisplayClientID("primary"), kind: .ios, role: .interactive, visible: true, cols: 80, rows: 24)
            try await fixture.expectControlFrame()
            let total = 16 * 1024 * 1024
            let producer = fixture.stream.produce(total: total)
            defer { producer.cancel() }
            try await fixture.waitForSourceToStop()
            #expect(!fixture.probe.childClosed)
            // The buffer also holds the small ownership frames sent after the hello.
            #expect(fixture.client.bufferedByteCountForTesting <= TerminalOutputCredit.clientWindowBytes + 4096)
            // Client-to-host control progresses, and the host answers at once.
            await fixture.sibling.sendHello(clientID: DisplayClientID("sibling"), kind: .ios, role: .interactive, visible: true, cols: 80, rows: 24)
            await fixture.sibling.takeControl(clientID: DisplayClientID("sibling"), kind: .ios, cols: 90, rows: 30)
            let lag = try await fixture.primaryOutputBeforeTakeover()
            #expect(lag <= TerminalOutputCredit.clientWindowBytes)
            // The remaining output still arrives, in order, from where it stopped.
            #expect(try await fixture.drainPrimary(expected: total - lag, from: lag))
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test("@spec REMOTE-9.20: If a terminal client does not negotiate an output window, then the host shall forward its output under SSH flow control alone.")
    func unnegotiatedClientKeepsSSHFlowControlOnly() async throws {
        let total = 8 * 1024 * 1024
        let fixture = try await SSHBackpressureFixture.make(negotiatesOutputWindow: false)
        do {
            let producer = fixture.stream.produce(total: total)
            defer { producer.cancel() }
            try await fixture.wait(for: "source drained") { fixture.stream.pushedBytes == total }
            try await fixture.waitForSourceToStop()
            #expect(fixture.client.bufferedByteCountForTesting > TerminalOutputCredit.clientWindowBytes)
            #expect(try await fixture.drainPrimary(expected: total))
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test("@spec REMOTE-9.18: When a terminal exits while its output is paused, the application shall deliver all of that output before reporting the exit status.")
    func exitWhilePausedDrainsOutputBeforeExitStatus() async throws {
        // SSH flow control alone, where NIOSSH can hold output behind the exit
        // request. Under a negotiated window the host sends the exit last anyway.
        let total = 12 * 1024 * 1024
        let fixture = try await SSHBackpressureFixture.make(negotiatesOutputWindow: false)
        do {
            let producer = fixture.stream.produce(total: total)
            try await fixture.wait(for: "source drained") { fixture.stream.pushedBytes == total }
            await producer.value
            fixture.stream.finish()
            try await fixture.wait(for: "EOF channel cleanup") { fixture.probe.childClosed }
            #expect(try await fixture.drainPrimary(expected: total))
            do {
                _ = try await fixture.client.receive()
                Issue.record("Expected exit status after final output")
            } catch TerminalSessionClient.ClientError.sessionEnded(let status) {
                #expect(status == 0)
            }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func exitAfterAResumedPauseDrainsEveryHeldWindow() async throws {
        // Resuming hands over the window NIOSSH held and re-grants it, so the
        // host can fill a second window behind the first before it closes.
        let total = 32 * 1024 * 1024
        let fixture = try await SSHBackpressureFixture.make(negotiatesOutputWindow: false)
        do {
            let producer = fixture.stream.produce(total: total)
            defer { producer.cancel() }
            try await fixture.waitForSourceToStop()
            // Just past the low mark. The read that releases has not landed yet.
            let position = try await fixture.drainPrimary(atLeast: fixture.client.bufferedByteCountForTesting - 1024 * 1024)
            try await fixture.wait(for: "source drained") { fixture.stream.pushedBytes == total }
            await producer.value
            fixture.stream.finish()
            try await fixture.wait(for: "EOF channel cleanup") { fixture.probe.childClosed }
            #expect(try await fixture.drainPrimary(expected: total - position, from: position))
            do {
                _ = try await fixture.client.receive()
                Issue.record("Expected exit status after final output")
            } catch TerminalSessionClient.ClientError.sessionEnded(let status) {
                #expect(status == 0)
            }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func terminalEOFDrainsFinalBytesBeforeExitStatus() async throws {
        let fixture = try await SSHBackpressureFixture.make()
        do {
            // Cross several SSH writes and the receive batch boundary, using
            // a changing pattern so missing or reordered slices are visible.
            let expected = Data((0..<(256 * 1024 + 3)).map {
                UInt8(truncatingIfNeeded: ($0 / 16384) ^ ($0 % 251))
            })
            try fixture.stream.emit(expected)
            fixture.stream.finish()
            try await fixture.wait(for: "EOF channel cleanup") {
                fixture.probe.childClosed && fixture.stream.wasClosed
            }

            let received = SSHBackpressureResult<(Data, Int)>()
            let receiver = Task {
                var bytes = Data()
                do {
                    while true {
                        switch try await fixture.client.receive() {
                        case .binary(let chunk):
                            guard bytes.count + chunk.count <= expected.count else {
                                throw SSHBackpressureFailure("unexpected extra terminal output")
                            }
                            bytes.append(chunk)
                        case .paged: throw PagedTerminalEnvelope.Error.invalid
                        case .text:
                            throw SSHBackpressureFailure("unexpected terminal control frame")
                        }
                    }
                } catch TerminalSessionClient.ClientError.sessionEnded(let status) {
                    received.complete(.success((bytes, status)))
                } catch {
                    received.complete(.failure(error))
                }
            }
            defer { receiver.cancel() }
            try await fixture.wait(for: "final bytes and exit status") { received.value != nil }
            let (bytes, status) = try #require(received.value).get()
            await receiver.value
            #expect(bytes == expected)
            #expect(status == 0)
            #expect(fixture.clientParent.isActive)
            #expect(fixture.serverParent.isActive)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }
}

private final class SSHBackpressureFixture: @unchecked Sendable {
    let clientParent = NIOAsyncTestingChannel()
    let serverParent = NIOAsyncTestingChannel()
    let stream = SSHBackpressureStream()
    let siblingStream = SSHBackpressureStream()
    let probe = SSHBackpressureProbe()
    private let ownershipStore = SessionDisplayOwnershipStore()
    private let ownershipBroadcaster = DisplayOwnershipBroadcaster()
    private let attachCount = SSHBackpressureCounter()
    private(set) var sibling: TerminalSessionClient!
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ssh-terminal-backpressure-\(UUID().uuidString)")
    private let deadline = ContinuousClock.now + .seconds(ProcessInfo.processInfo.environment["GRAFTTY_TERMINAL_FLOW_PROBES"] == nil ? 25 : 150)
    private let attachGate: SSHBackpressureAttachGate?
    private let childConfirmationGate: SSHBackpressureChildGate?
    private var pump: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var connecting: Task<Void, Never>?
    private var clientHandler: SSHBackpressureHandlerBox!
    private(set) var client: TerminalSessionClient!

    private let negotiatesOutputWindow: Bool
    private let windowBytes: Int
    private let oneWayDelay: Duration

    private init(stalling phase: SSHTerminalBackpressureTests.AttachmentPhase?, negotiatesOutputWindow: Bool, oneWayDelay: Duration, windowBytes: Int) {
        self.negotiatesOutputWindow = negotiatesOutputWindow
        self.windowBytes = windowBytes
        self.oneWayDelay = oneWayDelay
        attachGate = phase == .shellFactory ? SSHBackpressureAttachGate() : nil
        childConfirmationGate = phase == .childConfirmation ? SSHBackpressureChildGate() : nil
    }

    static func make(stalling phase: SSHTerminalBackpressureTests.AttachmentPhase? = nil, sibling: Bool = false, negotiatesOutputWindow: Bool = true, oneWayDelay: Duration = .zero, windowBytes: Int = TerminalOutputCredit.clientWindowBytes) async throws -> SSHBackpressureFixture {
        let fixture = SSHBackpressureFixture(stalling: phase, negotiatesOutputWindow: negotiatesOutputWindow, oneWayDelay: oneWayDelay, windowBytes: windowBytes)
        do {
            try await fixture.start()
            if sibling { try await fixture.openSibling() }
            return fixture
        } catch {
            await fixture.close()
            throw error
        }
    }

    private func start() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let store = TrustedPeerStore(directory: directory)
        let peer = SSHUserAuthTestSupport.makePeer(key: clientKey, kind: .mac)
        try store.add(peer)
        let stream = self.stream
        let siblingStream = self.siblingStream
        let attachCount = self.attachCount
        let ownershipStore = self.ownershipStore
        let ownershipBroadcaster = self.ownershipBroadcaster
        let probe = self.probe
        let attachGate = self.attachGate
        let childConfirmationGate = self.childConfirmationGate
        let serverHandler = SSHBackpressureHandlerBox(handler: SSHServerSetup.makeHandler(
            hostKey: serverKey, trustedPeerStore: store, allocator: serverParent.allocator,
            inboundChildChannelInitializer: { child, type in
                guard case .session = type else {
                    return child.eventLoop.makeFailedFuture(SSHBackpressureFailure("unexpected SSH channel type"))
                }
                let index = attachCount.next()
                child.closeFuture.whenComplete { _ in if index == 0 { probe.markChildClosed() } else { probe.markSiblingClosed() } }
                let installed = child.pipeline.addHandler(TerminalSessionHandler(
                    streamFactory: { _ in
                        await attachGate?.wait()
                        return index == 0 ? stream : siblingStream
                    },
                    ownershipStore: ownershipStore,
                    ownershipBroadcaster: ownershipBroadcaster, deviceID: peer.id
                ))
                guard let childConfirmationGate else { return installed }
                let ready = child.eventLoop.makePromise(of: Void.self)
                childConfirmationGate.hold(ready)
                return installed.flatMap { ready.futureResult }
            }
        ))
        let clientHandler = SSHBackpressureHandlerBox(handler: SSHClientSetup.makeHandler(
            clientKey: clientKey,
            expectedHostFingerprint: .init(of: try RemoteIdentityPublicKey(rawRepresentation: serverKey.publicKey.rawRepresentation)),
            allocator: clientParent.allocator
        ))
        try await serverParent.testingEventLoop.executeInContext {
            try self.serverParent.pipeline.syncOperations.addHandler(serverHandler.handler)
        }
        try await clientParent.testingEventLoop.executeInContext {
            try self.clientParent.pipeline.syncOperations.addHandler(clientHandler.handler)
            try self.clientParent.pipeline.syncOperations.addHandler(SSHBackpressureAuthenticationRelay(probe: probe))
        }
        try await serverParent.connect(to: .init(unixDomainSocketPath: "/tmp/ssh-backpressure-server")).get()
        try await clientParent.connect(to: .init(unixDomainSocketPath: "/tmp/ssh-backpressure-client")).get()
        let clientParent = self.clientParent
        let serverParent = self.serverParent
        let oneWayDelay = self.oneWayDelay
        pump = Task {
            // Each direction keeps its order; bytes wait out the link's delay.
            var toServer: [(due: ContinuousClock.Instant, bytes: IOData)] = []
            var toClient: [(due: ContinuousClock.Instant, bytes: IOData)] = []
            do {
                while !Task.isCancelled {
                    await clientParent.testingEventLoop.run()
                    await serverParent.testingEventLoop.run()
                    while let bytes = try await clientParent.readOutbound(as: IOData.self) {
                        toServer.append((ContinuousClock.now + oneWayDelay, bytes))
                    }
                    while let bytes = try await serverParent.readOutbound(as: IOData.self) {
                        toClient.append((ContinuousClock.now + oneWayDelay, bytes))
                    }
                    let now = ContinuousClock.now
                    while let next = toServer.first, next.due <= now {
                        try Task.checkCancellation()
                        toServer.removeFirst()
                        try await serverParent.writeInbound(next.bytes)
                    }
                    while let next = toClient.first, next.due <= now {
                        try Task.checkCancellation()
                        toClient.removeFirst()
                        try await clientParent.writeInbound(next.bytes)
                    }
                    try await Task.sleep(for: .milliseconds(1))
                }
            } catch {
                if !Task.isCancelled { probe.fail(error) }
            }
        }
        let deadline = self.deadline
        watchdog = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            probe.fail(SSHBackpressureFailure("SSH loopback watchdog expired"))
            clientParent.close(promise: nil)
            serverParent.close(promise: nil)
        }
        try await wait(for: "authentication") { probe.authenticated }
        self.clientHandler = clientHandler
        let client = TerminalSessionClient(parentChannel: clientParent,
            parentHandler: clientHandler.handler, sessionName: "backpressure",
            outputWindowBytes: negotiatesOutputWindow ? windowBytes : nil)
        self.client = client
        connecting = Task {
            do { try await client.connect(); probe.connection.complete(.success(())) }
            catch { probe.connection.complete(.failure(error)) }
        }
        // Shell acknowledgement has no production timeout. Poll its result so
        // an acknowledgement regression cannot hold this test open forever.
        if let childConfirmationGate {
            try await wait(for: "SSH child initializer entry") { childConfirmationGate.entered }
        } else if let attachGate {
            try await wait(for: "terminal factory entry") { attachGate.entered }
        } else {
            try await wait(for: "terminal shell acknowledgement") { probe.connection.value != nil }
            try #require(probe.connection.value).get()
        }
    }

    /// Same SSH connection and session as the primary: a sibling pane or
    /// viewer whose traffic must keep flowing while the primary is paused.
    private func openSibling() async throws {
        let sibling = TerminalSessionClient(parentChannel: clientParent,
            parentHandler: clientHandler.handler, sessionName: "backpressure")
        self.sibling = sibling
        let connected = SSHBackpressureResult<Void>()
        let task = Task {
            do { try await sibling.connect(); connected.complete(.success(())) }
            catch { connected.complete(.failure(error)) }
        }
        defer { task.cancel() }
        try await wait(for: "sibling shell acknowledgement") { connected.value != nil }
        try #require(connected.value).get()
        siblingStream.echoesInput = true
    }

    /// One keystroke round trip on the sibling terminal, in milliseconds.
    func siblingEcho() async throws -> Double {
        let start = ContinuousClock.now
        try await sibling.send(.binary(Data([0x65])))
        while true {
            if case .binary(let bytes) = try await sibling.receive(), !bytes.isEmpty { break }
        }
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }

    func expectControlFrame() async throws {
        while true {
            if case .text = try await client.receive() { return }
        }
    }

    /// Polls until the paused source has made no progress for a settle period.
    func waitForSourceToStop() async throws {
        var last = -1
        while stream.pushedBytes != last, !probe.childClosed {
            last = stream.pushedBytes
            try await Task.sleep(for: .milliseconds(300))
            if let error = probe.failure { throw error }
        }
    }

    /// Output bytes consumed before the sibling's takeover reaches the primary.
    /// Those bytes are verified against the source pattern.
    func primaryOutputBeforeTakeover() async throws -> Int {
        var position = 0
        while true {
            switch try await client.receive() {
            case .binary(let bytes):
                try verify(bytes, at: position)
                position += bytes.count
            case .paged: throw PagedTerminalEnvelope.Error.invalid
            case .text(let text):
                if case .ownership(let snapshot)? = try? WebControlEnvelope.parse(Data(text.utf8)),
                   snapshot.grid.cols == 90 { return position }
            }
        }
    }

    private func verify(_ bytes: Data, at position: Int) throws {
        for (offset, byte) in bytes.enumerated() where byte != SSHBackpressureStream.patternByte(at: position + offset) {
            throw SSHBackpressureFailure("Output differed at \(position + offset)")
        }
    }

    /// Consumes at least `count` output bytes from the start of the source, and
    /// returns the offset reached.
    func drainPrimary(atLeast count: Int) async throws -> Int {
        var position = 0
        while position < count {
            guard case .binary(let bytes) = try await client.receive() else { continue }
            try verify(bytes, at: position)
            position += bytes.count
        }
        return position
    }

    /// Consumes `expected` output bytes starting at source offset `from`, and
    /// reports whether they were intact and in order.
    func drainPrimary(expected: Int, from start: Int = 0) async throws -> Bool {
        var position = start
        while position < start + expected {
            guard case .binary(let bytes) = try await client.receive() else { continue }
            try verify(bytes, at: position)
            position += bytes.count
        }
        return position == start + expected
    }

    func cancelConnection() { connecting?.cancel() }
    func releaseAttach() {
        attachGate?.release()
        childConfirmationGate?.release()
    }

    func wait(for phase: String, until condition: () -> Bool) async throws {
        while !condition() {
            if let error = probe.failure { throw error }
            guard ContinuousClock.now < deadline else {
                throw SSHBackpressureFailure("Timed out waiting for \(phase)")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        if let error = probe.failure { throw error }
    }

    func close() async {
        watchdog?.cancel()
        releaseAttach()
        client?.close()
        sibling?.close()
        stream.finish()
        siblingStream.finish()
        connecting?.cancel()
        clientParent.close(promise: nil)
        serverParent.close(promise: nil)
        await clientParent.testingEventLoop.run()
        await serverParent.testingEventLoop.run()
        pump?.cancel()
        await pump?.value
        _ = try? await clientParent.finish()
        _ = try? await serverParent.finish()
        // A completed setup task can be joined. An unacknowledged shell task
        // may ignore cancellation, so cleanup must not await it indefinitely.
        if probe.connection.value != nil { await connecting?.value }
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class SSHBackpressureStream: GrafttyKit.TerminalByteStream, @unchecked Sendable {
    let inboundBytes: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var closed = false
    var wasClosed: Bool { lock.withLock { closed } }

    init() {
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(1))
        inboundBytes = pair.stream
        continuation = pair.continuation
    }

    func emit(_ data: Data) throws {
        guard data.count <= 8 * 1024 * 1024 + 16 * 1024,
              case .enqueued = continuation.yield(data) else {
            throw SSHBackpressureFailure("bounded terminal fixture rejected output")
        }
    }

    /// Changing pattern so loss, duplication or reordering is detectable.
    static func patternByte(at position: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: (position / 16384) ^ (position % 251))
    }

    private var pushed = 0
    var pushedBytes: Int { lock.withLock { pushed } }
    private var echoInput = false
    var echoesInput: Bool {
        get { lock.withLock { echoInput } }
        set { lock.withLock { echoInput = newValue } }
    }

    /// Mirrors the attach engine: the source retries a full bounded queue, so
    /// it stops advancing once the SSH consumer stops taking output.
    func produce(total: Int, startingAt start: Int = 0, chunk: Int = 64 * 1024) -> Task<Void, Never> {
        Task { [self] in
            var position = start
            while position < total, !Task.isCancelled, !wasClosed {
                let count = min(chunk, total - position)
                let data = Data((0..<count).map { Self.patternByte(at: position + $0) })
                while !Task.isCancelled, !wasClosed {
                    switch continuation.yield(data) {
                    case .enqueued:
                        position += count
                        lock.withLock { pushed = position }
                    case .dropped:
                        try? await Task.sleep(for: .milliseconds(1))
                        continue
                    case .terminated: return
                    @unknown default: return
                    }
                    break
                }
            }
        }
    }

    func send(_ bytes: Data) async throws {
        if echoesInput { continuation.yield(bytes) }
    }
    func finish() { continuation.finish() }
    func close() async {
        lock.withLock { closed = true }
        continuation.finish()
    }
}

private final class SSHBackpressureAttachGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var didEnter = false
    var entered: Bool { lock.withLock { didEnter } }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                didEnter = true
                if released { continuation.resume() }
                else { waiter = continuation }
            }
        }
    }

    func release() {
        let waiter = lock.withLock {
            released = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume()
    }
}

private final class SSHBackpressureChildGate: @unchecked Sendable {
    private let lock = NSLock()
    private var promise: EventLoopPromise<Void>?
    private var released = false
    private var didEnter = false
    var entered: Bool { lock.withLock { didEnter } }

    func hold(_ promise: EventLoopPromise<Void>) {
        let releaseImmediately = lock.withLock {
            didEnter = true
            guard !released else { return true }
            self.promise = promise
            return false
        }
        if releaseImmediately { promise.succeed(()) }
    }

    func release() {
        let promise = lock.withLock {
            released = true
            defer { self.promise = nil }
            return self.promise
        }
        promise?.succeed(())
    }
}

private final class SSHBackpressureResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    var value: Result<Value, Error>? { lock.withLock { result } }
    func complete(_ result: Result<Value, Error>) { lock.withLock { self.result = result } }
}

private final class SSHBackpressureProbe: @unchecked Sendable {
    let connection = SSHBackpressureResult<Void>()
    private let lock = NSLock()
    private var didAuthenticate = false
    private var didCloseChild = false
    private var didCloseSibling = false
    var siblingClosed: Bool { lock.withLock { didCloseSibling } }
    func markSiblingClosed() { lock.withLock { didCloseSibling = true } }
    private var error: Error?
    var authenticated: Bool { lock.withLock { didAuthenticate } }
    var childClosed: Bool { lock.withLock { didCloseChild } }
    var failure: Error? { lock.withLock { error } }
    func markAuthenticated() { lock.withLock { didAuthenticate = true } }
    func markChildClosed() { lock.withLock { didCloseChild = true } }
    func fail(_ error: Error) { lock.withLock { if self.error == nil { self.error = error } } }
}

private final class SSHBackpressureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

private struct ProbeReport: Encodable {
    let scenario: String
    let disconnected: Bool
    let producerBytesWhilePaused: Int
    let peakReceiveBufferBytes: Int
    let siblingEchoP95Milliseconds: Double?
    let siblingEchoSamples: Int
    var controlLagBytes: Int?
    var deliveredIntact: Bool?
    var disconnectedAfterResume: Bool?
    func json() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

private final class SSHBackpressureAuthenticationRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let probe: SSHBackpressureProbe
    init(probe: SSHBackpressureProbe) { self.probe = probe }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { probe.markAuthenticated() }
        context.fireUserInboundEventTriggered(event)
    }
}

private struct SSHBackpressureHandlerBox: @unchecked Sendable {
    let handler: NIOSSHHandler
}

private struct SSHBackpressureFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

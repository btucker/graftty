#if canImport(UIKit)
import CryptoKit
import Foundation
import GrafttyProtocol
import NIOCore
import NIOSSH
import Testing
import WebRTC
@testable import GrafttyMobileKit

/// End-to-end SSH-over-WebRTC terminal-session-channel tests.
///
/// Uses R3's `LoopbackPeer` pattern + real `SSHServerSetup`-equivalent
/// + real `SSHClientSetup` + a fake echoing `TerminalByteStream`. The
/// fake replaces the production `ZmxAttachEngine` because iOS Simulator
/// doesn't have host binaries — real `zmx attach` integration is
/// verified at the manual TestFlight gate, not in CI.
///
/// `.serialized` per R3 precedent (one SSH-over-WebRTC stack at a time
/// on the iOS Simulator's resource-constrained runtime).
@Suite(
    "SSH-over-WebRTC terminal channel — env+pty+shell + bytes round-trip (R4)",
    .serialized
)
struct SSHTerminalLoopbackTests {

    /// End-to-end: client opens session channel, sends env+pty+shell,
    /// writes "hi\n", server-side echo stream returns "hi\n".
    @Test(.timeLimit(.minutes(3)))
    func bytesRoundTripThroughTerminalSessionChannel() async throws {
        let echoFactory: @Sendable (String) async throws -> TerminalByteStream = { _ in
            EchoStream()
        }

        let received = try await runTerminalLoopback(
            streamFactory: echoFactory,
            sessionName: "alpha",
            outboundBytes: Data("hi\n".utf8)
        )

        #expect(received == Data("hi\n".utf8))
    }

    /// streamFactory throws -> client `receive()` throws on the next
    /// call (channel closes via exit-status: 1 + close on the server).
    @Test(.timeLimit(.minutes(3)))
    func streamFactoryThrowsClosesChannel() async throws {
        let failingFactory: @Sendable (String) async throws -> TerminalByteStream = { _ in
            throw FactoryError.notFound
        }

        await #expect(throws: (any Error).self) {
            _ = try await runTerminalLoopback(
                streamFactory: failingFactory,
                sessionName: "missing",
                outboundBytes: Data("hi\n".utf8),
                responseDeadline: .seconds(10)
            )
        }
    }

    /// Decision-gate spike for W2: pins whether swift-nio-ssh 0.13 supports
    /// writing SSH extended data (`.stdErr`-typed `SSHChannelData`) from
    /// BOTH halves of a session channel — server→client and client→server —
    /// interleaved with normal `.channel` byte traffic, without corrupting
    /// order, mixing streams, or dropping data. The next two W2 tasks
    /// (control-envelope carrier) are gated on this result: PASS locks in
    /// `.stdErr` as the carrier; FAIL forces a `terminal-control@graftty.dev`
    /// subsystem-channel fallback. (No @spec ID — this pins an
    /// infrastructure capability, not a product requirement.)
    @Test(.timeLimit(.minutes(3)))
    func extendedDataFlowsBothDirectionsOnSessionChannel() async throws {
        let clientToServer: [Frame] = [
            Frame(type: .channel, bytes: Data("client-c1".utf8)),
            Frame(type: .stdErr, bytes: Data("client-e1".utf8)),
            Frame(type: .channel, bytes: Data("client-c2".utf8)),
            Frame(type: .stdErr, bytes: Data("client-e2".utf8)),
            Frame(type: .stdErr, bytes: Data("client-e3".utf8)),
            Frame(type: .channel, bytes: Data("client-c3".utf8)),
        ]
        let serverToClient: [Frame] = [
            Frame(type: .stdErr, bytes: Data("server-e1".utf8)),
            Frame(type: .channel, bytes: Data("server-c1".utf8)),
            Frame(type: .stdErr, bytes: Data("server-e2".utf8)),
            Frame(type: .channel, bytes: Data("server-c2".utf8)),
            Frame(type: .channel, bytes: Data("server-c3".utf8)),
            Frame(type: .stdErr, bytes: Data("server-e3".utf8)),
        ]

        let (serverReceived, clientReceived) = try await runExtendedDataLoopback(
            clientToServerFrames: clientToServer,
            serverToClientFrames: serverToClient
        )

        // Full received order matches full sent order for each direction —
        // proves NIOSSH preserves FIFO ordering BETWEEN `.channel` and
        // `.stdErr` writes on the same channel (not just within each
        // stream considered separately).
        #expect(serverReceived == clientToServer)
        #expect(clientReceived == serverToClient)

        // Per-stream isolation: filtering by type recovers exactly the
        // sub-sequence sent on that type, intact and in order — `.channel`
        // and `.stdErr` never mix, and nothing is silently dropped.
        #expect(serverReceived.filter { $0.type == .stdErr } == clientToServer.filter { $0.type == .stdErr })
        #expect(serverReceived.filter { $0.type == .channel } == clientToServer.filter { $0.type == .channel })
        #expect(clientReceived.filter { $0.type == .stdErr } == serverToClient.filter { $0.type == .stdErr })
        #expect(clientReceived.filter { $0.type == .channel } == serverToClient.filter { $0.type == .channel })
    }

    // MARK: - Task 5: SSH terminal ownership (hello / takeControl / ownerResize)

    /// Also proves localization: each client's OWN ownership envelope
    /// reports the owner using ITS OWN supplied `clientID` iff it is
    /// actually the owner (`SessionClient.isOwner` depends on this).
    @Test(
        """
        @spec REMOTE-9.5: When two SSH clients attach to one session over the control carrier, \
        the application shall grant display ownership to the first client that sends hello and \
        takeControl — localized to that client's own clientID in its ownership envelopes — attach \
        the second hello client as a follower whose envelopes never name it as owner, and answer \
        a follower's terminal bytes with an ownership rebroadcast instead of a PTY echo.
        """,
        .timeLimit(.minutes(3))
    )
    func firstClientTakesControlSecondFollowsAndBytesAreDiscarded() async throws {
        try await runOwnershipLoopback { clientA, clientB in
            let idA = DisplayClientID("client-a")
            let idB = DisplayClientID("client-b")

            await clientA.sendHello(clientID: idA, kind: .ios, role: .interactive, visible: true, cols: 80, rows: 24)
            await clientA.takeControl(clientID: idA, kind: .ios, cols: 80, rows: 24)

            // A's own view: it IS the owner, localized to its own clientID.
            let aOwns = try await nextOwnershipSnapshot(clientA) { $0.ownerClientID != nil }
            #expect(aOwns.ownerClientID == idA)
            #expect(aOwns.ownerKind == .ios)
            #expect(aOwns.epoch == 1)

            await clientB.sendHello(clientID: idB, kind: .ios, role: .interactive, visible: true, cols: 80, rows: 24)

            // B's view: someone else owns — never localized to B's own id.
            let bSees = try await nextOwnershipSnapshot(clientB) { $0.ownerClientID != nil }
            #expect(bSees.ownerClientID != idB)
            #expect(bSees.ownerKind == .ios)

            // B is a follower — its bytes must be discarded, not echoed.
            // The very next frame B observes is the discard's ownership
            // rebroadcast, never a `.binary` echo of what it just sent.
            try await clientB.send(.binary(Data("should-not-echo".utf8)))
            let followup = try await clientB.receive()
            guard case let .text(text) = followup else {
                Issue.record("expected the discard rebroadcast as a .text control frame, got \(followup)")
                return
            }
            guard case let .ownership(rebroadcast) = try WebControlEnvelope.parse(Data(text.utf8)) else {
                Issue.record("expected the discard rebroadcast to decode as an ownership envelope, got \(text)")
                return
            }
            #expect(rebroadcast.ownerClientID != idB, "the discard rebroadcast must never name the follower itself as owner")
        }
    }

    @Test(
        """
        @spec REMOTE-9.6: When an owner-eligible follower SSH client sends takeControl, the \
        application shall transfer display ownership to it and bump the session epoch, observable \
        by the new owner as a self-owned snapshot and by the former owner as a non-self owner in \
        their next ownership envelopes.
        """,
        .timeLimit(.minutes(3))
    )
    func takeControlFlipsOwnershipAndBumpsEpoch() async throws {
        try await runOwnershipLoopback { clientA, clientB in
            let idA = DisplayClientID("client-a")
            let idB = DisplayClientID("client-b")

            await clientA.sendHello(clientID: idA, kind: .ios, role: .interactive, visible: true, cols: 80, rows: 24)
            await clientA.takeControl(clientID: idA, kind: .ios, cols: 80, rows: 24)
            let aOwns = try await nextOwnershipSnapshot(clientA) { $0.ownerClientID == idA }
            #expect(aOwns.epoch == 1)

            await clientB.sendHello(clientID: idB, kind: .ios, role: .interactive, visible: true, cols: 80, rows: 24)
            _ = try await nextOwnershipSnapshot(clientB) { $0.ownerClientID != nil }

            await clientB.takeControl(clientID: idB, kind: .ios, cols: 80, rows: 24)

            let bOwns = try await nextOwnershipSnapshot(clientB) { $0.ownerClientID == idB }
            #expect(bOwns.epoch == 2, "owner change must bump the epoch")

            let aSeesHandoff = try await nextOwnershipSnapshot(clientA) { $0.epoch == 2 }
            #expect(aSeesHandoff.ownerClientID != idA, "the former owner must never see itself as owner after losing control")
        }
    }

    /// Mirrors the web transport's `SessionDisplayOwnershipStore.ownerResize`
    /// epoch+identity check on the SSH carrier.
    @Test(
        """
        @spec REMOTE-9.7: If an SSH client that is not the current display owner sends ownerResize, \
        then the application shall reject it and leave the broadcast grid unchanged; while the \
        current owner sends ownerResize at the current epoch, the application shall update the \
        broadcast grid without bumping the epoch.
        """,
        .timeLimit(.minutes(3))
    )
    func ownerResizeAcceptedOnlyFromCurrentOwner() async throws {
        try await runOwnershipLoopback { clientA, clientB in
            let idA = DisplayClientID("client-a")
            let idB = DisplayClientID("client-b")

            await clientA.sendHello(clientID: idA, kind: .ios, role: .interactive, visible: true, cols: 80, rows: 24)
            await clientA.takeControl(clientID: idA, kind: .ios, cols: 80, rows: 24)
            let aOwns = try await nextOwnershipSnapshot(clientA) { $0.ownerClientID == idA }
            let ownerEpoch = aOwns.epoch

            await clientB.sendHello(clientID: idB, kind: .ios, role: .interactive, visible: true, cols: 80, rows: 24)
            _ = try await nextOwnershipSnapshot(clientB) { $0.ownerClientID != nil }

            // Owner resize: accepted, grid updates, epoch unchanged.
            await clientA.ownerResize(clientID: idA, epoch: ownerEpoch, cols: 100, rows: 30)
            let acceptedGrid = try DisplayGrid(cols: 100, rows: 30)
            let resized = try await nextOwnershipSnapshot(clientA) { $0.grid == acceptedGrid }
            #expect(resized.epoch == ownerEpoch, "an owner resize must not bump the epoch")
            // Drain B's copy of the SAME accepted-resize broadcast before
            // exercising the rejection below — otherwise the next raw
            // envelope B observes could be this already-queued, unrelated
            // broadcast (which coincidentally carries the same grid),
            // masking a bug that incorrectly accepted B's resize.
            _ = try await nextOwnershipSnapshot(clientB) { $0.grid == acceptedGrid }

            // Non-owner resize: rejected — the very next envelope B observes
            // still carries the owner's committed grid, never B's requested one.
            await clientB.ownerResize(clientID: idB, epoch: ownerEpoch, cols: 999, rows: 999)
            let afterRejected = try await nextEnvelope(clientB)
            guard case let .ownership(snapshot) = afterRejected else {
                Issue.record("expected an ownership envelope, got \(afterRejected)")
                return
            }
            #expect(snapshot.grid == acceptedGrid, "a non-owner's resize must be rejected")
        }
    }

    /// A poisoned-but-alive `.stdErr` carrier is a frozen-ownership black
    /// hole: no more take-control/ownerResize requests could ever be
    /// parsed, and (if this client isn't the owner) inbound ownership
    /// updates would stop too, with no signal to the client that anything
    /// is wrong. Closing the child channel on poisoning routes into
    /// `SessionClient`'s existing reconnect/backoff instead, so the
    /// client self-heals rather than hanging silently forever.
    @Test(.timeLimit(.minutes(3)))
    func oversizedInboundControlFrameClosesChildChannelAndEndsTheClientStream() async throws {
        try await runPoisonedControlFrameLoopback()
    }

    /// Before this fix, `TerminalSessionClient.gridDimension` only clamped
    /// to `UInt16`'s range (0...65535) — a transient layout value like
    /// 20_000 sails through that check untouched, gets encoded into the
    /// `.hello` envelope as-is, and fails `WebControlEnvelope.parse`'s
    /// `cols <= maxGridDimension (10_000)` check server-side. Pre-wave-A
    /// that silently stranded the connection forever (no `.hello` frame
    /// ever parses, so `receivedHello` never flips); even with wave A's
    /// lenient-hello fallback the client should never SEND an
    /// envelope its own protocol would reject. `gridDimension` now clamps
    /// through `WebControlEnvelope.clampedGridDimension` (the same shared
    /// bound the server enforces), so this hello is accepted immediately
    /// and the resulting grid is clamped rather than rejected or dropped.
    @Test(.timeLimit(.minutes(3)))
    func outOfRangeHelloGridIsClampedNotStranded() async throws {
        try await runOwnershipLoopback { clientA, _ in
            let idA = DisplayClientID("client-a")
            await clientA.sendHello(
                clientID: idA,
                kind: .ios,
                role: .interactive,
                visible: true,
                cols: 20_000,
                rows: 30
            )
            await clientA.takeControl(clientID: idA, kind: .ios, cols: 20_000, rows: 30)

            let aOwns = try await nextOwnershipSnapshot(clientA) { $0.ownerClientID == idA }
            #expect(
                aOwns.grid.cols == UInt16(WebControlEnvelope.maxGridDimension),
                "an out-of-range hello/takeControl grid must clamp to the shared cap, not strand the connection"
            )
        }
    }

    /// `send(.text)` used to write the envelope JSON as `.channel` PTY
    /// bytes — asymmetric with `receive()` (which surfaces control frames
    /// as `.text`) and with `URLSessionWebSocketClient` (where `.text` IS
    /// the control encoding): a polymorphic caller sending a control
    /// envelope through the generic `WebSocketClient.send` surface would
    /// have had its JSON typed into the shared PTY instead of reaching the
    /// server's control parser. Proven end-to-end here: a hello delivered
    /// via `send(.text(helloJSON))` must flip the server's hello gating —
    /// observable because a subsequent `takeControl` is only honored (and
    /// only produces a self-owned ownership snapshot) after a `.hello` has
    /// been PARSED from the control carrier; a hello that went out as PTY
    /// bytes would leave every control frame dropped and the snapshot
    /// unobservable (echoed keystrokes, no ownership).
    @Test(.timeLimit(.minutes(3)))
    func sendTextRoutesThroughControlCarrierNotPTYBytes() async throws {
        try await runOwnershipLoopback { clientA, _ in
            let idA = DisplayClientID("client-a")
            let helloJSON = WebControlEnvelope.hello(
                clientID: idA,
                kind: .ios,
                role: .interactive,
                visible: true,
                cols: 80,
                rows: 24
            ).encoded()

            try await clientA.send(.text(helloJSON))
            await clientA.takeControl(clientID: idA, kind: .ios, cols: 80, rows: 24)

            let aOwns = try await nextOwnershipSnapshot(clientA) { $0.ownerClientID == idA }
            #expect(
                aOwns.ownerClientID == idA,
                "a hello sent via send(.text) must arrive on the control carrier and flip hello gating"
            )
        }
    }

    // MARK: - Loopback driver

    /// Bootstraps ONE SSH-over-WebRTC connection: a loopback WebRTC data
    /// channel pair, an `SSHNIOTransport` on each side, a server-side
    /// `NIOSSHHandler` wired to `inboundChildChannelInitializer`, and a
    /// client-side `NIOSSHHandler` trusted to the server's fingerprint.
    /// Every `run*Loopback` driver in this file used to bootstrap an
    /// identical ~40-line copy of this WebRTC+SSH-handshake plumbing before
    /// installing its own test-specific server-side channel handler — this
    /// is that shared bootstrap, extracted once four drivers had each grown
    /// their own copy. Server/client identity keys and the trusted-peer
    /// store are generated internally: no caller needed the concrete keys
    /// themselves, only a connection whose handshake succeeds.
    private func makeLoopbackConnection(
        inboundChildChannelInitializer: @escaping @Sendable (Channel, SSHChannelType) -> EventLoopFuture<Void>
    ) async throws -> LoopbackConnection {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(fingerprint: Self.fingerprint(of: clientKey))

        let offerer = LoopbackPeer(role: .offerer)
        let answerer = LoopbackPeer(role: .answerer)
        let offer = try await offerer.createOffer()
        let answer = try await answerer.accept(offer: offer)
        await offerer.bindIceCandidates(to: answerer)
        await answerer.bindIceCandidates(to: offerer)
        try await offerer.applyAnswer(answer)
        let offererDC = try await offerer.openedDataChannel()
        let answererDC = try await answerer.openedDataChannel()

        let clientTransport = SSHNIOTransport(dataChannel: offererDC)
        let serverTransport = SSHNIOTransport(dataChannel: answererDC)

        try await serverTransport.eventLoop.submit {
            let serverConfig = SSHServerConfiguration(
                hostKeys: [NIOSSHPrivateKey(ed25519Key: serverKey)],
                userAuthDelegate: TrustSetServerUserAuthDelegate(store: peerStore)
            )
            let sshHandler = NIOSSHHandler(
                role: .server(serverConfig),
                allocator: serverTransport.channel.allocator,
                inboundChildChannelInitializer: inboundChildChannelInitializer
            )
            try serverTransport.channel.pipeline.syncOperations.addHandler(sshHandler)
        }.get()

        // Client: real SSHClientSetup. Capture the handler for the caller's
        // channel client(s) to use.
        let handlerPromise = clientTransport.eventLoop.makePromise(of: NIOSSHHandler.self)
        try await clientTransport.eventLoop.submit {
            let h = SSHClientSetup.makeHandler(
                clientKey: clientKey,
                expectedHostFingerprint: Self.fingerprint(of: serverKey),
                allocator: clientTransport.channel.allocator
            )
            try clientTransport.channel.pipeline.syncOperations.addHandler(h)
            handlerPromise.succeed(h)
        }.get()
        let sshHandler = try await handlerPromise.futureResult.get()

        try await serverTransport.start()
        try await clientTransport.start()

        return LoopbackConnection(
            clientTransport: clientTransport,
            serverTransport: serverTransport,
            sshHandler: sshHandler,
            offerer: offerer,
            answerer: answerer
        )
    }

    private func runTerminalLoopback(
        streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream,
        sessionName: String,
        outboundBytes: Data,
        responseDeadline: Duration = .seconds(180)
    ) async throws -> Data {
        let connection = try await makeLoopbackConnection { childChannel, channelType in
            guard case .session = channelType else {
                return childChannel.eventLoop.makeFailedFuture(LoopbackError.unexpectedChannelType)
            }
            return childChannel.eventLoop.makeCompletedFuture {
                let h = TerminalSessionHandler(streamFactory: streamFactory)
                try childChannel.pipeline.syncOperations.addHandler(h)
            }
        }

        // Open the terminal session channel via TerminalSessionClient.
        let client = TerminalSessionClient(
            parentChannel: connection.clientTransport.channel,
            parentHandler: connection.sshHandler,
            sessionName: sessionName
        )

        // Belt-and-suspenders deadline (same pattern as R3 — wall-clock
        // Task rather than NIO scheduler).
        let deadlineTask = Task { [client] in
            try? await Task.sleep(for: responseDeadline)
            client.close()
        }
        defer { deadlineTask.cancel() }

        try await client.connect()
        try await client.send(.binary(outboundBytes))

        let frame = try await client.receive()
        let received: Data
        switch frame {
        case .binary(let d): received = d
        case .text(let s): received = Data(s.utf8)
        }

        client.close()
        await connection.close()

        return received
    }

    /// Loopback driver for the extended-data decision-gate spike. Opens a
    /// bare session channel on each side (no env/pty/shell — this spike
    /// tests raw `SSHChannelData` carriage, not the terminal protocol) with
    /// a `FrameRecordingHandler` that records every inbound frame (type +
    /// bytes) in receipt order. Writes `clientToServerFrames` and
    /// `serverToClientFrames` sequentially (awaiting each flush) so the
    /// send-side order is well-defined, then returns what each side
    /// actually received.
    private func runExtendedDataLoopback(
        clientToServerFrames: [Frame],
        serverToClientFrames: [Frame],
        responseDeadline: Duration = .seconds(60)
    ) async throws -> (server: [Frame], client: [Frame]) {
        let serverCollector = FrameCollector()
        let clientCollector = FrameCollector()
        // Buffered `AsyncStream` rather than an `EventLoopPromise` — unlike
        // the promise this replaced, it needs no live `EventLoop` at
        // construction time, so it can be captured by the
        // `inboundChildChannelInitializer` closure BEFORE
        // `makeLoopbackConnection` has created the server transport whose
        // event loop the old promise was made on.
        var serverChildContinuation: AsyncStream<Channel>.Continuation!
        let serverChildStream = AsyncStream<Channel> { serverChildContinuation = $0 }

        // Server: accept the inbound session channel and just record
        // frames — no TerminalSessionHandler, no env/pty/shell gating.
        let connection = try await makeLoopbackConnection { childChannel, channelType in
            guard case .session = channelType else {
                return childChannel.eventLoop.makeFailedFuture(LoopbackError.unexpectedChannelType)
            }
            return childChannel.eventLoop.makeCompletedFuture {
                try childChannel.pipeline.syncOperations.addHandler(
                    FrameRecordingHandler(collector: serverCollector)
                )
                serverChildContinuation.yield(childChannel)
            }
        }

        // Client: open a bare session channel directly through the parent
        // handler (bypassing TerminalSessionClient, which only ever writes
        // `.channel`-typed data) and record inbound frames the same way.
        let clientChildPromise = connection.clientTransport.eventLoop.makePromise(of: Channel.self)
        connection.sshHandler.createChannel(clientChildPromise, channelType: .session) { child, _ in
            child.eventLoop.makeCompletedFuture {
                try child.pipeline.syncOperations.addHandler(
                    FrameRecordingHandler(collector: clientCollector)
                )
            }
        }
        let clientChild = try await clientChildPromise.futureResult.get()
        var serverChildIterator = serverChildStream.makeAsyncIterator()
        guard let serverChild = await serverChildIterator.next() else {
            throw LoopbackError.channelInactiveBeforeResponse
        }

        // Belt-and-suspenders wall-clock deadline (same pattern as the
        // byte-round-trip driver above) — closing both children also
        // finishes both collectors' streams so `collect` below can't hang.
        let deadlineTask = Task {
            try? await Task.sleep(for: responseDeadline)
            clientChild.close(promise: nil)
            serverChild.close(promise: nil)
        }
        defer { deadlineTask.cancel() }

        async let clientSend: Void = Self.writeFrames(clientToServerFrames, to: clientChild)
        async let serverSend: Void = Self.writeFrames(serverToClientFrames, to: serverChild)
        _ = try await (clientSend, serverSend)

        let serverReceived = await Self.collect(serverCollector.frames, count: clientToServerFrames.count)
        let clientReceived = await Self.collect(clientCollector.frames, count: serverToClientFrames.count)

        clientChild.close(promise: nil)
        serverChild.close(promise: nil)
        await connection.close()

        return (serverReceived, clientReceived)
    }

    private static func writeFrames(_ frames: [Frame], to channel: Channel) async throws {
        for frame in frames {
            let buffer = channel.allocator.buffer(bytes: frame.bytes)
            let channelData = SSHChannelData(type: frame.type, data: .byteBuffer(buffer))
            try await channel.writeAndFlush(channelData).get()
        }
    }

    /// Drains up to `count` frames from `stream`, stopping early if the
    /// stream finishes (channel closed) before `count` is reached — the
    /// caller's `#expect` equality checks then fail with a clear
    /// short-received-fewer-than-sent mismatch rather than hanging.
    private static func collect(_ stream: AsyncStream<Frame>, count: Int) async -> [Frame] {
        var results: [Frame] = []
        var iterator = stream.makeAsyncIterator()
        for _ in 0..<count {
            guard let next = await iterator.next() else { break }
            results.append(next)
        }
        return results
    }

    private static func fingerprint(of key: Curve25519.Signing.PrivateKey) -> RemoteIdentityFingerprint {
        let pubkey = try! RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        return RemoteIdentityFingerprint(of: pubkey)
    }

    // MARK: - Ownership loopback driver (task 5)

    /// Opens ONE SSH-over-WebRTC connection and TWO `TerminalSessionClient`
    /// session channels on it (mirroring two iPads attached to the same
    /// graftty session over independent SSH connections closely enough for
    /// these scenarios — ownership is keyed by the coordinator's own
    /// per-channel `clientID`, not by connection identity). Both server-side
    /// channels share ONE `TestOwnershipStore` + `TestOwnershipBroadcaster`,
    /// exactly like production's single store/broadcaster shared across
    /// every `TerminalSessionHandler` on a `WebRTCHostAgent`
    /// (`SubsystemDispatcher.init`). `body` drives each client directly
    /// (`sendHello`/`takeControl`/`ownerResize`/`send`) and asserts on the
    /// `.ownership` envelopes each observes.
    private func runOwnershipLoopback(
        sessionName: String = "alpha",
        responseDeadline: Duration = .seconds(60),
        body: (TerminalSessionClient, TerminalSessionClient) async throws -> Void
    ) async throws {
        let store = TestOwnershipStore()
        let broadcaster = TestOwnershipBroadcaster()

        let connection = try await makeLoopbackConnection { childChannel, channelType in
            guard case .session = channelType else {
                return childChannel.eventLoop.makeFailedFuture(LoopbackError.unexpectedChannelType)
            }
            return childChannel.eventLoop.makeCompletedFuture {
                let h = TerminalSessionHandler(
                    streamFactory: { _ in EchoStream() },
                    store: store,
                    broadcaster: broadcaster
                )
                try childChannel.pipeline.syncOperations.addHandler(h)
            }
        }

        let clientA = TerminalSessionClient(
            parentChannel: connection.clientTransport.channel,
            parentHandler: connection.sshHandler,
            sessionName: sessionName
        )
        let clientB = TerminalSessionClient(
            parentChannel: connection.clientTransport.channel,
            parentHandler: connection.sshHandler,
            sessionName: sessionName
        )

        // Belt-and-suspenders deadline (same pattern as the other drivers
        // above) — force-closes both clients so any stuck `receive()` call
        // fails with `channelClosed` instead of hanging past the test's
        // own `.timeLimit`.
        let deadlineTask = Task { [clientA, clientB] in
            try? await Task.sleep(for: responseDeadline)
            clientA.close()
            clientB.close()
        }
        defer { deadlineTask.cancel() }

        try await clientA.connect()
        try await clientB.connect()

        // Run `body` via a captured Result so the teardown below executes
        // on BOTH exits — `defer` can't await the async transport closes,
        // and skipping them on a thrown assertion failure would leak live
        // WebRTC peer connections + NIO channels into subsequent tests
        // (noisier failures exactly when a real regression is present).
        let bodyResult: Result<Void, any Error>
        do {
            try await body(clientA, clientB)
            bodyResult = .success(())
        } catch {
            bodyResult = .failure(error)
        }

        clientA.close()
        clientB.close()
        await connection.close()

        try bodyResult.get()
    }

    // MARK: - Poisoned control-carrier loopback driver (task 6)

    /// Opens ONE `TerminalSessionClient` session channel against a bare
    /// server-side handler (`PoisonInjectingSessionHandler`) that acks the
    /// shell request — so `connect()` resolves exactly like a real
    /// attach — then immediately writes a single malformed `.stdErr`
    /// frame (a length prefix that overflows `StdErrControlFraming.maxFrameLength`)
    /// directly onto the wire, bypassing the coordinator entirely (the
    /// real coordinator/handler never emit malformed frames; this
    /// simulates a corrupted carrier the way a buggy peer or bit-flip
    /// would). Asserts the client's `receive()` observes `.channelClosed`
    /// — proving `InboundRelay` closed the child channel instead of
    /// silently dropping control parsing forever.
    private func runPoisonedControlFrameLoopback(
        responseDeadline: Duration = .seconds(20)
    ) async throws {
        let connection = try await makeLoopbackConnection { childChannel, channelType in
            guard case .session = channelType else {
                return childChannel.eventLoop.makeFailedFuture(LoopbackError.unexpectedChannelType)
            }
            return childChannel.eventLoop.makeCompletedFuture {
                try childChannel.pipeline.syncOperations.addHandler(PoisonInjectingSessionHandler())
            }
        }

        let client = TerminalSessionClient(
            parentChannel: connection.clientTransport.channel,
            parentHandler: connection.sshHandler,
            sessionName: "poison-test"
        )

        // Belt-and-suspenders deadline (same pattern as the other drivers
        // above) so a regression that silently drops the poisoned frame
        // (never closing the channel) fails fast instead of hanging past
        // the test's own `.timeLimit`.
        var deadlineFired = false
        let deadlineTask = Task { [client] in
            try? await Task.sleep(for: responseDeadline)
            deadlineFired = true
            client.close()
        }
        defer { deadlineTask.cancel() }

        try await client.connect()

        // Check that the channel closes due to InboundRelay's poison detection,
        // not via the deadline: if deadlineFired is true when we observe the
        // close, it means the timeout fell back to the belt-and-suspenders close
        // rather than reacting to the poisoned frame near-instantly.
        do {
            _ = try await client.receive()
            Issue.record("expected receive() to throw once the poisoned control frame closed the channel")
        } catch TerminalSessionClient.ClientError.channelClosed {
            #expect(
                !deadlineFired,
                "expected InboundRelay to close the channel promptly on poisoning, not via the test's own \(responseDeadline) belt-and-suspenders deadline"
            )
        } catch {
            Issue.record("expected .channelClosed, got \(error)")
        }

        client.close()
        await connection.close()
    }

    /// Drains `client.receive()` until a `.ownership` envelope satisfying
    /// `predicate` is observed, silently skipping any interleaved `.binary`
    /// terminal-byte frames or non-matching `.ownership` envelopes (e.g. a
    /// sibling client's unrelated attach broadcast). Relies on the driver's
    /// belt-and-suspenders deadline to bound how long this can block.
    private func nextOwnershipSnapshot(
        _ client: TerminalSessionClient,
        where predicate: (DisplayOwnershipSnapshot) -> Bool
    ) async throws -> DisplayOwnershipSnapshot {
        while true {
            let envelope = try await nextEnvelope(client)
            guard case let .ownership(snapshot) = envelope else { continue }
            if predicate(snapshot) { return snapshot }
        }
    }

    /// Returns the next frame from `client.receive()` that decodes as a
    /// `WebControlEnvelope`, skipping non-`.text` frames and undecodable
    /// text. Unlike `nextOwnershipSnapshot`, does not skip past envelopes
    /// that fail a caller predicate — callers needing "the very next
    /// thing, whatever it is" (e.g. proving a rejection didn't change
    /// anything) use this directly instead.
    private func nextEnvelope(_ client: TerminalSessionClient) async throws -> WebControlEnvelope {
        while true {
            let frame = try await client.receive()
            guard case let .text(text) = frame else { continue }
            if let envelope = try? WebControlEnvelope.parse(Data(text.utf8)) {
                return envelope
            }
        }
    }
}

// MARK: - Fakes / helpers

/// Result of `SSHTerminalLoopbackTests.makeLoopbackConnection`: everything a
/// `run*Loopback` driver needs to open its own channel(s) on top of an
/// already-handshaken SSH-over-WebRTC connection, plus a single `close()`
/// that tears the whole stack down in the order every driver used to repeat
/// by hand (transports, then the WebRTC peers underneath them).
private struct LoopbackConnection {
    let clientTransport: SSHNIOTransport
    let serverTransport: SSHNIOTransport
    let sshHandler: NIOSSHHandler
    let offerer: LoopbackPeer
    let answerer: LoopbackPeer

    func close() async {
        await clientTransport.close()
        await serverTransport.close()
        await offerer.close()
        await answerer.close()
    }
}

private enum FactoryError: Error { case notFound }

private final class EchoStream: TerminalByteStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>

    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func send(_ bytes: Data) async throws {
        continuation.yield(bytes)
    }

    func close() async {
        continuation.finish()
    }
}

// MARK: - Extended-data spike helpers (SSHChannelData carrier decision gate)

/// One recorded `SSHChannelData` frame: which stream it arrived on
/// (`.channel` vs `.stdErr`) and its payload bytes.
private struct Frame: Equatable, Sendable {
    let type: SSHChannelData.DataType
    let bytes: Data
}

/// Collects inbound `Frame`s in receipt order via an `AsyncStream`, so the
/// spike test can assert both content and ordering without polling.
private final class FrameCollector: @unchecked Sendable {
    private let continuation: AsyncStream<Frame>.Continuation
    let frames: AsyncStream<Frame>

    init() {
        var cont: AsyncStream<Frame>.Continuation!
        self.frames = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func record(_ frame: Frame) {
        continuation.yield(frame)
    }

    func finish() {
        continuation.finish()
    }
}

/// Records every inbound `SSHChannelData` frame on a session channel,
/// tagged by data type, without interpreting or echoing it. Used only by
/// `extendedDataFlowsBothDirectionsOnSessionChannel` to observe whether
/// `.channel` and `.stdErr` writes arrive intact, in order, and unmixed.
private final class FrameRecordingHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let collector: FrameCollector

    init(collector: FrameCollector) {
        self.collector = collector
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case let .byteBuffer(buf) = channelData.data else { return }
        var view = buf
        guard let bytes = view.readBytes(length: view.readableBytes) else { return }
        collector.record(Frame(type: channelData.type, bytes: Data(bytes)))
    }

    func channelInactive(context: ChannelHandlerContext) {
        collector.finish()
        context.fireChannelInactive()
    }
}

/// Server-side handler for `runPoisonedControlFrameLoopback`: acks the
/// shell request (so the client's `connect()` resolves exactly like a
/// real attach), then immediately writes a single malformed `.stdErr`
/// frame — a `u32 BE` length prefix that overflows
/// `StdErrControlFraming.maxFrameLength` — directly onto the
/// channel. Deliberately bypasses `WebControlEnvelope` encoding entirely;
/// the real coordinator/handler never emit malformed frames, so this
/// simulates a corrupted carrier (buggy peer, bit-flip) rather than any
/// real production code path.
private final class PoisonInjectingSessionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let shellEvent = event as? SSHChannelRequestEvent.ShellRequest {
            if shellEvent.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
            var buffer = context.channel.allocator.buffer(capacity: 4)
            buffer.writeBytes([0xFF, 0xFF, 0xFF, 0xFF])
            let data = SSHChannelData(type: .stdErr, data: .byteBuffer(buffer))
            context.writeAndFlush(wrapOutboundOut(data), promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Ignore all inbound bytes — this handler only ever injects the
        // one malformed frame above.
    }
}

// MARK: - Inlined TerminalSessionHandler (mirror of GrafttyHostAgent's production type, ownership included)
//
// `TerminalSessionHandler` lives in `GrafttyHostAgent`, which transitively
// pulls in `GrafttyKit`'s AppKit-importing files and is therefore not
// importable from this iOS-only test target. Likewise
// `SessionDisplayOwnershipStore`/`DisplayOwnershipBroadcaster`/
// `TerminalAttachCoordinator` live in `GrafttyKit` and are unavailable here
// too. The types below mirror the production shapes (see
// `Sources/GrafttyHostAgent/SSH/Channels/TerminalSessionHandler.swift`,
// `Sources/GrafttyKit/SessionDisplayOwnershipStore.swift`,
// `Sources/GrafttyKit/Remote/TerminalAttachCoordinator.swift`) closely
// enough to exercise task 5's SSH-terminal-ownership scenarios: hello/
// attach, takeControl eligibility, owner-gated binary writes, ownerResize,
// and localized ownership-snapshot broadcast. Per R3's precedent for the
// server-side userauth delegate — copy, don't extract; post-R6 work.

/// Test-local mirror of `GrafttyKit.SessionDisplayOwnershipStore`, trimmed
/// to the operations task 5's scenarios exercise (no
/// `restoreOwnerAfterFailedClaim`/`releaseOwner`/`claimOwnerIfOwnerlessOrCurrent`
/// — those back the Mac-host and legacy-resize paths, neither of which this
/// suite drives).
private final class TestOwnershipStore: @unchecked Sendable {
    struct ClaimResult { let accepted: Bool; let snapshot: DisplayOwnershipSnapshot }
    struct ResizeResult { let accepted: Bool; let snapshot: DisplayOwnershipSnapshot }

    private struct AttachedClient {
        var kind: DisplayClientKind
        var role: DisplayClientRole
        var visible: Bool

        func isOwnerEligible(claimingAs kind: DisplayClientKind) -> Bool {
            self.kind == kind && self.kind != .preview && role != .preview && visible
        }
    }

    private struct Record {
        var ownerClientID: DisplayClientID?
        var ownerKind: DisplayClientKind?
        var grid: DisplayGrid?
        var epoch: UInt64 = 0
        var revision: UInt64 = 0
        var attachedClients: [DisplayClientID: AttachedClient] = [:]
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]

    func attachClient(
        sessionName: String,
        clientID: DisplayClientID,
        kind: DisplayClientKind,
        role: DisplayClientRole,
        visible: Bool,
        grid: DisplayGrid
    ) -> DisplayOwnershipSnapshot {
        lock.lock(); defer { lock.unlock() }
        var record = records[sessionName] ?? Record()
        record.attachedClients[clientID] = AttachedClient(kind: kind, role: role, visible: visible)
        record.revision += 1
        records[sessionName] = record
        return snapshot(sessionName: sessionName, record: record, fallbackGrid: grid)
    }

    func claimOwner(
        sessionName: String,
        clientID: DisplayClientID,
        kind: DisplayClientKind,
        grid: DisplayGrid
    ) -> ClaimResult {
        lock.lock(); defer { lock.unlock() }
        var record = records[sessionName] ?? Record()
        guard let attached = record.attachedClients[clientID], attached.isOwnerEligible(claimingAs: kind) else {
            return ClaimResult(accepted: false, snapshot: snapshot(sessionName: sessionName, record: record, fallbackGrid: grid))
        }
        let ownerChanged = record.ownerClientID != clientID || record.ownerKind != kind
        record.ownerClientID = clientID
        record.ownerKind = kind
        record.grid = grid
        if ownerChanged { record.epoch += 1 }
        record.revision += 1
        records[sessionName] = record
        return ClaimResult(accepted: true, snapshot: snapshot(sessionName: sessionName, record: record, fallbackGrid: grid))
    }

    func ownerResize(
        sessionName: String,
        clientID: DisplayClientID,
        epoch: UInt64,
        grid: DisplayGrid
    ) -> ResizeResult {
        lock.lock(); defer { lock.unlock() }
        var record = records[sessionName] ?? Record()
        let accepted = record.ownerClientID == clientID && record.epoch == epoch
        if accepted {
            record.grid = grid
            record.revision += 1
            records[sessionName] = record
        }
        return ResizeResult(accepted: accepted, snapshot: snapshot(sessionName: sessionName, record: record, fallbackGrid: .daemonFallback))
    }

    func detachClient(sessionName: String, clientID: DisplayClientID, fallbackGrid: DisplayGrid) -> DisplayOwnershipSnapshot {
        lock.lock(); defer { lock.unlock() }
        var record = records[sessionName] ?? Record()
        record.attachedClients.removeValue(forKey: clientID)
        if record.ownerClientID == clientID {
            record.ownerClientID = nil
            record.ownerKind = nil
            record.epoch += 1
            record.revision += 1
        }
        let result = snapshot(sessionName: sessionName, record: record, fallbackGrid: fallbackGrid)
        if record.ownerClientID == nil, record.grid == nil, record.attachedClients.isEmpty {
            records.removeValue(forKey: sessionName)
        } else {
            records[sessionName] = record
        }
        return result
    }

    func snapshot(sessionName: String, fallbackGrid: DisplayGrid = .daemonFallback) -> DisplayOwnershipSnapshot {
        lock.lock(); defer { lock.unlock() }
        let record = records[sessionName] ?? Record()
        return snapshot(sessionName: sessionName, record: record, fallbackGrid: fallbackGrid)
    }

    private func snapshot(sessionName: String, record: Record, fallbackGrid: DisplayGrid) -> DisplayOwnershipSnapshot {
        try! DisplayOwnershipSnapshot(
            sessionName: sessionName,
            ownerClientID: record.ownerClientID,
            ownerKind: record.ownerKind,
            grid: record.grid ?? fallbackGrid,
            epoch: record.epoch,
            revision: record.revision
        )
    }
}

/// Test-local mirror of `GrafttyKit.DisplayOwnershipBroadcaster`, trimmed to
/// direct `register`/`broadcast` (no store-observer subscription — that
/// bridges Mac-host-originated mutations, which this suite never performs;
/// `TestAttachCoordinator` always broadcasts explicitly right after
/// mutating the store, exactly like the production coordinator does).
private final class TestOwnershipBroadcaster: @unchecked Sendable {
    private struct Subscriber { let send: @Sendable (DisplayOwnershipSnapshot) -> Void }
    private let lock = NSLock()
    private var subscribers: [String: [UUID: Subscriber]] = [:]

    func register(sessionName: String, send: @escaping @Sendable (DisplayOwnershipSnapshot) -> Void) -> () -> Void {
        let id = UUID()
        lock.lock()
        var sessionSubscribers = subscribers[sessionName] ?? [:]
        sessionSubscribers[id] = Subscriber(send: send)
        subscribers[sessionName] = sessionSubscribers
        lock.unlock()
        return { [weak self] in self?.unregister(sessionName: sessionName, id: id) }
    }

    func broadcast(_ snapshot: DisplayOwnershipSnapshot) {
        lock.lock()
        let sends = subscribers[snapshot.sessionName]?.values.map(\.send) ?? []
        lock.unlock()
        for send in sends { send(snapshot) }
    }

    private func unregister(sessionName: String, id: UUID) {
        lock.lock()
        subscribers[sessionName]?.removeValue(forKey: id)
        lock.unlock()
    }
}

/// Test-local mirror of `GrafttyKit.TerminalAttachCoordinator`, trimmed to
/// the `.hello`/`.takeControl`/`.ownerResize`/binary-write/detach seams
/// task 5's scenarios exercise (no PTY-size push, no legacy `.resize`
/// handling — this test double's clients always speak the control
/// carrier, unlike the production server which must also serve pre-hello
/// legacy clients on the same handler).
private final class TestAttachCoordinator: @unchecked Sendable {
    private let sessionName: String
    private let clientID: DisplayClientID
    private let defaultKind: DisplayClientKind
    private let store: TestOwnershipStore
    private let broadcaster: TestOwnershipBroadcaster
    private let sendText: @Sendable (String) -> Void
    private let write: @Sendable (Data) -> Void
    private let lock = NSLock()

    private var unregister: (() -> Void)?
    private var boundProtocolClientID: DisplayClientID?
    private var attachedKind: DisplayClientKind?
    private var attached = false
    private var detached = false

    init(
        sessionName: String,
        clientID: DisplayClientID,
        defaultKind: DisplayClientKind,
        store: TestOwnershipStore,
        broadcaster: TestOwnershipBroadcaster,
        sendText: @escaping @Sendable (String) -> Void,
        write: @escaping @Sendable (Data) -> Void
    ) {
        self.sessionName = sessionName
        self.clientID = clientID
        self.defaultKind = defaultKind
        self.store = store
        self.broadcaster = broadcaster
        self.sendText = sendText
        self.write = write
        self.unregister = broadcaster.register(sessionName: sessionName) { [weak self] snapshot in
            self?.sendOwnershipSnapshot(snapshot)
        }
    }

    func handleControl(_ envelope: WebControlEnvelope) {
        switch envelope {
        case let .hello(protocolClientID, _, role, visible, cols, rows):
            guard bindOrVerify(protocolClientID) else { return }
            let kind = defaultKind
            let grid = try! DisplayGrid(cols: cols, rows: rows)
            lock.lock(); attached = true; attachedKind = kind; lock.unlock()
            let snapshot = store.attachClient(
                sessionName: sessionName,
                clientID: clientID,
                kind: kind,
                role: role,
                visible: visible,
                grid: grid
            )
            broadcaster.broadcast(snapshot)

        case let .takeControl(protocolClientID, _, cols, rows):
            guard bindOrVerify(protocolClientID) else { return }
            let kind = currentKind() ?? defaultKind
            let grid = try! DisplayGrid(cols: cols, rows: rows)
            // Production parity: TerminalAttachCoordinator defensively
            // attaches a client that takes control without a prior hello.
            ensureAttached(kind: kind, grid: grid)
            let result = store.claimOwner(sessionName: sessionName, clientID: clientID, kind: kind, grid: grid)
            broadcaster.broadcast(result.snapshot)

        case let .ownerResize(protocolClientID, epoch, cols, rows):
            guard bindOrVerify(protocolClientID) else { return }
            let grid = try! DisplayGrid(cols: cols, rows: rows)
            let result = store.ownerResize(sessionName: sessionName, clientID: clientID, epoch: epoch, grid: grid)
            broadcaster.broadcast(result.snapshot)

        case .resize, .grid, .ownership:
            break
        }
    }

    func handleBinary(_ data: Data) {
        if isCurrentOwner() {
            write(data)
            return
        }
        broadcaster.broadcast(store.snapshot(sessionName: sessionName))
    }

    func detach() {
        lock.lock()
        if detached { lock.unlock(); return }
        detached = true
        let wasAttached = attached
        let cancel = unregister
        unregister = nil
        lock.unlock()
        cancel?()
        guard wasAttached else { return }
        let snapshot = store.detachClient(sessionName: sessionName, clientID: clientID, fallbackGrid: .daemonFallback)
        broadcaster.broadcast(snapshot)
    }

    /// Production parity with `TerminalAttachCoordinator.ensureAttached`:
    /// registers this client in the store on first contact if `.hello`
    /// hasn't already done so (a client may `.takeControl` first).
    private func ensureAttached(kind: DisplayClientKind, grid: DisplayGrid) {
        lock.lock()
        if attached {
            lock.unlock()
            return
        }
        attached = true
        attachedKind = kind
        lock.unlock()
        let snapshot = store.attachClient(
            sessionName: sessionName,
            clientID: clientID,
            kind: kind,
            role: .interactive,
            visible: true,
            grid: grid
        )
        broadcaster.broadcast(snapshot)
    }

    private func bindOrVerify(_ protocolClientID: DisplayClientID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if protocolClientID == clientID { return true }
        if let boundProtocolClientID { return boundProtocolClientID == protocolClientID }
        boundProtocolClientID = protocolClientID
        return true
    }

    private func currentKind() -> DisplayClientKind? {
        lock.lock(); defer { lock.unlock() }
        return attachedKind
    }

    private func isCurrentOwner() -> Bool {
        store.snapshot(sessionName: sessionName).ownerClientID == clientID
    }

    private func sendOwnershipSnapshot(_ snapshot: DisplayOwnershipSnapshot) {
        sendText(WebControlEnvelope.ownership(localizedSnapshot(snapshot)).encoded())
    }

    /// Mirrors `TerminalAttachCoordinator.localizedSnapshot`: rewrites the
    /// server-internal `ownerClientID` into the recipient's own
    /// protocol-level clientID when the recipient IS the owner (so
    /// `ownershipSnapshot?.ownerClientID == displayClientID` matches on
    /// the client, per `SessionClient.isOwner`); any other owner's
    /// internal ID is left as-is.
    private func localizedSnapshot(_ snapshot: DisplayOwnershipSnapshot) -> DisplayOwnershipSnapshot {
        guard let ownerClientID = snapshot.ownerClientID else { return snapshot }
        let protocolClientID = currentProtocolClientID()
        let localizedOwnerID: DisplayClientID
        if ownerClientID == clientID {
            localizedOwnerID = protocolClientID ?? ownerClientID
        } else if ownerClientID == protocolClientID {
            localizedOwnerID = DisplayClientID("remote-owner:\(ownerClientID.rawValue)")
        } else {
            localizedOwnerID = ownerClientID
        }
        return try! DisplayOwnershipSnapshot(
            sessionName: snapshot.sessionName,
            ownerClientID: localizedOwnerID,
            ownerKind: snapshot.ownerKind,
            grid: snapshot.grid,
            epoch: snapshot.epoch,
            revision: snapshot.revision
        )
    }

    private func currentProtocolClientID() -> DisplayClientID? {
        lock.lock(); defer { lock.unlock() }
        return boundProtocolClientID
    }
}

fileprivate final class TerminalSessionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let streamFactory: @Sendable (String) async throws -> TerminalByteStream
    private let store: TestOwnershipStore
    private let broadcaster: TestOwnershipBroadcaster
    private let deviceID: String
    private var envSessionName: String?
    private var ptyAccepted = false
    private var stream: TerminalByteStream?
    private var coordinator: TestAttachCoordinator?
    private var inboundForwardingTask: Task<Void, Never>?
    private var isShuttingDown = false
    /// See the production handler's `helloLock` doc comment — same
    /// rationale (`sendText` reads this from the broadcaster fan-out
    /// path, which can fire from a sibling channel's mutation).
    private let helloLock = NSLock()
    private var _receivedHello = false
    private var receivedHello: Bool {
        get { helloLock.lock(); defer { helloLock.unlock() }; return _receivedHello }
        set { helloLock.lock(); defer { helloLock.unlock() }; _receivedHello = newValue }
    }
    private var stdErrDecoder = StdErrControlFraming.Decoder()
    private var stdErrPoisoned = false
    private var ptyWriteContinuation: AsyncStream<Data>.Continuation?
    private var ptyWriterTask: Task<Void, Never>?

    init(
        streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream,
        store: TestOwnershipStore = TestOwnershipStore(),
        broadcaster: TestOwnershipBroadcaster = TestOwnershipBroadcaster(),
        deviceID: String = "test-device"
    ) {
        self.streamFactory = streamFactory
        self.store = store
        self.broadcaster = broadcaster
        self.deviceID = deviceID
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case let .byteBuffer(buf) = channelData.data else { return }
        var view = buf
        guard let bytes = view.readBytes(length: view.readableBytes) else { return }

        switch channelData.type {
        case .stdErr:
            ingestStdErr(Data(bytes), channel: context.channel)
        default:
            guard stream != nil else { return }
            let payload = Data(bytes)
            if receivedHello, let coordinator {
                coordinator.handleBinary(payload)
            } else {
                ptyWriteContinuation?.yield(payload)
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let envEvent as SSHChannelRequestEvent.EnvironmentRequest:
            if envEvent.name == "GRAFTTY_SESSION" {
                envSessionName = envEvent.value
            }
            if envEvent.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }

        case let ptyEvent as SSHChannelRequestEvent.PseudoTerminalRequest:
            ptyAccepted = true
            if ptyEvent.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }

        case let shellEvent as SSHChannelRequestEvent.ShellRequest:
            guard let name = envSessionName else {
                if shellEvent.wantReply {
                    context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                }
                context.close(promise: nil)
                return
            }
            attach(context: context, sessionName: name, wantReply: shellEvent.wantReply)

        case let winEvent as SSHChannelRequestEvent.WindowChangeRequest:
            guard stream != nil else { return }
            let cols = winEvent.terminalCharacterWidth
            let rows = winEvent.terminalRowHeight
            if receivedHello, let coordinator {
                guard
                    let gridCols = UInt16(exactly: cols), gridCols > 0,
                    let gridRows = UInt16(exactly: rows), gridRows > 0
                else { return }
                coordinator.handleControl(.resize(cols: gridCols, rows: gridRows))
            } else {
                let snapshot = stream
                Task { [snapshot] in await snapshot?.resize(cols: cols, rows: rows) }
            }

        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        isShuttingDown = true
        inboundForwardingTask?.cancel()
        ptyWriteContinuation?.finish()
        ptyWriteContinuation = nil
        ptyWriterTask = nil
        let snapshot = stream
        stream = nil
        let coordinatorSnapshot = coordinator
        coordinator = nil
        coordinatorSnapshot?.detach()
        Task { [snapshot] in
            await snapshot?.close()
        }
        context.fireChannelInactive()
    }

    private func attach(context: ChannelHandlerContext, sessionName: String, wantReply: Bool) {
        let factory = streamFactory
        let channel = context.channel
        let loop = context.eventLoop
        let pipeline = context.pipeline

        Task { [weak self] in
            do {
                let stream = try await factory(sessionName)
                loop.execute { [weak self] in
                    guard let self else {
                        Task { await stream.close() }
                        return
                    }
                    if self.isShuttingDown {
                        Task { await stream.close() }
                        return
                    }
                    self.stream = stream
                    self.startPTYWriter(stream: stream)
                    self.installCoordinator(sessionName: sessionName, channel: channel, loop: loop)
                    if wantReply {
                        pipeline.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
                    }
                    self.startInboundForwarding(stream: stream, channel: channel, loop: loop)
                }
            } catch {
                loop.execute {
                    if wantReply {
                        pipeline.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                    }
                    let exit = SSHChannelRequestEvent.ExitStatus(exitStatus: 1)
                    pipeline.triggerUserOutboundEvent(exit, promise: nil)
                    channel.close(promise: nil)
                }
            }
        }
    }

    private func startPTYWriter(stream: TerminalByteStream) {
        var continuation: AsyncStream<Data>.Continuation!
        let pipe = AsyncStream<Data> { continuation = $0 }
        ptyWriteContinuation = continuation
        ptyWriterTask = Task {
            for await chunk in pipe {
                try? await stream.send(chunk)
            }
        }
    }

    private func installCoordinator(sessionName: String, channel: Channel, loop: EventLoop) {
        let clientID = DisplayClientID("ssh-\(deviceID)-\(UUID().uuidString.prefix(8))")
        let coordinator = TestAttachCoordinator(
            sessionName: sessionName,
            clientID: clientID,
            defaultKind: .ios,
            store: store,
            broadcaster: broadcaster,
            sendText: { [weak self] payload in
                guard let self, self.receivedHello else { return }
                guard let framed = StdErrControlFraming.encode(payload) else { return }
                loop.execute {
                    var buffer = channel.allocator.buffer(capacity: framed.count)
                    buffer.writeBytes(framed)
                    let data = SSHChannelData(type: .stdErr, data: .byteBuffer(buffer))
                    channel.writeAndFlush(data, promise: nil)
                }
            },
            write: { [weak self] data in
                self?.ptyWriteContinuation?.yield(data)
            }
        )
        self.coordinator = coordinator
        drainControlFrames(channel: channel)
    }

    private func startInboundForwarding(stream: TerminalByteStream, channel: Channel, loop: EventLoop) {
        let task = Task {
            for await chunk in stream.inboundBytes {
                let buffer = channel.allocator.buffer(bytes: chunk)
                let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
                loop.execute {
                    channel.writeAndFlush(data, promise: nil)
                }
            }
        }
        inboundForwardingTask = task
    }

    // MARK: - `.stdErr` control-frame framing (mirrors TerminalSessionHandler,
    // via the shared StdErrControlFraming codec)

    private func ingestStdErr(_ data: Data, channel: Channel) {
        guard !stdErrPoisoned else { return }
        stdErrDecoder.append(data)
        if coordinator != nil {
            drainControlFrames(channel: channel)
        }
        if stdErrDecoder.isOverAccumulated {
            poisonStdErr(channel: channel)
        }
    }

    private func drainControlFrames(channel: Channel) {
        let (frames, oversized) = stdErrDecoder.drain()
        for payload in frames {
            guard let envelope = try? WebControlEnvelope.parse(payload) else { continue }
            if case .hello = envelope {
                receivedHello = true
            }
            guard receivedHello else { continue }
            coordinator?.handleControl(envelope)
        }
        if oversized {
            poisonStdErr(channel: channel)
        }
    }

    private func poisonStdErr(channel: Channel) {
        stdErrPoisoned = true
        stdErrDecoder.reset()
        guard receivedHello else { return }
        channel.close(promise: nil)
    }
}

// MARK: - Copied SSH+WebRTC helpers from R3's SSHAuthLoopbackTests
//
// Each helper below is a verbatim copy of the corresponding type in
// `SSHAuthLoopbackTests.swift`. Per R3's precedent (and the parent
// design's "copy don't extract" approach), the dup is intentional;
// consolidation happens post-R6 when a shared fixture can replace
// both files.

fileprivate final class InMemoryTrustedPeerSet: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprints: Set<RemoteIdentityFingerprint> = []
    private var lookupError: (any Error)?

    func add(fingerprint: RemoteIdentityFingerprint) {
        lock.lock(); defer { lock.unlock() }
        fingerprints.insert(fingerprint)
    }

    func get(fingerprint: RemoteIdentityFingerprint) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let error = lookupError { throw error }
        return fingerprints.contains(fingerprint)
    }

    func injectLookupError(_ error: any Error) {
        lock.lock(); defer { lock.unlock() }
        lookupError = error
    }
}

fileprivate struct TrustSetServerUserAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey

    let store: InMemoryTrustedPeerSet

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        switch request.request {
        case .publicKey(let publicKeyRequest):
            do {
                let fp = try Self.fingerprint(of: publicKeyRequest.publicKey)
                if try store.get(fingerprint: fp) {
                    responsePromise.succeed(.success)
                } else {
                    responsePromise.succeed(.failure)
                }
            } catch {
                responsePromise.succeed(.failure)
            }
        case .password, .hostBased, .none:
            responsePromise.succeed(.failure)
        @unknown default:
            responsePromise.succeed(.failure)
        }
    }

    static func fingerprint(of key: NIOSSHPublicKey) throws -> RemoteIdentityFingerprint {
        let openSSH = String(openSSHPublicKey: key)
        let components = openSSH.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard components.count >= 2 else {
            throw FingerprintError.unsupportedKeyFormat
        }
        guard let rawBytes = Data(base64Encoded: String(components[1])) else {
            throw FingerprintError.unsupportedKeyFormat
        }

        var buffer = ByteBufferAllocator().buffer(capacity: rawBytes.count)
        buffer.writeContiguousBytes(rawBytes)

        guard
            let typeLen: UInt32 = buffer.readInteger(),
            let typeBytes = buffer.readBytes(length: Int(typeLen)),
            let typeName = String(bytes: typeBytes, encoding: .utf8),
            typeName == "ssh-ed25519",
            let keyLen: UInt32 = buffer.readInteger(),
            keyLen == 32,
            let keyBytes = buffer.readBytes(length: 32)
        else {
            throw FingerprintError.unsupportedKeyFormat
        }

        let pubkey = try RemoteIdentityPublicKey(rawRepresentation: Data(keyBytes))
        return RemoteIdentityFingerprint(of: pubkey)
    }

    enum FingerprintError: Error { case unsupportedKeyFormat }
}

fileprivate enum LoopbackError: Error {
    case unexpectedChannelType
    case dataChannelNeverOpened
    case timedOut
    case channelInactiveBeforeResponse
}

fileprivate actor LoopbackPeer: WebRTCIceCandidateReceiver {
    enum Role { case offerer, answerer }

    private let role: Role
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private nonisolated let pcDelegate = LoopbackPeerConnectionDelegate()

    private var pendingLocalCandidates: [RTCIceCandidate] = []
    private var iceCandidateTarget: WebRTCIceCandidateReceiver?

    private var gatheringContinuation: CheckedContinuation<Void, Never>?
    private var gatheringTimeoutTask: Task<Void, Never>?
    private var openContinuation: CheckedContinuation<RTCDataChannel, Error>?
    private var resolvedOpenDataChannel: RTCDataChannel?

    private static let gatheringTimeout: Duration = .seconds(5)

    init(role: Role) {
        self.role = role
        self.factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        pcDelegate.onIceCandidate = { [weak self] candidate in
            Task { await self?.routeLocalIceCandidate(candidate) }
        }
        pcDelegate.onDataChannel = { [weak self] dc in
            Task { await self?.adoptInboundDataChannel(dc) }
        }
    }

    func createOffer() async throws -> RTCSessionDescription {
        precondition(role == .offerer)
        let config = RemoteHostConnection.defaultConfig()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: pcDelegate) else {
            throw NSError(domain: "LoopbackPeer", code: 1)
        }
        self.peerConnection = pc

        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        guard let dc = pc.dataChannel(forLabel: "graftty-ssh", configuration: dcConfig) else {
            throw NSError(domain: "LoopbackPeer", code: 2)
        }
        self.dataChannel = dc
        installOpenTracker(on: dc)

        let offer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.offer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: NSError(domain: "LoopbackPeer", code: 3)); return }
                continuation.resume(returning: sdp)
            }
        }
        try await Self.setLocalDescription(pc, offer)
        await waitForIceGatheringComplete(pc)
        return pc.localDescription ?? offer
    }

    func accept(offer: RTCSessionDescription) async throws -> RTCSessionDescription {
        precondition(role == .answerer)
        let config = RemoteHostConnection.defaultConfig()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: pcDelegate) else {
            throw NSError(domain: "LoopbackPeer", code: 4)
        }
        self.peerConnection = pc

        try await Self.setRemoteDescription(pc, offer)
        let answer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.answer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: NSError(domain: "LoopbackPeer", code: 5)); return }
                continuation.resume(returning: sdp)
            }
        }
        try await Self.setLocalDescription(pc, answer)
        await waitForIceGatheringComplete(pc)
        return pc.localDescription ?? answer
    }

    func applyAnswer(_ answer: RTCSessionDescription) async throws {
        precondition(role == .offerer)
        guard let pc = peerConnection else { throw NSError(domain: "LoopbackPeer", code: 6) }
        try await Self.setRemoteDescription(pc, answer)
    }

    func openedDataChannel() async throws -> RTCDataChannel {
        if let dc = resolvedOpenDataChannel { return dc }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCDataChannel, Error>) in
            self.openContinuation = continuation
        }
    }

    func bindIceCandidates(to peer: WebRTCIceCandidateReceiver) {
        self.iceCandidateTarget = peer
        let drained = pendingLocalCandidates
        pendingLocalCandidates.removeAll()
        Task {
            for candidate in drained {
                try? await peer.addRemoteIceCandidate(candidate)
            }
        }
    }

    private func routeLocalIceCandidate(_ candidate: RTCIceCandidate) {
        if let target = iceCandidateTarget {
            Task { try? await target.addRemoteIceCandidate(candidate) }
        } else {
            pendingLocalCandidates.append(candidate)
        }
    }

    func addRemoteIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func adoptInboundDataChannel(_ dc: RTCDataChannel) {
        self.dataChannel = dc
        installOpenTracker(on: dc)
    }

    private nonisolated(unsafe) var currentOpenTracker: OpenTrackerDelegate?

    private func installOpenTracker(on dc: RTCDataChannel) {
        let tracker = OpenTrackerDelegate()
        tracker.onOpen = { [weak self] in
            Task { await self?.handleDataChannelOpen(dc) }
        }
        if dc.readyState == .open {
            Task { await self.handleDataChannelOpen(dc) }
        }
        dc.delegate = tracker
        self.currentOpenTracker = tracker
    }

    private func handleDataChannelOpen(_ dc: RTCDataChannel) {
        guard resolvedOpenDataChannel == nil else { return }
        resolvedOpenDataChannel = dc
        if let continuation = openContinuation {
            openContinuation = nil
            continuation.resume(returning: dc)
        }
        currentOpenTracker = nil
    }

    private func waitForIceGatheringComplete(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.gatheringContinuation = continuation
            pcDelegate.onIceGatheringComplete = { [weak self] in
                Task { await self?.handleIceGatheringComplete() }
            }
            if pc.iceGatheringState == .complete {
                handleIceGatheringComplete()
                return
            }
            self.gatheringTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.gatheringTimeout)
                await self?.handleIceGatheringComplete()
            }
        }
    }

    private func handleIceGatheringComplete() {
        let pending = gatheringContinuation
        gatheringContinuation = nil
        pcDelegate.onIceGatheringComplete = nil
        gatheringTimeoutTask?.cancel()
        gatheringTimeoutTask = nil
        pending?.resume()
    }

    func close() {
        if let pending = gatheringContinuation {
            gatheringContinuation = nil
            pcDelegate.onIceGatheringComplete = nil
            gatheringTimeoutTask?.cancel()
            gatheringTimeoutTask = nil
            pending.resume()
        }
        if let pending = openContinuation {
            openContinuation = nil
            pending.resume(throwing: LoopbackError.dataChannelNeverOpened)
        }
        dataChannel?.close()
        peerConnection?.close()
        iceCandidateTarget = nil
        pendingLocalCandidates.removeAll()
    }

    private static func setLocalDescription(_ pc: RTCPeerConnection, _ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func setRemoteDescription(_ pc: RTCPeerConnection, _ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

fileprivate final class LoopbackPeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onIceCandidate: (@Sendable (RTCIceCandidate) -> Void)?
    nonisolated(unsafe) var onDataChannel: (@Sendable (RTCDataChannel) -> Void)?
    nonisolated(unsafe) var onIceGatheringComplete: (@Sendable () -> Void)?
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { onIceGatheringComplete?() }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onIceCandidate?(candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        onDataChannel?(dataChannel)
    }
}

fileprivate final class OpenTrackerDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onOpen: (@Sendable () -> Void)?
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open { onOpen?() }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {}
}
#endif

#if canImport(UIKit)
import CryptoKit
import Foundation
import GrafttyProtocol
import NIOCore
import NIOSSH
import Testing
import GrafttyRemoteTestSupport
import WebRTC
@testable import GrafttyRemoteClient
import GrafttyTunnel

/// End-to-end SSH-over-WebRTC loopback tests for the R5 panes-state and
/// pane-control channel types.
///
/// Exercises both `PanesStateChannelClient` and `PaneControlChannelClient`
/// against an inline server-side implementation that mirrors
/// `PanesStateChannelHandler` and `PaneControlChannelHandler` from
/// `GrafttyHostAgent`. Those types can't be imported directly because
/// `GrafttyHostAgent` transitively depends on `GrafttyKit`'s AppKit-importing
/// files. The inline implementation is a deliberate copy per the R3/R4
/// "copy don't extract" precedent; consolidation happens post-R6.
///
/// Also exercises the Task 2 userauth-time capability gate: a peer with
/// `terminalControl: .disabled` cannot complete SSH userauth.
///
/// `.serialized` per R3/R4 precedent — one SSH-over-WebRTC stack at a
/// time on the iOS Simulator's resource-constrained runtime.
@Suite(
    "SSH-over-WebRTC panes-state + pane-control loopback (R5)",
    .serialized
)
struct SSHPanesAndControlLoopbackTests {

    // MARK: - Test 1: panes-state snapshot round-trip

    @Test(.timeLimit(.minutes(3)))
    func panesStateSnapshotRoundTrip() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(
            fingerprint: Self.fingerprint(of: clientKey),
            terminalControl: .allowed
        )

        let snapshot = makeWorktrees(count: 2)
        let subscribe: TestPanesStateSubscribe = { onChange in
            await onChange(snapshot)
            return TestCancellable(cancel: {})
        }
        let mutator: TestPaneControlMutator = { _ in .ok }

        let received = try await runPanesStateLoopback(
            serverKey: serverKey,
            trustedPeers: peerStore,
            clientKey: clientKey,
            expectedHostFingerprint: Self.fingerprint(of: serverKey),
            subscribe: subscribe,
            mutator: mutator
        )

        #expect(received == snapshot)
    }

    // MARK: - Test 2: pane-control RPC round-trip

    @Test(.timeLimit(.minutes(3)))
    func paneControlRpcRoundTrip() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(
            fingerprint: Self.fingerprint(of: clientKey),
            terminalControl: .allowed
        )

        let subscribe: TestPanesStateSubscribe = { _ in TestCancellable(cancel: {}) }
        let mutator: TestPaneControlMutator = { request in
            if case .split = request { return .ok }
            return .error(code: "unexpected", message: "test only handles split")
        }

        let response = try await runPaneControlLoopback(
            serverKey: serverKey,
            trustedPeers: peerStore,
            clientKey: clientKey,
            expectedHostFingerprint: Self.fingerprint(of: serverKey),
            subscribe: subscribe,
            mutator: mutator,
            request: .split(target: "session-a", direction: .down)
        )

        #expect(response == .ok)
    }

    // MARK: - Test 3: unauthorized peer rejected at userauth

    @Test(.timeLimit(.minutes(3)))
    func peerWithoutTerminalControlCannotConnect() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(
            fingerprint: Self.fingerprint(of: clientKey),
            terminalControl: .disabled  // <- key difference
        )

        let subscribe: TestPanesStateSubscribe = { _ in TestCancellable(cancel: {}) }
        let mutator: TestPaneControlMutator = { _ in .ok }

        await #expect(throws: Error.self) {
            _ = try await runPanesStateLoopback(
                serverKey: serverKey,
                trustedPeers: peerStore,
                clientKey: clientKey,
                expectedHostFingerprint: Self.fingerprint(of: serverKey),
                subscribe: subscribe,
                mutator: mutator,
                responseDeadline: .seconds(10)
            )
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func panesStateNegotiationObservesUnknownSubsystemRejection() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let peerStore = InMemoryTrustedPeerSet()
        peerStore.add(
            fingerprint: Self.fingerprint(of: clientKey),
            terminalControl: .allowed
        )

        do {
            _ = try await runPanesStateLoopback(
                serverKey: serverKey,
                trustedPeers: peerStore,
                clientKey: clientKey,
                expectedHostFingerprint: Self.fingerprint(of: serverKey),
                subscribe: { _ in TestCancellable(cancel: {}) },
                mutator: { _ in .ok },
                responseDeadline: .seconds(20),
                subsystemName: "unknown-panes-state@graftty.dev",
                requestReply: true
            )
            Issue.record("expected the unknown subsystem to be rejected")
        } catch let error as PanesStateChannelClient.ClientError {
            guard case .openFailed(let underlying) = error,
                  let underlying = underlying
                    as? PanesStateChannelClient.ClientError,
                  case .subsystemRejected = underlying else {
                Issue.record(
                    "expected an explicit subsystem rejection, got \(error)"
                )
                return
            }
        } catch {
            Issue.record("expected a panes-state client error, got \(error)")
        }
    }

    // MARK: - Loopback drivers

    /// Builds a loopback, opens a panes-state channel, waits for the first
    /// snapshot to be delivered, returns it.
    private func runPanesStateLoopback(
        serverKey: Curve25519.Signing.PrivateKey,
        trustedPeers: InMemoryTrustedPeerSet,
        clientKey: Curve25519.Signing.PrivateKey,
        expectedHostFingerprint: RemoteIdentityFingerprint,
        subscribe: @escaping TestPanesStateSubscribe,
        mutator: @escaping TestPaneControlMutator,
        responseDeadline: Duration = .seconds(180),
        subsystemName: String = SSHChannelTypeNames.panesState,
        requestReply: Bool = false
    ) async throws -> [WorktreePanes] {
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

        // Server: NIOSSHHandler with inline SubsystemRouter
        try await serverTransport.eventLoop.submit {
            let serverConfig = SSHServerConfiguration(
                hostKeys: [NIOSSHPrivateKey(ed25519Key: serverKey)],
                userAuthDelegate: TrustSetServerUserAuthDelegate(store: trustedPeers)
            )
            let sshHandler = NIOSSHHandler(
                role: .server(serverConfig),
                allocator: serverTransport.channel.allocator,
                inboundChildChannelInitializer: { childChannel, channelType in
                    guard case .session = channelType else {
                        return childChannel.eventLoop.makeFailedFuture(LoopbackError.unexpectedChannelType)
                    }
                    return childChannel.eventLoop.makeCompletedFuture {
                        let router = TestSubsystemRouter(
                            subscribe: subscribe,
                            mutator: mutator
                        )
                        try childChannel.pipeline.syncOperations.addHandler(router)
                    }
                }
            )
            try serverTransport.channel.pipeline.syncOperations.addHandler(sshHandler)
        }.get()

        // Client: real SSHClientSetup
        let handlerPromise = clientTransport.eventLoop.makePromise(of: NIOSSHHandler.self)
        try await clientTransport.eventLoop.submit {
            let h = SSHClientSetup.makeHandler(
                clientKey: clientKey,
                expectedHostFingerprint: expectedHostFingerprint,
                allocator: clientTransport.channel.allocator
            )
            try clientTransport.channel.pipeline.syncOperations.addHandler(h)
            handlerPromise.succeed(h)
        }.get()
        let sshHandler = try await handlerPromise.futureResult.get()

        try await serverTransport.start()
        try await clientTransport.start()

        // Open panes-state channel via PanesStateChannelClient
        let snapshotBox = SnapshotBox()
        let client = PanesStateChannelClient(
            parentChannel: clientTransport.channel,
            parentHandler: sshHandler,
            subsystemName: subsystemName,
            requestReply: requestReply,
            onSnapshot: { snapshots in await snapshotBox.set(snapshots) },
            onClosed: { _ in await snapshotBox.fail(LoopbackError.channelClosedBeforeSnapshot) }
        )

        let deadlineTask = Task { [snapshotBox] in
            try? await Task.sleep(for: responseDeadline)
            // Fail the snapshot box so snapshotBox.wait() unblocks, then
            // close the transport so any pending client.open() future
            // fails (NIOSSH won't close the transport automatically when
            // auth fails — client has no more methods but the channel
            // doesn't fast-fail per SSHAuthLoopbackTests precedent).
            await snapshotBox.fail(LoopbackError.timedOut)
            client.close()
            await clientTransport.close()
        }
        defer { deadlineTask.cancel() }

        do {
            try await client.open()
        } catch {
            deadlineTask.cancel()
            await clientTransport.close()
            await serverTransport.close()
            await offerer.close()
            await answerer.close()
            throw error
        }

        // Poll for the snapshot to arrive (the server fires it on handlerAdded/channelActive).
        let received: [WorktreePanes]
        do {
            received = try await snapshotBox.wait()
        } catch {
            client.close()
            await clientTransport.close()
            await serverTransport.close()
            await offerer.close()
            await answerer.close()
            throw error
        }

        client.close()
        await clientTransport.close()
        await serverTransport.close()
        await offerer.close()
        await answerer.close()
        return received
    }

    /// Builds a loopback, opens a pane-control channel, sends a single RPC,
    /// returns the response.
    private func runPaneControlLoopback(
        serverKey: Curve25519.Signing.PrivateKey,
        trustedPeers: InMemoryTrustedPeerSet,
        clientKey: Curve25519.Signing.PrivateKey,
        expectedHostFingerprint: RemoteIdentityFingerprint,
        subscribe: @escaping TestPanesStateSubscribe,
        mutator: @escaping TestPaneControlMutator,
        request: PaneControlRequest,
        responseDeadline: Duration = .seconds(180)
    ) async throws -> PaneControlResponse {
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

        // Server: NIOSSHHandler with inline SubsystemRouter
        try await serverTransport.eventLoop.submit {
            let serverConfig = SSHServerConfiguration(
                hostKeys: [NIOSSHPrivateKey(ed25519Key: serverKey)],
                userAuthDelegate: TrustSetServerUserAuthDelegate(store: trustedPeers)
            )
            let sshHandler = NIOSSHHandler(
                role: .server(serverConfig),
                allocator: serverTransport.channel.allocator,
                inboundChildChannelInitializer: { childChannel, channelType in
                    guard case .session = channelType else {
                        return childChannel.eventLoop.makeFailedFuture(LoopbackError.unexpectedChannelType)
                    }
                    return childChannel.eventLoop.makeCompletedFuture {
                        let router = TestSubsystemRouter(
                            subscribe: subscribe,
                            mutator: mutator
                        )
                        try childChannel.pipeline.syncOperations.addHandler(router)
                    }
                }
            )
            try serverTransport.channel.pipeline.syncOperations.addHandler(sshHandler)
        }.get()

        // Client: real SSHClientSetup
        let handlerPromise = clientTransport.eventLoop.makePromise(of: NIOSSHHandler.self)
        try await clientTransport.eventLoop.submit {
            let h = SSHClientSetup.makeHandler(
                clientKey: clientKey,
                expectedHostFingerprint: expectedHostFingerprint,
                allocator: clientTransport.channel.allocator
            )
            try clientTransport.channel.pipeline.syncOperations.addHandler(h)
            handlerPromise.succeed(h)
        }.get()
        let sshHandler = try await handlerPromise.futureResult.get()

        try await serverTransport.start()
        try await clientTransport.start()

        // Open pane-control channel via PaneControlChannelClient
        let client = PaneControlChannelClient(
            parentChannel: clientTransport.channel,
            parentHandler: sshHandler
        )

        let deadlineTask = Task { [client] in
            try? await Task.sleep(for: responseDeadline)
            client.close()
        }
        defer { deadlineTask.cancel() }

        let response: PaneControlResponse
        do {
            try await client.open()
            response = try await client.send(request)
        } catch {
            await clientTransport.close()
            await serverTransport.close()
            await offerer.close()
            await answerer.close()
            throw error
        }

        client.close()
        await clientTransport.close()
        await serverTransport.close()
        await offerer.close()
        await answerer.close()
        return response
    }

    // MARK: - Helpers

    private static func fingerprint(of key: Curve25519.Signing.PrivateKey) -> RemoteIdentityFingerprint {
        let pubkey = try! RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        return RemoteIdentityFingerprint(of: pubkey)
    }
}

// MARK: - Test data helper

private func makeWorktrees(count: Int) -> [WorktreePanes] {
    (0..<count).map { i in
        WorktreePanes(
            path: "/repo/wt-\(i)",
            displayName: "worktree-\(i)",
            repoDisplayName: "repo",
            displayBranch: "branch-\(i)",
            state: .running,
            isMainCheckout: i == 0,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: nil
        )
    }
}

// MARK: - Snapshot delivery helper

/// Actor that buffers the first panes-state snapshot and resolves a waiter.
private actor SnapshotBox {
    private var value: [WorktreePanes]?
    private var continuation: CheckedContinuation<[WorktreePanes], Error>?

    func set(_ snapshot: [WorktreePanes]) {
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: snapshot)
        } else {
            value = snapshot
        }
    }

    /// Fails pending waiters with the given error (e.g. when channel closes).
    func fail(_ error: any Error) {
        if let cont = continuation {
            continuation = nil
            cont.resume(throwing: error)
        }
    }

    func wait() async throws -> [WorktreePanes] {
        if let v = value { return v }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
        }
    }
}

// MARK: - Type aliases for inline server-side callbacks

typealias TestPanesStateSubscribe = @Sendable (
    @escaping @Sendable ([WorktreePanes]) async -> Void
) async -> TestCancellable

typealias TestPaneControlMutator = @Sendable (PaneControlRequest) async -> PaneControlResponse

// MARK: - Cancellable

struct TestCancellable: Sendable {
    private let _cancel: @Sendable () -> Void
    init(cancel: @escaping @Sendable () -> Void) { self._cancel = cancel }
    func cancel() { _cancel() }
}

// MARK: - Server-side inline SubsystemRouter
//
// Routes the first SSH channel-request event to the appropriate
// server-side handler — mirrors `GrafttyHostAgent.SubsystemDispatcher`
// but only handles the two R5 subsystem types. The terminal-session
// path is omitted: these tests don't exercise `openTerminalSession`.
//
// Per R3/R4 "copy don't extract" precedent — `GrafttyHostAgent` is not
// reachable from this iOS-only test target (it imports AppKit transitively
// via GrafttyKit). Consolidation post-R6.

fileprivate final class TestSubsystemRouter: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let subscribe: TestPanesStateSubscribe
    private let mutator: TestPaneControlMutator
    private var dispatched = false

    init(
        subscribe: @escaping TestPanesStateSubscribe,
        mutator: @escaping TestPaneControlMutator
    ) {
        self.subscribe = subscribe
        self.mutator = mutator
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard !dispatched else {
            context.fireUserInboundEventTriggered(event)
            return
        }

        guard let request = event as? SSHChannelRequestEvent.SubsystemRequest else {
            // Not a subsystem request — forward through without dispatching.
            context.fireUserInboundEventTriggered(event)
            return
        }

        switch request.subsystem {
        case SSHChannelTypeNames.panesState:
            dispatched = true
            do {
                // Install handlers in reverse order: each .after(self) lands
                // immediately after self, pushing previous inserts further down.
                // Final order: [self, codec, decoder, prepender, panesHandler] →
                // after self is removed: [codec, decoder, prepender, panesHandler].
                try context.pipeline.syncOperations.addHandler(
                    InlineServerPanesStateHandler(subscribe: subscribe),
                    position: .after(self)
                )
                try context.pipeline.syncOperations.addHandler(
                    LengthPrefixedFraming.makeFramePrepender(),
                    position: .after(self)
                )
                try context.pipeline.syncOperations.addHandler(
                    LengthPrefixedFraming.makeFrameDecoder(),
                    position: .after(self)
                )
                // SSHChannelDataCodec bridges SSHChannelData ↔ ByteBuffer
                // so the downstream framing handlers operate on raw bytes.
                try context.pipeline.syncOperations.addHandler(
                    SSHChannelDataCodec(),
                    position: .after(self)
                )
                if request.wantReply {
                    context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
                }
                context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
            } catch {
                if request.wantReply {
                    context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                }
                context.close(promise: nil)
            }

        case SSHChannelTypeNames.paneControl:
            dispatched = true
            do {
                try context.pipeline.syncOperations.addHandler(
                    InlineServerPaneControlHandler(mutator: mutator),
                    position: .after(self)
                )
                try context.pipeline.syncOperations.addHandler(
                    LengthPrefixedFraming.makeFramePrepender(),
                    position: .after(self)
                )
                try context.pipeline.syncOperations.addHandler(
                    LengthPrefixedFraming.makeFrameDecoder(),
                    position: .after(self)
                )
                // SSHChannelDataCodec bridges SSHChannelData ↔ ByteBuffer.
                try context.pipeline.syncOperations.addHandler(
                    SSHChannelDataCodec(),
                    position: .after(self)
                )
                if request.wantReply {
                    context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
                }
                context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
            } catch {
                if request.wantReply {
                    context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                }
                context.close(promise: nil)
            }

        default:
            if request.wantReply {
                context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
            }
            context.close(promise: nil)
        }
    }
}

// MARK: - Inline server-side panes-state handler
//
// Mirror of `GrafttyHostAgent.PanesStateChannelHandler`. On `channelActive`
// it invokes the subscribe callback, which fires `onChange` immediately
// with the snapshot. Length-prefixed framing is already applied by
// `TestSubsystemRouter` above, so this handler reads/writes one
// `ByteBuffer` = one JSON envelope.

fileprivate final class InlineServerPanesStateHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let subscribe: TestPanesStateSubscribe
    private let lock = NSLock()
    private var isInactive = false
    private var cancellable: TestCancellable?

    init(subscribe: @escaping TestPanesStateSubscribe) {
        self.subscribe = subscribe
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // If the channel is already active (i.e. we were installed after
        // channelActive fired — the normal case for subsystem-routed handlers),
        // start the subscription immediately. NIO won't re-fire channelActive
        // for handlers added to an already-active pipeline.
        if context.channel.isActive {
            startSubscription(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        startSubscription(context: context)
        context.fireChannelActive()
    }

    private func startSubscription(context: ChannelHandlerContext) {
        let channel = context.channel
        let loop = context.eventLoop
        let allocator = context.channel.allocator
        let subscribe = self.subscribe
        let storeCancellable: @Sendable (TestCancellable) -> Void = { [weak self] c in
            guard let self else { c.cancel(); return }
            let shouldCancel: Bool = self.lock.withLock {
                if self.isInactive { return true }
                self.cancellable = c
                return false
            }
            if shouldCancel { c.cancel() }
        }

        Task { [storeCancellable] in
            let cancellable = await subscribe { snapshot in
                guard let body = try? JSONEncoder().encode(PanesStateMessage.snapshot(snapshot)) else { return }
                let buf = allocator.buffer(bytes: body)
                loop.execute {
                    channel.writeAndFlush(buf, promise: nil)
                }
            }
            storeCancellable(cancellable)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // panes-state is server-pushed; drop inbound frames.
    }

    func channelInactive(context: ChannelHandlerContext) {
        let c = lock.withLock { () -> TestCancellable? in
            isInactive = true
            let snapshot = cancellable
            cancellable = nil
            return snapshot
        }
        c?.cancel()
        context.fireChannelInactive()
    }
}

// MARK: - Inline server-side pane-control handler
//
// Mirror of `GrafttyHostAgent.PaneControlChannelHandler`. Decodes each
// inbound buffer as a `PaneControlRequest`, dispatches to the mutator,
// encodes the response, writes it back. Framing is applied upstream.

fileprivate final class InlineServerPaneControlHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let mutator: TestPaneControlMutator

    init(mutator: @escaping TestPaneControlMutator) {
        self.mutator = mutator
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let inbound = unwrapInboundIn(data)
        let bytes = Data(inbound.readableBytesView)
        let channel = context.channel
        let loop = context.eventLoop
        let allocator = context.channel.allocator
        let mutator = self.mutator

        Task {
            let response: PaneControlResponse
            do {
                let request = try JSONDecoder().decode(PaneControlRequest.self, from: bytes)
                response = await mutator(request)
            } catch {
                response = .error(code: "malformed-request", message: String(describing: error))
            }
            guard let body = try? JSONEncoder().encode(response) else { return }
            let buf = allocator.buffer(bytes: body)
            loop.execute {
                channel.writeAndFlush(buf, promise: nil)
            }
        }
    }
}

// MARK: - Errors

fileprivate enum LoopbackError: Error {
    case unexpectedChannelType
    case timedOut
    case channelClosedBeforeSnapshot
}

// MARK: - TerminalControl capability (test-local mirror of GrafttyKit.PairedDeviceCapabilities.TerminalControl)
//
// `PairedDeviceCapabilities` lives in `GrafttyKit` which imports AppKit and
// is not reachable from this iOS-only test target. This enum mirrors the
// two values needed for the Task 2 REMOTE-6.1/REMOTE-7.1 cap-check test.

fileprivate enum TerminalControlCap {
    case allowed
    case disabled
}

// MARK: - InMemoryTrustedPeerSet + TrustSetServerUserAuthDelegate
//
// Copied from SSHAuthLoopbackTests and extended with `terminalControl`
// capability tracking so Test 3 (unauthorized peer) can exercise the
// REMOTE-6.1/REMOTE-7.1 cap-check gate at userauth.

fileprivate final class InMemoryTrustedPeerSet: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [RemoteIdentityFingerprint: TerminalControlCap] = [:]
    private var lookupError: (any Error)?

    /// Add a trusted peer with the given terminalControl capability.
    /// Defaults to `.allowed` to remain compatible with the existing
    /// call sites in R3/R4 tests that don't need cap-check coverage.
    func add(
        fingerprint: RemoteIdentityFingerprint,
        terminalControl: TerminalControlCap = .allowed
    ) {
        lock.lock(); defer { lock.unlock() }
        entries[fingerprint] = terminalControl
    }

    /// Returns the `terminalControl` capability for the given fingerprint,
    /// or `nil` if the peer isn't trusted. Throws if a lookup error was
    /// injected via `injectLookupError`.
    func get(fingerprint: RemoteIdentityFingerprint) throws -> TerminalControlCap? {
        lock.lock(); defer { lock.unlock() }
        if let error = lookupError { throw error }
        return entries[fingerprint]
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
                // Mirror SSHUserAuthDelegate: require peer to be trusted AND
                // have terminalControl == .allowed. REMOTE-6.1/REMOTE-7.1.
                if case .allowed? = try store.get(fingerprint: fp) {
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

    /// Mirror of `SSHUserAuthDelegate.fingerprint(of:)`.
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

#endif

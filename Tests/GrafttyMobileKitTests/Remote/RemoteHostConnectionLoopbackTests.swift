#if canImport(UIKit)
import Foundation
import Testing
import WebRTC
@testable import GrafttyMobileKit

/// Loopback test: construct a `RemoteHostConnection` (offerer, mobile-side)
/// and a paired in-process answerer using the bundled WebRTC SDK, exchange
/// SDP + ICE in-process (no signaling endpoint yet), verify a DataChannel
/// opens, and verify a byte ping-pong round-trips.
///
/// This is the M1.1 acceptance criterion: SDK integration works, peer
/// connection negotiates, data channel opens. M1.2 replaces the in-process
/// SDP swap with an HTTPS signaling endpoint; M1.3 adds Noise before any
/// channel traffic; M1.4 framing.
@Suite("WebRTC SDK integration — loopback DataChannel ping-pong (M1.1 foundation).")
struct RemoteHostConnectionLoopbackTests {

    @Test
    func twoConnectionsExchangeBytesOverDataChannel() async throws {
        let client = RemoteHostConnection()
        let answererPeer = TestAnswerer()

        diag("test start")
        do {
            // 1. Client creates offer.
            let offer = try await client.createOffer()
            diag("createOffer returned")

            // 2. In a real flow this would be POSTed to /v1/rtc/offer.
            //    Here we feed it straight into the answerer.
            let answer = try await answererPeer.accept(offer: offer)
            diag("accept returned")

            // 3. Forward ICE candidates each way. Both sides buffer candidates
            //    emitted during the initial gathering pass (which happens
            //    inside `createOffer` / `accept` before this point), then
            //    drain in arrival order when their target is bound.
            await client.bindIceCandidates(to: answererPeer)
            await answererPeer.bindIceCandidates(to: client)
            diag("bindIceCandidates done both sides")

            // 4. Apply the answer on the client; this waits for the data
            //    channel to reach the `open` state on the offerer side.
            try await client.applyAnswer(answer)
            diag("applyAnswer returned (offerer dc reportedly open)")

            // 5. Send a binary ping from the client; the answerer should
            //    receive it within a short window.
            let ping = Data([0xCA, 0xFE, 0xBA, 0xBE])
            try await client.sendBinary(ping)
            diag("sendBinary(ping) returned")

            try await pollUntil(timeout: .seconds(5)) {
                await answererPeer.lastReceived == ping
            }
            diag("pollUntil ping received")

            // 6. Send a binary pong back; the client should receive it.
            let pong = Data([0xDE, 0xAD, 0xBE, 0xEF])
            try await answererPeer.send(pong)
            diag("send(pong) returned")

            try await pollUntil(timeout: .seconds(5)) {
                await client.lastReceivedBinary == pong
            }
            diag("pollUntil pong received")
        } catch {
            diag("test FAILED with: \(error)")
            await answererPeer.dumpDiagnostics()
            await client.close()
            await answererPeer.close()
            throw error
        }

        await client.close()
        await answererPeer.close()
    }
}

/// Print-with-timestamp helper. Output goes to stdout where xcodebuild
/// captures it into the CI test log. The timestamp uses `Date()` since
/// `ContinuousClock` doesn't have a wall-clock representation — we want
/// relative ordering across WebRTC's queues and our actor, not absolute
/// time, so any monotonic source works.
private func diag(_ message: String, file: String = #fileID, line: Int = #line) {
    let ts = Date().timeIntervalSince1970
    print("[DIAG \(String(format: "%.6f", ts))] \(message) (\(file):\(line))")
}

/// Test helper that owns the answerer side of the loopback. Production
/// uses `WebRTCHostAgent` from GrafttyKit, but that target isn't
/// importable here; we duplicate the minimal answerer logic inline so
/// the loopback proves the mobile-side `RemoteHostConnection` works in
/// isolation. The Mac-side test in `GrafttyKitTests` will mirror.
private actor TestAnswerer: WebRTCIceCandidateReceiver {
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    /// `nonisolated let` so the `onDataChannel` callback (which fires on
    /// WebRTC's serial queue) can install `dc.delegate` and the
    /// `onMessage` closure **synchronously**, before any message has a
    /// chance to race in. The previous design queued a `Task { await
    /// adopt }`; if the first message arrived during the actor-queue gap
    /// between Task dispatch and Task execution, `dc.delegate` was nil
    /// and WebRTC dropped the message. The delegate classes are
    /// `@unchecked Sendable`.
    private nonisolated let delegate = AnswererDelegate()
    private nonisolated let dataChannelDelegate = AnswererDataChannelDelegate()
    private(set) var lastReceived: Data?
    /// Mirror of `RemoteHostConnection.pendingLocalCandidates` — buffer
    /// candidates gathered during `accept` until the test binds a target,
    /// so the offerer doesn't starve waiting for our host candidates.
    private var pendingLocalCandidates: [RTCIceCandidate] = []
    private var iceCandidateTarget: RemoteHostConnection?
    /// DIAGNOSTIC: number of times `record(_:)` has been invoked on the actor.
    private(set) var recordCallCount: Int = 0

    init() {
        self.factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        // See `RemoteHostConnection.init` — install the candidate sink
        // up-front so candidates emitted during `accept`'s ICE gathering
        // pass (before `bindIceCandidates` is called) are buffered.
        delegate.onIceCandidate = { [weak self] candidate in
            Task { await self?.routeLocalIceCandidate(candidate) }
        }
        // Install dc routing synchronously so the first inbound message
        // is never dropped to a nil delegate during an actor-queue gap.
        // Stashing the dc reference (for `send`) can still go through
        // the actor since `send` is only driven by the test after
        // `applyAnswer` returns.
        delegate.onDataChannel = { [weak self] dc in
            diag("answerer: onDataChannel fired (state=\(dc.readyState.rawValue))")
            guard let self else { return }
            dc.delegate = self.dataChannelDelegate
            self.dataChannelDelegate.onMessage = { [weak self] data in
                diag("answerer: onMessage closure fired (\(data.count) bytes)")
                Task { await self?.record(data) }
            }
            Task { await self.captureDataChannel(dc) }
        }
    }

    /// DIAGNOSTIC: dump final state of all instrumented counters/buffers.
    func dumpDiagnostics() {
        diag("answerer DIAG: dataChannel set? \(dataChannel != nil), readyState=\(dataChannel?.readyState.rawValue.description ?? "nil")")
        diag("answerer DIAG: recordCallCount=\(recordCallCount), lastReceived=\(lastReceived.map { "\($0.count) bytes" } ?? "nil")")
        diag("answerer DIAG: dataChannelDelegate.didReceiveCount=\(dataChannelDelegate.didReceiveCount), stateChanges=\(dataChannelDelegate.stateChangeLog)")
    }

    private func captureDataChannel(_ dc: RTCDataChannel) {
        self.dataChannel = dc
    }

    private func routeLocalIceCandidate(_ candidate: RTCIceCandidate) async {
        if let target = iceCandidateTarget {
            try? await target.addRemoteIceCandidate(candidate)
        } else {
            pendingLocalCandidates.append(candidate)
        }
    }

    func accept(offer: RTCSessionDescription) async throws -> RTCSessionDescription {
        let config = RemoteHostConnection.defaultConfig()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
            throw NSError(domain: "TestAnswerer", code: 1)
        }
        self.peerConnection = pc

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(offer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let answer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.answer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: NSError(domain: "TestAnswerer", code: 2)); return }
                continuation.resume(returning: sdp)
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(answer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        // Wait for ICE gathering to complete so the answer SDP includes
        // every `a=candidate:` line — mirrors WebRTCHostAgent.acceptOffer.
        // Without this, the client's connection has no remote candidates
        // and the data channel never opens, hanging the test forever.
        await waitForIceGatheringComplete(pc)
        return pc.localDescription ?? answer
    }

    private func waitForIceGatheringComplete(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.gatheringContinuation = continuation
            delegate.onIceGatheringComplete = { [weak self] in
                Task { await self?.handleIceGatheringComplete() }
            }
            if pc.iceGatheringState == .complete {
                handleIceGatheringComplete()
                return
            }
            // iOS simulator's WebRTC can't see real interfaces and stays
            // in `.gathering` forever otherwise.
            self.gatheringTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.gatheringTimeout)
                await self?.handleIceGatheringComplete()
            }
        }
    }

    private static let gatheringTimeout: Duration = .seconds(5)
    private var gatheringContinuation: CheckedContinuation<Void, Never>?
    private var gatheringTimeoutTask: Task<Void, Never>?

    private func handleIceGatheringComplete() {
        let pending = gatheringContinuation
        gatheringContinuation = nil
        delegate.onIceGatheringComplete = nil
        gatheringTimeoutTask?.cancel()
        gatheringTimeoutTask = nil
        pending?.resume()
    }

    func send(_ data: Data) async throws {
        guard let dc = dataChannel, dc.readyState == .open else {
            throw NSError(domain: "TestAnswerer", code: 3)
        }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        guard dc.sendData(buffer) else {
            throw NSError(domain: "TestAnswerer", code: 4)
        }
    }

    func bindIceCandidates(to client: RemoteHostConnection) {
        self.iceCandidateTarget = client
        let drained = pendingLocalCandidates
        pendingLocalCandidates.removeAll()
        // Single Task, sequential awaits — mirror of
        // `RemoteHostConnection.bindIceCandidates`. Per-candidate Tasks
        // would race on the receiver's executor.
        Task {
            for candidate in drained {
                try? await client.addRemoteIceCandidate(candidate)
            }
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

    func close() {
        if let pending = gatheringContinuation {
            gatheringContinuation = nil
            delegate.onIceGatheringComplete = nil
            gatheringTimeoutTask?.cancel()
            gatheringTimeoutTask = nil
            pending.resume()
        }
        dataChannel?.close()
        peerConnection?.close()
        iceCandidateTarget = nil
        pendingLocalCandidates.removeAll()
    }

    fileprivate func record(_ data: Data) {
        recordCallCount += 1
        diag("answerer: record() invoked, count=\(recordCallCount)")
        self.lastReceived = data
    }
}

private final class AnswererDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onIceCandidate: (@Sendable (RTCIceCandidate) -> Void)?
    nonisolated(unsafe) var onDataChannel: (@Sendable (RTCDataChannel) -> Void)?
    nonisolated(unsafe) var onIceGatheringComplete: (@Sendable () -> Void)?
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            onIceGatheringComplete?()
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onIceCandidate?(candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        onDataChannel?(dataChannel)
    }
}

private final class AnswererDataChannelDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onMessage: (@Sendable (Data) -> Void)?
    /// DIAGNOSTIC: counts every `didReceiveMessageWith` callback from WebRTC.
    /// If this stays 0 in a failed run, WebRTC never delivered the message
    /// to the delegate (drop happened upstream of our code). If it's > 0
    /// but `record()` count is 0, the onMessage Task hop failed.
    nonisolated(unsafe) private(set) var didReceiveCount: Int = 0
    /// DIAGNOSTIC: every state transition reported via the delegate. The
    /// production `RemoteHostConnection.DataChannelDelegate` fires `onOpen`
    /// on `.open` — we don't fire anything on the answerer side, but we
    /// log so we can compare with `dataChannel?.readyState` polling.
    nonisolated(unsafe) private(set) var stateChangeLog: [Int] = []
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let s = dataChannel.readyState.rawValue
        stateChangeLog.append(s)
        diag("answerer dc dataChannelDidChangeState: state=\(s)")
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        didReceiveCount += 1
        diag("answerer dc didReceiveMessageWith: \(buffer.data.count) bytes, count=\(didReceiveCount)")
        onMessage?(buffer.data)
    }
}

/// Poll until `condition()` returns true or the deadline expires. Used
/// instead of arbitrary `Task.sleep` so the test exits promptly on
/// success but still fails clearly when the condition genuinely doesn't
/// hold. Throws on timeout so the test stops at the first failure point
/// rather than cascading into follow-up failures triggered by the same
/// root cause.
private struct PollTimeout: Error, CustomStringConvertible {
    let timeout: Duration
    var description: String { "pollUntil timed out after \(timeout)" }
}

private func pollUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(50),
    condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: interval)
    }
    throw PollTimeout(timeout: timeout)
}
#endif

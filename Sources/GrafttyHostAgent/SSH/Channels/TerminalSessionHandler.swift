import Foundation
import GrafttyKit
import GrafttyProtocol
import NIOCore
import NIOSSH

/// Server-side SSH channel handler for graftty's terminal session
/// channel. Installs on an inbound SSH session child channel and:
///
///   1. Collects `env GRAFTTY_SESSION=<name>` and `pty-req` channel
///      requests as they arrive.
///   2. On `shell`, calls the injected `streamFactory(name)` to obtain
///      a `TerminalByteStream` (which in production wraps a
///      `Process` spawning `zmx attach <name>`).
///   3. Bridges bytes both ways: inbound `SSHChannelData` -> `stream.send`;
///      `stream.inboundBytes` -> outbound `SSHChannelData`.
///   4. Forwards `window-change` channel requests to `stream.resize`.
///   5. On channel close, calls `stream.close()` — which terminates the
///      `zmx attach` Process. The user's shell survives because it
///      runs in the zmx daemon, attached/detached transparently.
///   6. If `streamFactory` throws, sends `exit-status: 1` and closes
///      the channel.
///
/// REMOTE-9: display ownership rides the SAME session channel as
/// terminal bytes, multiplexed by `SSHChannelData.type` — `.channel`
/// carries raw PTY bytes (unchanged), `.stdErr` carries
/// length-prefixed (`<u32 BE length><UTF-8 JSON>`) `WebControlEnvelope`
/// frames. This can't be delegated to the `LengthPrefixedFraming`
/// pipeline handlers the subsystem channels use (`SubsystemDispatcher`)
/// because those convert *every* `SSHChannelData` on the channel to
/// `ByteBuffer` indiscriminately — correct for a subsystem channel that
/// carries exactly one data type, wrong here where `.channel` and
/// `.stdErr` must stay distinct streams on one channel. Framing is done
/// inline instead (`ingestStdErr`/`encodeStdErrFrame`) using the same
/// 4-byte-BE-length wire shape.
///
/// **Legacy-client gating.** Today's mobile `TerminalSessionClient`
/// treats every inbound `SSHChannelData` as terminal bytes regardless of
/// `.type` — it has no notion of `.stdErr` control frames. Emitting an
/// ownership envelope to such a client would corrupt its terminal
/// output. Since a legacy client never sends `.stdErr` data either, this
/// handler uses "have we ever received a `.hello` envelope" as the
/// protocol-version signal: `receivedHello == false` reproduces exactly
/// pre-REMOTE-9 behavior (inbound `.channel` bytes go straight to
/// `stream.send`, ungated; `sendText` is a silent no-op so no `.stdErr`
/// frame is ever queued). Only after a `.hello` arrives does the
/// `TerminalAttachCoordinator`'s owner-gated path activate for both
/// directions.
///
/// Concurrency: `@unchecked Sendable` because all mutable state
/// (`envSessionName`, `ptyAccepted`, `stream`, `inboundForwardingTask`)
/// is accessed exclusively on the channel's event loop. NIO guarantees
/// `channelRead`, `userInboundEventTriggered`, and `channelInactive` all
/// run on that loop; `loop.execute` callbacks in `attach` also run there.
public final class TerminalSessionHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = SSHChannelData
    public typealias OutboundOut = SSHChannelData

    private let streamFactory: @Sendable (String) async throws -> TerminalByteStream
    private let ownershipStore: SessionDisplayOwnershipStore
    private let ownershipBroadcaster: DisplayOwnershipBroadcaster
    private let deviceID: RemoteDeviceID
    private var envSessionName: String?
    private var ptyAccepted = false
    /// Captured from `pty-req`'s cols/rows (REMOTE-9.4) — fed through
    /// `coordinator.handlePTYSize` once immediately after attach so
    /// session-wide ownership observers see the client's real terminal
    /// size as soon as possible, rather than waiting on
    /// `ZmxAttachEngine`'s 250ms size-poll cadence.
    private var ptyGrid: DisplayGrid?
    private var stream: TerminalByteStream?
    private var coordinator: TerminalAttachCoordinator?
    private var inboundForwardingTask: Task<Void, Never>?
    private var isShuttingDown = false
    /// REMOTE-9 protocol-version gate — see the type doc comment. Guarded
    /// by `helloLock` (rather than relying on event-loop exclusivity like
    /// the rest of this handler's state) because `sendText` reads it from
    /// `TerminalAttachCoordinator`'s broadcaster-fan-out path, which can
    /// fire from a different SSH connection's event loop when another
    /// client on the same session mutates the shared ownership store.
    private let helloLock = NSLock()
    private var _receivedHello = false
    private var receivedHello: Bool {
        get { helloLock.lock(); defer { helloLock.unlock() }; return _receivedHello }
        set { helloLock.lock(); defer { helloLock.unlock() }; _receivedHello = newValue }
    }
    private var stdErrAccumulator: [UInt8] = []
    /// Set when a `.stdErr` frame header claims a length above
    /// `Self.maxControlFrameLength`. Framing is unrecoverable at that
    /// point (we can't tell where the next frame starts), so the control
    /// carrier is abandoned for this channel: all further `.stdErr`
    /// bytes are dropped and nothing is ever emitted on `.stdErr`.
    /// Terminal bytes keep flowing untouched.
    private var stdErrPoisoned = false
    /// Control envelopes are small JSON (hello/takeControl/ownership —
    /// hundreds of bytes). 1 MiB is orders of magnitude above any real
    /// frame while bounding what a buggy/hostile peer can make the host
    /// buffer (the accumulator can never exceed cap + one inbound chunk).
    private static let maxControlFrameLength: UInt32 = 1 << 20

    /// FIFO pipe for PTY writes. Both byte paths (pre-hello legacy and
    /// the coordinator's owner-gated `write` seam) yield into this
    /// stream from the channel's event loop, and a single consumer task
    /// (`ptyWriterTask`) awaits `stream.send` sequentially — spawning an
    /// independent `Task` per chunk (the previous shape) provides no
    /// FIFO guarantee between tasks, so a fast burst of keystrokes could
    /// reach the PTY out of order.
    private var ptyWriteContinuation: AsyncStream<Data>.Continuation?
    private var ptyWriterTask: Task<Void, Never>?

    public init(
        streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream,
        ownershipStore: SessionDisplayOwnershipStore,
        ownershipBroadcaster: DisplayOwnershipBroadcaster,
        deviceID: RemoteDeviceID
    ) {
        self.streamFactory = streamFactory
        self.ownershipStore = ownershipStore
        self.ownershipBroadcaster = ownershipBroadcaster
        self.deviceID = deviceID
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case let .byteBuffer(buf) = channelData.data else { return }
        var view = buf
        guard let bytes = view.readBytes(length: view.readableBytes) else { return }

        switch channelData.type {
        case .stdErr:
            // Accumulated even before attach completes: a client may
            // send its `.hello` right behind pty-req/shell without
            // waiting for the shell ack, while `streamFactory` is still
            // resolving. Dropping it here would leave the client
            // permanently stuck in legacy mode (only a `.hello` flips
            // `receivedHello`, and this was its one). `ingestStdErr`
            // buffers raw bytes; frames drain once the coordinator
            // exists (`installCoordinator` calls `drainControlFrames`).
            ingestStdErr(Data(bytes))

        default:
            guard stream != nil else {
                // Bytes arrived before `shell` completed attach; drop
                // them. Real clients never do this — SSH state machine
                // prevents shell-before-data — but be defensive.
                return
            }
            let payload = Data(bytes)
            if receivedHello, let coordinator {
                // REMOTE-9.2: owner-gated once the client has opted into
                // the control carrier.
                coordinator.handleBinary(payload)
            } else {
                // Pre-hello: exactly today's behavior, ungated.
                ptyWriteContinuation?.yield(payload)
            }
        }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let envEvent as SSHChannelRequestEvent.EnvironmentRequest:
            if envEvent.name == "GRAFTTY_SESSION" {
                envSessionName = envEvent.value
            }
            // Acknowledge the env request if a reply was requested.
            // (Other env names are accepted silently — no-op.)
            if envEvent.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }

        case let ptyEvent as SSHChannelRequestEvent.PseudoTerminalRequest:
            // Accept any pty-req. Capture cols/rows (REMOTE-9.4) as the
            // client's requested initial grid — used once attach
            // completes to seed an early size signal; the client
            // re-sends window-change after shell completes for any
            // subsequent resize.
            ptyAccepted = true
            ptyGrid = try? DisplayGrid(
                cols: UInt16(clamping: ptyEvent.terminalCharacterWidth),
                rows: UInt16(clamping: ptyEvent.terminalRowHeight)
            )
            if ptyEvent.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }

        case let shellEvent as SSHChannelRequestEvent.ShellRequest:
            guard let name = envSessionName else {
                // No GRAFTTY_SESSION env — we have nothing to attach to.
                if shellEvent.wantReply {
                    context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                }
                context.close(promise: nil)
                return
            }
            attach(context: context, sessionName: name, wantReply: shellEvent.wantReply)

        case let winEvent as SSHChannelRequestEvent.WindowChangeRequest:
            guard let snapshot = stream else { return }
            let cols = winEvent.terminalCharacterWidth
            let rows = winEvent.terminalRowHeight
            if receivedHello, let coordinator {
                // Once the control carrier is active, an SSH-level
                // window-change goes through the same owner gate the
                // web transport applies to its legacy `resize` frames
                // (REMOTE-9.3) — a follower's window drag must not
                // stomp the shared PTY. Zero/invalid dimensions are
                // ignored (a 0-col resize is meaningless and the grid
                // type rejects it).
                guard
                    let gridCols = UInt16(exactly: cols), gridCols > 0,
                    let gridRows = UInt16(exactly: rows), gridRows > 0
                else { return }
                coordinator.handleControl(.resize(cols: gridCols, rows: gridRows))
            } else {
                // Pre-hello (legacy client): historical direct resize.
                Task { [snapshot] in
                    await snapshot.resize(cols: cols, rows: rows)
                }
            }

        default:
            // Other channel-request events (exec, signal, exit-*) are
            // not used by graftty's iPad client; ignore.
            break
        }
    }

    public func channelInactive(context: ChannelHandlerContext) {
        isShuttingDown = true
        inboundForwardingTask?.cancel()
        ptyWriteContinuation?.finish()
        ptyWriteContinuation = nil
        ptyWriterTask = nil
        let snapshot = stream
        stream = nil
        // REMOTE-9.1: detach synchronously so the ownership store and any
        // other session subscribers learn this client is gone before the
        // channel finishes tearing down. `detach()` is idempotent and
        // internally locked — safe to call unconditionally.
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
        // Use the channel's pipeline for outbound events — Channel is
        // Sendable, ChannelHandlerContext is not.
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
                        // Channel closed while factory was awaiting — clean up.
                        Task { await stream.close() }
                        return
                    }
                    self.stream = stream
                    self.startPTYWriter(stream: stream)
                    self.installCoordinator(
                        sessionName: sessionName,
                        stream: stream,
                        channel: channel,
                        loop: loop
                    )
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

    /// Creates the FIFO write pipe and its single consumer task — the
    /// only path by which inbound bytes reach `stream.send`, preserving
    /// wire order end-to-end (see `ptyWriteContinuation`).
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

    /// Builds the `TerminalAttachCoordinator` for this attach and wires
    /// its seams. Called once, from the `loop.execute` block in `attach`
    /// that installs `self.stream` — so `self.coordinator` is available
    /// before any inbound bytes/control frames can be dispatched.
    private func installCoordinator(
        sessionName: String,
        stream: TerminalByteStream,
        channel: Channel,
        loop: EventLoop
    ) {
        // REMOTE-9.1: clientID embeds the authenticated device identity
        // so ownership-store entries are attributable to a real paired
        // device, not just an opaque per-channel UUID.
        let clientID = DisplayClientID("ssh-\(deviceID.value)-\(UUID().uuidString.prefix(8))")
        let coordinator = TerminalAttachCoordinator(
            sessionName: sessionName,
            clientID: clientID,
            defaultKind: .ios,
            ownershipStore: ownershipStore,
            broadcaster: ownershipBroadcaster,
            sendText: { [weak self] payload in
                // Legacy gate: stay silent until this client has proven
                // (via `.hello`) that it understands `.stdErr` control
                // frames. See the type doc comment.
                guard let self, self.receivedHello else { return }
                guard let framed = Self.encodeStdErrFrame(payload) else { return }
                loop.execute {
                    var buffer = channel.allocator.buffer(capacity: framed.count)
                    buffer.writeBytes(framed)
                    let data = SSHChannelData(type: .stdErr, data: .byteBuffer(buffer))
                    channel.writeAndFlush(data, promise: nil)
                }
            },
            resize: { [weak self] cols, rows in
                let snapshot = self?.stream
                Task { [snapshot] in
                    await snapshot?.resize(cols: Int(cols), rows: Int(rows))
                }
            },
            write: { [weak self] data in
                // Only called from `handleBinary` (owner-gated inbound
                // bytes), which runs on the event loop via channelRead —
                // yield into the same FIFO pipe as the legacy path so
                // byte order is preserved across both.
                self?.ptyWriteContinuation?.yield(data)
            }
        )
        self.coordinator = coordinator

        if let sizeReporting = stream as? TerminalSizeReporting {
            sizeReporting.onPTYSize = { [weak self] cols, rows in
                // May run off the event loop (see `TerminalSizeReporting`
                // doc); marshal onto the channel's loop before touching
                // the coordinator.
                loop.execute { [weak self] in
                    self?.coordinator?.handlePTYSize(cols: cols, rows: rows)
                }
            }
        }

        // Drain any control frames that arrived while the factory was
        // resolving (a client may send `.hello` without waiting for the
        // shell ack) — BEFORE the initial grid push, so a buffered hello
        // activates the carrier first and the grid push below actually
        // reaches the client.
        drainControlFrames()

        if let ptyGrid {
            coordinator.handlePTYSize(cols: ptyGrid.cols, rows: ptyGrid.rows)
        }
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

    // MARK: - `.stdErr` control-frame framing (REMOTE-9)

    /// Accumulates inbound `.stdErr` bytes, then drains complete frames
    /// if the coordinator exists. Pre-attach (`coordinator == nil`),
    /// bytes only accumulate — `installCoordinator` calls
    /// `drainControlFrames()` to replay them once attach completes, so
    /// an early `.hello` is never lost.
    private func ingestStdErr(_ data: Data) {
        guard !stdErrPoisoned else { return }
        stdErrAccumulator.append(contentsOf: data)
        if coordinator != nil {
            drainControlFrames()
        }
        // Bound pre-attach accumulation too (frames don't drain until
        // the coordinator exists): anything past one max-size frame's
        // worth of undrained bytes is a protocol violation.
        if stdErrAccumulator.count > Int(Self.maxControlFrameLength) + 4 {
            stdErrPoisoned = true
            stdErrAccumulator = []
        }
    }

    /// Extracts complete `<u32 BE length><UTF-8 JSON>` frames from the
    /// accumulator, forwarding each parsed `WebControlEnvelope` to the
    /// coordinator. A `.hello` frame flips `receivedHello`; every other
    /// frame is dropped until one arrives (a well-behaved client always
    /// sends `.hello` first). A length above `maxControlFrameLength`
    /// poisons the carrier — see `stdErrPoisoned`.
    private func drainControlFrames() {
        while stdErrAccumulator.count >= 4 {
            let length = (UInt32(stdErrAccumulator[0]) << 24)
                | (UInt32(stdErrAccumulator[1]) << 16)
                | (UInt32(stdErrAccumulator[2]) << 8)
                | UInt32(stdErrAccumulator[3])
            guard length <= Self.maxControlFrameLength else {
                stdErrPoisoned = true
                stdErrAccumulator = []
                return
            }
            let total = 4 + Int(length)
            guard stdErrAccumulator.count >= total else { break }
            let payload = Data(stdErrAccumulator[4..<total])
            stdErrAccumulator.removeFirst(total)

            guard let envelope = try? WebControlEnvelope.parse(payload) else { continue }
            if case .hello = envelope {
                receivedHello = true
            }
            guard receivedHello else { continue }
            coordinator?.handleControl(envelope)
        }
    }

    private static func encodeStdErrFrame(_ payload: String) -> [UInt8]? {
        let bytes = Array(payload.utf8)
        // A control envelope can never approach UInt32.max in practice;
        // guard (rather than trap or clamp — clamping would desync the
        // framing) and drop the frame if it somehow does.
        guard let length = UInt32(exactly: bytes.count) else { return nil }
        var framed: [UInt8] = [
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ]
        framed.append(contentsOf: bytes)
        return framed
    }
}

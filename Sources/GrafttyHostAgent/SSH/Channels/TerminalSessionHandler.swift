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
/// inline instead (`ingestStdErr`, backed by the shared
/// `StdErrControlFraming` codec) using the same 4-byte-BE-length wire
/// shape.
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
/// (`envSessionName`, `ptyAccepted`, `stream`, `inboundForwardingTask`,
/// `coordinator`, `stdErrDecoder`, `stdErrPoisoned`,
/// `ptyGrid`, `ptyWriteContinuation`) is accessed exclusively on the
/// channel's event loop. NIO guarantees `channelRead`, `userInboundEventTriggered`, and
/// `channelInactive` all run on that loop; `loop.execute` callbacks in
/// `attach` also run there. `_receivedHello` is the one exception — see
/// `helloLock`.
public final class TerminalSessionHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = SSHChannelData
    public typealias OutboundOut = SSHChannelData

    private let streamFactory: @Sendable (String) async throws -> TerminalByteStream
    private let ownershipStore: SessionDisplayOwnershipStore
    private let ownershipBroadcaster: DisplayOwnershipBroadcaster
    private let deviceID: RemoteDeviceID
    private let defaultKind: DisplayClientKind
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
    /// Accumulates/drains the `.stdErr` control carrier's
    /// `<u32 BE length><UTF-8 JSON>` frames — see
    /// `StdErrControlFraming` for the wire format and cap this shares
    /// with `TerminalSessionClient`/`InboundRelay` on the client side.
    private var stdErrDecoder = StdErrControlFraming.Decoder()
    /// Set when a `.stdErr` frame header claims a length above
    /// `StdErrControlFraming.maxFrameLength`. Framing is unrecoverable at
    /// that point (we can't tell where the next frame starts), so all
    /// further `.stdErr` bytes are dropped and nothing is ever emitted on
    /// `.stdErr` again. Pre-hello, that's the whole story: the client
    /// behaves like a legacy client from then on and terminal bytes keep
    /// flowing untouched. Post-hello, abandoning the carrier alone would
    /// silently strand a live client (see `poisonStdErr`), so the
    /// channel is also closed.
    private var stdErrPoisoned = false

    /// FIFO pipe for PTY writes. Both byte paths (pre-hello legacy and
    /// the coordinator's owner-gated `write` seam) yield into this
    /// stream from the channel's event loop, and a single consumer task
    /// (`ptyWriterTask`) awaits `stream.send` sequentially — spawning an
    /// independent `Task` per chunk (the previous shape) provides no
    /// FIFO guarantee between tasks, so a fast burst of keystrokes could
    /// reach the PTY out of order. The stream is bounded: if a stalled PTY
    /// cannot keep up, the channel closes instead of retaining attacker-
    /// controlled input without limit.
    private var ptyWriteContinuation: AsyncStream<Data>.Continuation?
    private var ptyWriterTask: Task<Void, Never>?
    private static let maxPendingPTYWriteChunks = 256

    public init(
        streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream,
        ownershipStore: SessionDisplayOwnershipStore,
        ownershipBroadcaster: DisplayOwnershipBroadcaster,
        deviceID: RemoteDeviceID,
        defaultKind: DisplayClientKind = .ios
    ) {
        self.streamFactory = streamFactory
        self.ownershipStore = ownershipStore
        self.ownershipBroadcaster = ownershipBroadcaster
        self.deviceID = deviceID
        self.defaultKind = defaultKind
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
            ingestStdErr(Data(bytes), channel: context.channel)

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
                enqueuePTYWrite(payload, channel: context.channel)
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
            // REMOTE-9 grid-cap coherence: clamp to
            // WebControlEnvelope.maxGridDimension (not just UInt16's
            // range) — an unclamped grid here would seed `ptyGrid`,
            // which `installCoordinator` feeds straight into the shared
            // ownership store via `handlePTYSize`. `DisplayGrid` itself
            // has no upper bound, so an over-cap grid would enter the
            // store and poison every subsequent `.ownership` broadcast
            // for every client on the session (`WebControlEnvelope.parse`
            // rejects any grid above the cap).
            ptyGrid = try? DisplayGrid(
                cols: WebControlEnvelope.clampedGridDimension(ptyEvent.terminalCharacterWidth),
                rows: WebControlEnvelope.clampedGridDimension(ptyEvent.terminalRowHeight)
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
                // Clamp (don't reject) to the shared cap — see the
                // pty-req handler's comment on why an unclamped grid here
                // would poison every client's `.ownership` broadcast.
                coordinator.handleControl(.resize(
                    cols: WebControlEnvelope.clampedGridDimension(Int(gridCols)),
                    rows: WebControlEnvelope.clampedGridDimension(Int(gridRows))
                ))
            } else {
                // Pre-hello (legacy client): historical direct resize.
                // Same FIFO reasoning as the owner-gated seam above — call
                // synchronously when the concrete stream supports it
                // (`TerminalSyncResizing`); this handler already runs on
                // the event loop (`userInboundEventTriggered`). Falls back
                // to the `Task`-wrapped async path for streams that only
                // implement the protocol's `async` resize (test fakes).
                if let syncResizing = snapshot as? TerminalSyncResizing {
                    syncResizing.resize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
                } else {
                    Task { [snapshot] in
                        await snapshot.resize(cols: cols, rows: rows)
                    }
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
        ptyWriterTask?.cancel()
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
        let pipe = AsyncStream<Data>(
            bufferingPolicy: .bufferingOldest(Self.maxPendingPTYWriteChunks)
        ) { continuation = $0 }
        ptyWriteContinuation = continuation
        ptyWriterTask = Task {
            for await chunk in pipe {
                guard !Task.isCancelled else { return }
                try? await stream.send(chunk)
            }
        }
    }

    private func enqueuePTYWrite(_ data: Data, channel: Channel) {
        guard let continuation = ptyWriteContinuation else { return }
        switch continuation.yield(data) {
        case .enqueued:
            return
        case .dropped:
            // Terminal input is not safely lossy. Tear down this attachment
            // rather than silently corrupting a paste/command or retaining
            // an unbounded backlog behind a stalled zmx process.
            continuation.finish()
            ptyWriteContinuation = nil
            ptyWriterTask?.cancel()
            channel.close(promise: nil)
        case .terminated:
            return
        @unknown default:
            channel.close(promise: nil)
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
        // device, not just an opaque per-channel UUID. The UUID suffix is
        // the FULL 36-character `uuidString` (not an 8-char prefix) — the
        // store keys attached clients by clientID, and truncating to 32
        // bits of entropy widens the window for two concurrent SSH
        // attaches from the same device to collide and cross-contaminate
        // each other's channel. `/ws`'s equivalent path uses the full
        // UUID for the same reason.
        let clientID = DisplayClientID("ssh-\(deviceID.value)-\(UUID().uuidString)")
        let coordinator = TerminalAttachCoordinator(
            sessionName: sessionName,
            clientID: clientID,
            defaultKind: defaultKind,
            ownershipStore: ownershipStore,
            broadcaster: ownershipBroadcaster,
            sendText: { [weak self] payload in
                // Legacy gate: stay silent until this client has proven
                // (via `.hello`) that it understands `.stdErr` control
                // frames. See the type doc comment.
                guard let self, self.receivedHello else { return }
                guard let framed = StdErrControlFraming.encode(payload) else { return }
                loop.execute {
                    var buffer = channel.allocator.buffer(capacity: framed.count)
                    buffer.writeBytes(framed)
                    let data = SSHChannelData(type: .stdErr, data: .byteBuffer(buffer))
                    channel.writeAndFlush(data, promise: nil)
                }
            },
            resize: { [weak self] cols, rows in
                // This closure runs synchronously on the channel's event
                // loop (via `handleControl`, from `channelRead` or
                // `drainControlFrames`) — the same loop that serializes
                // `ptyWriteContinuation` writes. Calling a
                // `TerminalSyncResizing` conformer (`ZmxAttachEngine` in
                // production) directly here preserves that ordering;
                // spawning a `Task` per call (the previous shape, still
                // used as a fallback below for streams — test fakes —
                // that only implement the protocol's `async` resize) gave
                // no FIFO guarantee against a concurrently-queued PTY
                // write, exactly the hazard `ptyWriteContinuation`'s doc
                // comment describes.
                guard let self else { return }
                if let syncResizing = self.stream as? TerminalSyncResizing {
                    syncResizing.resize(cols: cols, rows: rows)
                } else {
                    let snapshot = self.stream
                    Task { [snapshot] in
                        await snapshot?.resize(cols: Int(cols), rows: Int(rows))
                    }
                }
            },
            write: { [weak self] data in
                // Only called from `handleBinary` (owner-gated inbound
                // bytes), which runs on the event loop via channelRead —
                // yield into the same FIFO pipe as the legacy path so
                // byte order is preserved across both.
                self?.enqueuePTYWrite(data, channel: channel)
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
        drainControlFrames(channel: channel)

        if let ptyGrid {
            coordinator.handlePTYSize(cols: ptyGrid.cols, rows: ptyGrid.rows)
        }
    }

    private func startInboundForwarding(stream: TerminalByteStream, channel: Channel, loop: EventLoop) {
        let task = Task { [weak self] in
            for await chunk in stream.inboundBytes {
                let buffer = channel.allocator.buffer(bytes: chunk)
                let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
                loop.execute {
                    channel.writeAndFlush(data, promise: nil)
                }
            }
            // `inboundBytes` finished — either because `channelInactive`
            // already called `stream.close()` (in which case
            // `isShuttingDown` is already true and closing again would be
            // redundant), or because the underlying child exited on its
            // own with the channel still active. In the latter case
            // nothing else would ever close this channel or detach the
            // coordinator from the ownership store, leaving a stale
            // attached/owner entry and a leaked channel — close it here
            // so the existing `channelInactive` cleanup runs exactly
            // once. `isShuttingDown` is read on the event loop per the
            // type's concurrency contract, not from this Task's thread.
            loop.execute { [weak self] in
                guard let self, !self.isShuttingDown else { return }
                channel.close(promise: nil)
            }
        }
        inboundForwardingTask = task
    }

    // MARK: - `.stdErr` control-frame framing (REMOTE-9)

    /// Accumulates inbound `.stdErr` bytes, then drains complete frames
    /// if the coordinator exists. Pre-attach (`coordinator == nil`),
    /// bytes only accumulate — `installCoordinator` calls
    /// `drainControlFrames(channel:)` to replay them once attach
    /// completes, so an early `.hello` is never lost.
    private func ingestStdErr(_ data: Data, channel: Channel) {
        guard !stdErrPoisoned else { return }
        stdErrDecoder.append(data)
        if coordinator != nil {
            drainControlFrames(channel: channel)
        }
        // Bound pre-attach accumulation too (frames don't drain until
        // the coordinator exists): anything past one max-size frame's
        // worth of undrained bytes is a protocol violation. On the
        // pre-attach path (where `drainControlFrames` never runs above)
        // this is a plain `count`-only check; once frames DO start
        // draining, `isOverAccumulated` compares against the
        // still-unconsumed tail so a perfectly ordinary long-running
        // connection that has drained many frames doesn't trip it.
        if stdErrDecoder.isOverAccumulated {
            poisonStdErr(channel: channel)
        }
    }

    /// Extracts complete `<u32 BE length><UTF-8 JSON>` frames from the
    /// `StdErrControlFraming.Decoder`, forwarding each parsed
    /// `WebControlEnvelope` to the coordinator. A `.hello` frame flips
    /// `receivedHello`; every other frame is dropped until one arrives (a
    /// well-behaved client always sends `.hello` first). A length above
    /// `StdErrControlFraming.maxFrameLength` poisons the carrier — see
    /// `stdErrPoisoned`.
    private func drainControlFrames(channel: Channel) {
        let (frames, oversized) = stdErrDecoder.drain()
        for payload in frames {
            guard let envelope = try? WebControlEnvelope.parse(payload) else {
                // A structurally-valid `.hello` whose grid exceeds
                // `WebControlEnvelope.maxGridDimension` fails `parse`
                // outright (`.invalidDimension`). Since only a
                // successfully-parsed `.hello` ever flips
                // `receivedHello`, silently dropping it here (the
                // pre-existing behavior) would permanently strand an
                // otherwise carrier-capable client: every future frame
                // keeps failing the same way, so it can never attach,
                // never take control, and its keystrokes vanish into the
                // pre-hello ungated path forever with no error surfaced.
                // Detect the hello shape leniently and clamp the grid
                // instead of rejecting.
                if !receivedHello, let lenientHello = Self.parseLenientHello(payload) {
                    receivedHello = true
                    coordinator?.handleControl(lenientHello)
                }
                continue
            }
            if case .hello = envelope {
                receivedHello = true
            }
            guard receivedHello else { continue }
            coordinator?.handleControl(envelope)
        }
        // Framing is unrecoverable once a length header exceeds the cap
        // (we can't tell where the next frame starts) — poison after
        // processing whatever complete frames arrived before it, exactly
        // like the per-frame loop this replaced.
        if oversized {
            poisonStdErr(channel: channel)
        }
    }

    /// Marks the `.stdErr` carrier as unrecoverably framed (see
    /// `stdErrPoisoned`) and, if this client had already proven protocol
    /// awareness via `.hello`, closes the channel.
    ///
    /// Pre-hello, closing would be gratuitous: `sendText` is still a
    /// silent no-op and inbound `.channel` bytes still flow ungated
    /// (`receivedHello == false`), so a poisoned pre-hello carrier leaves
    /// the client behaving exactly like a legacy (pre-REMOTE-9) one —
    /// nothing is stranded, just no ownership features.
    ///
    /// Post-hello, the owner-gated path is active on both directions:
    /// silently abandoning the carrier would leave the client receiving
    /// grid/ownership envelopes while its own takeControl/resize requests
    /// can never be parsed again, and — if it isn't the owner — its
    /// keystrokes are discarded too. That's a silent, unrecoverable brick.
    /// Closing the channel instead surfaces a disconnect the client can
    /// react to (reconnect), and drives the existing `channelInactive`
    /// path to run `detach()`/`stream.close()` cleanup exactly once.
    private func poisonStdErr(channel: Channel) {
        stdErrPoisoned = true
        stdErrDecoder.reset()
        guard receivedHello else { return }
        channel.close(promise: nil)
    }

    /// Lenient fallback for a `.hello` envelope that is structurally valid
    /// (well-formed JSON, `type == "hello"`, every other field present)
    /// but whose declared grid exceeds `WebControlEnvelope.maxGridDimension`
    /// — the one condition `WebControlEnvelope.parse` rejects outright via
    /// `.invalidDimension` that this handler can safely recover from by
    /// clamping instead. Deliberately narrow: any OTHER malformation
    /// (missing/invalid clientID, kind, role, visible, or a non-positive
    /// grid dimension) returns `nil` and the frame is dropped exactly as
    /// before — those shapes were never the reported failure mode, and
    /// synthesizing defaults for them risks attaching a client under
    /// fabricated identity instead of surfacing the malformed frame.
    private static func parseLenientHello(_ payload: Data) -> WebControlEnvelope? {
        guard
            let json = try? JSONSerialization.jsonObject(with: payload),
            let dict = json as? [String: Any],
            dict["type"] as? String == "hello",
            let clientIDRaw = dict["clientID"] as? String,
            let kindRaw = dict["kind"] as? String,
            let kind = DisplayClientKind(rawValue: kindRaw),
            let roleRaw = dict["role"] as? String,
            let role = DisplayClientRole(rawValue: roleRaw),
            let visible = dict["visible"] as? Bool,
            let cols = dict["cols"] as? Int, cols > 0,
            let rows = dict["rows"] as? Int, rows > 0
        else { return nil }
        return .hello(
            clientID: DisplayClientID(clientIDRaw),
            kind: kind,
            role: role,
            visible: visible,
            cols: WebControlEnvelope.clampedGridDimension(cols),
            rows: WebControlEnvelope.clampedGridDimension(rows)
        )
    }
}

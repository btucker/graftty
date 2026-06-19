import Foundation
import GhosttyKit
import GrafttyRemoteClient

final class RemoteTerminalSurfaceBackend {
    typealias SurfaceWriteBuffer = (ghostty_surface_t, Data) -> Void

    enum Error: Swift.Error {
        case alreadyStarted
        case closed
    }

    private enum Lifecycle {
        case idle
        case running
        case closed
    }

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr, len > 0 else { return }
        guard let backend = RemoteTerminalSurfaceBackend.backend(from: userdata) else { return }

        backend.sendToRemote(Data(bytes: ptr, count: len))
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, _, _ in
        guard let userdata else { return }
        guard let backend = RemoteTerminalSurfaceBackend.backend(from: userdata) else { return }

        backend.receiveResize(cols: cols, rows: rows)
    }

    private let client: WebSocketClient
    private let writeBuffer: SurfaceWriteBuffer
    private let lock = NSLock()

    private var lifecycle: Lifecycle = .idle
    private var surface: ghostty_surface_t?
    private var receiveTask: Task<Void, Never>?
    private var sendTail: Task<Void, Never>?
    private var userdataPointer: UnsafeMutableRawPointer?
    private var requestRefresh: () -> Void

    init(
        client: WebSocketClient,
        writeBuffer: @escaping SurfaceWriteBuffer = { surface, data in
            RemoteTerminalSurfaceBackend.defaultWriteBuffer(surface: surface, data: data)
        },
        requestRefresh: @escaping () -> Void = {}
    ) {
        self.client = client
        self.writeBuffer = writeBuffer
        self.requestRefresh = requestRefresh

        let userdata = RemoteTerminalSurfaceBackendUserdata(backend: self)
        self.userdataPointer = Unmanaged.passRetained(userdata).toOpaque()
    }

    convenience init(
        client: WebSocketClient,
        writeBuffer: @escaping (Data) -> Void,
        requestRefresh: @escaping () -> Void = {}
    ) {
        self.init(
            client: client,
            writeBuffer: { _, data in writeBuffer(data) },
            requestRefresh: requestRefresh
        )
    }

    deinit {
        close()
        if let userdataPointer {
            Unmanaged<RemoteTerminalSurfaceBackendUserdata>
                .fromOpaque(userdataPointer)
                .release()
        }
    }

    func configure(_ config: inout ghostty_surface_config_s) {
        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_userdata = userdataPointer
        config.receive_buffer = Self.receiveBufferCallback
        config.receive_resize = Self.receiveResizeCallback
    }

    func start(surface: ghostty_surface_t) throws {
        lock.lock()
        switch lifecycle {
        case .idle:
            lifecycle = .running
            self.surface = surface
        case .running:
            lock.unlock()
            throw Error.alreadyStarted
        case .closed:
            lock.unlock()
            throw Error.closed
        }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(surface: surface)
        }
        lock.unlock()
    }

    func write(_ data: Data, claimEngagement _: Bool = true) throws {
        guard !data.isEmpty else { return }

        lock.lock()
        guard case .closed = lifecycle else {
            lock.unlock()
            sendToRemote(data)
            return
        }
        lock.unlock()
        throw Error.closed
    }

    func bindSurfaceSync(
        currentGridSize _: @escaping () -> (cols: UInt16, rows: UInt16)?,
        requestRefresh: @escaping () -> Void
    ) {
        lock.lock()
        self.requestRefresh = requestRefresh
        lock.unlock()
    }

    func close() {
        let task: Task<Void, Never>?
        lock.lock()
        if case .closed = lifecycle {
            lock.unlock()
            return
        }
        lifecycle = .closed
        surface = nil
        task = receiveTask
        receiveTask = nil
        sendTail?.cancel()
        sendTail = nil
        lock.unlock()

        task?.cancel()
        client.close()
    }

    func surfaceWasFreed() {
        lock.lock()
        guard let pointer = userdataPointer else {
            lock.unlock()
            return
        }
        userdataPointer = nil
        lock.unlock()

        Unmanaged<RemoteTerminalSurfaceBackendUserdata>
            .fromOpaque(pointer)
            .release()
    }

    var userdataForTesting: UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        return userdataPointer
    }

    private func sendToRemote(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        if case .closed = lifecycle {
            lock.unlock()
            return
        }
        let previous = sendTail
        let client = client
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            try? await client.send(.binary(data))
        }
        sendTail = task
        lock.unlock()
    }

    private func receiveResize(cols: UInt16, rows: UInt16) {
        lock.lock()
        guard case .closed = lifecycle else {
            lock.unlock()
            Task { [client] in
                await client.resize(cols: Int(cols), rows: Int(rows))
            }
            return
        }
        lock.unlock()
    }

    private func receiveLoop(surface: ghostty_surface_t) async {
        while !Task.isCancelled {
            do {
                let frame = try await client.receive()
                guard case let .binary(data) = frame, !data.isEmpty else { continue }
                writeBuffer(surface, data)
                currentRequestRefresh()
            } catch {
                return
            }
        }
    }

    private func currentRequestRefresh() {
        lock.lock()
        let refresh = requestRefresh
        let isClosed: Bool
        if case .closed = lifecycle {
            isClosed = true
        } else {
            isClosed = false
        }
        lock.unlock()

        guard !isClosed else { return }
        refresh()
    }

    private static func defaultWriteBuffer(surface: ghostty_surface_t, data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            ghostty_surface_write_buffer(surface, base, UInt(buffer.count))
        }
    }

    private static func backend(from userdata: UnsafeMutableRawPointer) -> RemoteTerminalSurfaceBackend? {
        Unmanaged<RemoteTerminalSurfaceBackendUserdata>
            .fromOpaque(userdata)
            .takeUnretainedValue()
            .backend
    }
}

extension RemoteTerminalSurfaceBackend: SurfaceHandleZmxBackend {
    func write(_ data: Data) throws {
        try write(data, claimEngagement: true)
    }

    func withProgrammaticInput(_ body: () -> Void) {
        body()
    }

    func withUserInput(_ body: () -> Void) {
        body()
    }

    func markLayoutSettled() {}
    func remoteClientsDidDetach() {}
    func resyncVisibleGrid() {}
}

private final class RemoteTerminalSurfaceBackendUserdata {
    weak var backend: RemoteTerminalSurfaceBackend?

    init(backend: RemoteTerminalSurfaceBackend) {
        self.backend = backend
    }
}

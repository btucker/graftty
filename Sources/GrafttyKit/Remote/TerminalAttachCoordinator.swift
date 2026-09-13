import Foundation
import GrafttyProtocol

public final class DisplayOwnershipBroadcaster: @unchecked Sendable {
    internal final class Registration: @unchecked Sendable {
        private let onCancel: () -> Void
        private let lock = NSLock()
        private var cancelled = false

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func cancel() {
            lock.lock()
            if cancelled {
                lock.unlock()
                return
            }
            cancelled = true
            lock.unlock()
            onCancel()
        }

        deinit {
            cancel()
        }
    }

    private struct Subscriber {
        let clientID: DisplayClientID
        let send: @Sendable (DisplayOwnershipSnapshot) -> Void
    }

    private let lock = NSLock()
    private var subscribers: [String: [UUID: Subscriber]] = [:]
    /// Held for the broadcaster's lifetime so it stays subscribed to the
    /// shared ownership store; cancels (unsubscribes) when this broadcaster
    /// is torn down.
    private var storeObserverToken: SessionDisplayOwnershipStore.ObserverToken?

    /// When `store` is provided, the broadcaster subscribes to every owner
    /// mutation on it and re-broadcasts the snapshot to connected clients.
    /// This is what propagates *Mac-host* ownership changes — those mutate the
    /// shared store directly (via `HostManagedZmxOwnership`) and never pass
    /// through this bridge's own broadcast calls, so without this subscription
    /// web/iOS followers never learn the Mac took or released the display.
    public init(store: SessionDisplayOwnershipStore? = nil) {
        if let store {
            storeObserverToken = store.addObserver { [weak self] snapshot in
                self?.broadcast(snapshot)
            }
        }
    }

    func register(
        sessionName: String,
        clientID: DisplayClientID,
        send: @escaping @Sendable (DisplayOwnershipSnapshot) -> Void
    ) -> Registration {
        let id = UUID()
        lock.lock()
        var sessionSubscribers = subscribers[sessionName] ?? [:]
        sessionSubscribers[id] = Subscriber(clientID: clientID, send: send)
        subscribers[sessionName] = sessionSubscribers
        lock.unlock()

        return Registration { [weak self] in
            self?.unregister(sessionName: sessionName, id: id)
        }
    }

    func broadcast(_ snapshot: DisplayOwnershipSnapshot) {
        lock.lock()
        let sends = subscribers[snapshot.sessionName]?.values.map(\.send) ?? []
        lock.unlock()

        for send in sends {
            send(snapshot)
        }
    }

    private func unregister(sessionName: String, id: UUID) {
        lock.lock()
        if var sessionSubscribers = subscribers[sessionName] {
            sessionSubscribers.removeValue(forKey: id)
            subscribers[sessionName] = sessionSubscribers.isEmpty ? nil : sessionSubscribers
        }
        lock.unlock()
    }
}

/// Transport-neutral display-ownership coordinator for a single attached
/// client. Owns the handshake/claim/resize/detach flow against the shared
/// `SessionDisplayOwnershipStore` and reports outcomes back to the caller
/// via the `sendText:resize:write:` closures supplied at init. Two
/// consumers drive it today: the `/ws` bridge (`WebSocketBridgeHandler`)
/// and `GrafttyHostAgent`'s SSH terminal path (`TerminalSessionHandler`,
/// REMOTE-9) — the transport-neutral design anticipated exactly this
/// second consumer.
///
/// Made `public` (REMOTE-9) so `TerminalSessionHandler` can construct and
/// drive it directly.
public final class TerminalAttachCoordinator: @unchecked Sendable {
    private let sessionName: String
    private let clientID: DisplayClientID
    private let defaultKind: DisplayClientKind
    private let ownershipStore: SessionDisplayOwnershipStore
    private let broadcaster: DisplayOwnershipBroadcaster
    private let sendText: @Sendable (String) -> Void
    private let resize: @Sendable (UInt16, UInt16) -> Void
    private let followDisplayGrid: @Sendable (DisplayOwnershipSnapshot) -> Void
    private let write: @Sendable (Data) -> Void
    private let lock = NSLock()

    private var registration: DisplayOwnershipBroadcaster.Registration?
    private var boundProtocolClientID: DisplayClientID?
    private var attachedKind: DisplayClientKind?
    private var attached = false
    private var detached = false
    private var lastAcceptedOwnerGrid: DisplayGrid?
    private let supportsImagePaste: Bool
    private let pasteImage: @MainActor @Sendable (Data) -> Bool
    /// Run the final ownership check and input enqueue together on the
    /// transport's event loop, after clipboard work leaves MainActor.
    private let dispatchImageCommit: @Sendable (@escaping @Sendable () -> Void) -> Void
    private var imageUpload = ImagePasteUpload()
    private var imageUploadEpoch: UInt64?
    private var pendingImageCommit: UUID?

    public init(
        sessionName: String,
        clientID: DisplayClientID,
        defaultKind: DisplayClientKind,
        ownershipStore: SessionDisplayOwnershipStore,
        broadcaster: DisplayOwnershipBroadcaster,
        sendText: @escaping @Sendable (String) -> Void,
        resize: @escaping @Sendable (UInt16, UInt16) -> Void,
        write: @escaping @Sendable (Data) -> Void,
        followDisplayGrid: @escaping @Sendable (DisplayOwnershipSnapshot) -> Void = { _ in },
        supportsImagePaste: Bool = true,
        pasteImage: (@MainActor @Sendable (Data) -> Bool)? = nil,
        dispatchImageCommit: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { $0() }
    ) {
        self.sessionName = sessionName
        self.clientID = clientID
        self.defaultKind = defaultKind
        self.ownershipStore = ownershipStore
        self.broadcaster = broadcaster
        self.sendText = sendText
        self.resize = resize
        self.followDisplayGrid = followDisplayGrid
        self.write = write
        self.supportsImagePaste = supportsImagePaste
        self.pasteImage = pasteImage ?? { HostImagePasteboard.write($0) }
        self.dispatchImageCommit = dispatchImageCommit
        self.registration = broadcaster.register(sessionName: sessionName, clientID: clientID) { [weak self] snapshot in
            self?.sendOwnershipSnapshot(snapshot)
        }
    }

    deinit {
        detach()
    }

    public func handleControl(_ envelope: WebControlEnvelope) {
        switch envelope {
        case let .hello(protocolClientID, _, role, visible, cols, rows):
            guard bindOrVerify(protocolClientID: protocolClientID) else { return }
            let kind = defaultKind
            let grid = try! DisplayGrid(cols: cols, rows: rows)
            lock.lock()
            attached = true
            attachedKind = kind
            lock.unlock()
            let snapshot = ownershipStore.attachClient(
                sessionName: sessionName,
                clientID: clientID,
                kind: kind,
                role: role,
                visible: visible,
                grid: grid
            )
            noteAcceptedOwnerGridIfCurrentOwner(snapshot: snapshot)
            broadcaster.broadcast(snapshot)
            if supportsImagePaste { sendText(WebControlEnvelope.imagePaste(.available).encoded()) }

        case let .takeControl(protocolClientID, _, cols, rows):
            guard bindOrVerify(protocolClientID: protocolClientID) else { return }
            let kind = currentKind() ?? defaultKind
            ensureAttached(kind: kind, grid: try! DisplayGrid(cols: cols, rows: rows))
            let grid = try! DisplayGrid(cols: cols, rows: rows)
            let result = ownershipStore.claimOwner(
                sessionName: sessionName,
                clientID: clientID,
                kind: kind,
                grid: grid,
                fallbackGrid: grid
            )
            if result.accepted {
                acceptOwnerGrid(grid)
                resize(cols, rows)
            }
            broadcaster.broadcast(result.snapshot)

        case let .ownerResize(protocolClientID, epoch, cols, rows):
            guard bindOrVerify(protocolClientID: protocolClientID) else { return }
            let grid = try! DisplayGrid(cols: cols, rows: rows)
            let result = ownershipStore.ownerResize(
                sessionName: sessionName,
                clientID: clientID,
                epoch: epoch,
                grid: grid
            )
            if result.accepted {
                acceptOwnerGrid(grid)
                resize(cols, rows)
            }
            broadcaster.broadcast(result.snapshot)

        case let .resize(cols, rows):
            handleLegacyResize(cols: cols, rows: rows)

        case .imagePaste(let message):
            handleImagePaste(message)

        case .grid, .ownership:
            break
        }
    }

    private func handleImagePaste(_ message: ImagePasteMessage) {
        let id: UUID
        switch message {
        case .begin(let value, _), .chunk(let value, _, _), .commit(let value), .cancel(let value):
            id = value
        case .available, .result:
            return
        }
        do {
            let completed: Data? = try lock.withLock {
                let snapshot = ownershipStore.snapshot(sessionName: sessionName)
                guard supportsImagePaste, !detached, attached, snapshot.ownerClientID == clientID else {
                    throw ImagePasteUpload.UploadError.invalidUpload
                }
                if case .cancel = message {
                    imageUpload.cancel(id: id)
                    if pendingImageCommit == id { pendingImageCommit = nil }
                    return nil
                }
                guard pendingImageCommit == nil else { throw ImagePasteUpload.UploadError.invalidUpload }
                switch message {
                case .begin(_, let byteCount):
                    try imageUpload.begin(id: id, byteCount: byteCount)
                    imageUploadEpoch = snapshot.epoch
                case .chunk(_, let offset, let data):
                    guard imageUploadEpoch == snapshot.epoch else { throw ImagePasteUpload.UploadError.invalidUpload }
                    try imageUpload.append(id: id, offset: offset, data: data)
                case .commit:
                    guard imageUploadEpoch == snapshot.epoch else { throw ImagePasteUpload.UploadError.invalidUpload }
                    let data = try imageUpload.finish(id: id)
                    pendingImageCommit = id
                    return data
                default:
                    break
                }
                return nil
            }
            guard let completed else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let error: String? = self.lock.withLock {
                    let snapshot = self.ownershipStore.snapshot(sessionName: self.sessionName)
                    guard !self.detached, self.pendingImageCommit == id,
                          snapshot.ownerClientID == self.clientID,
                          snapshot.epoch == self.imageUploadEpoch else {
                        if self.pendingImageCommit == id { self.pendingImageCommit = nil }
                        return "Pane control changed before the image could be pasted."
                    }
                    guard self.pasteImage(completed) else {
                        self.pendingImageCommit = nil
                        return "The host could not put this image on its clipboard."
                    }
                    return nil
                }
                if let error {
                    self.sendText(WebControlEnvelope.imagePaste(.result(id: id, error: error)).encoded())
                } else {
                    self.dispatchImageCommit { [weak self] in
                        self?.enqueueImagePaste(id: id)
                    }
                }
            }
        } catch {
            lock.withLock { imageUpload.cancel(id: id) }
            sendText(WebControlEnvelope.imagePaste(.result(
                id: id, error: "Image upload rejected. Check pane control and try pasting again."
            )).encoded())
        }
    }

    private func enqueueImagePaste(id: UUID) {
        let error: String? = lock.withLock {
            defer { if pendingImageCommit == id { pendingImageCommit = nil } }
            let snapshot = ownershipStore.snapshot(sessionName: sessionName)
            guard !detached, pendingImageCommit == id,
                  snapshot.ownerClientID == clientID,
                  snapshot.epoch == imageUploadEpoch else {
                return "Pane control changed before the image could be pasted."
            }
            return nil
        }
        // A writer may close its channel synchronously on queue overflow,
        // which re-enters detach(). Do not hold our lock across that call.
        if error == nil { write(Data([0x16])) }
        // Success confirms submission to the transport's input writer.
        // The terminal protocol cannot acknowledge the CLI's clipboard read.
        sendText(WebControlEnvelope.imagePaste(.result(id: id, error: error)).encoded())
    }

    public func handleBinary(_ data: Data) {
        if isCurrentOwner() {
            write(data)
            return
        }

        let snapshot = ownershipStore.snapshot(sessionName: sessionName)
        broadcaster.broadcast(snapshot)
    }

    public func handlePTYSize(cols: UInt16, rows: UInt16) {
        guard let grid = try? DisplayGrid(cols: cols, rows: rows) else { return }
        sendText(WebControlEnvelope.grid(cols: cols, rows: rows).encoded())
        let snapshot = ownershipStore.snapshot(sessionName: sessionName, fallbackGrid: grid)
        if isCurrentOwner(), currentLastAcceptedOwnerGrid() == grid {
            broadcaster.broadcast(snapshot)
        } else {
            sendOwnershipSnapshot(snapshot)
        }
    }

    public func detach() {
        lock.lock()
        if detached {
            lock.unlock()
            return
        }
        detached = true
        imageUpload = .init()
        imageUploadEpoch = nil
        pendingImageCommit = nil
        let wasAttached = attached
        let fallbackGrid = lastAcceptedOwnerGrid
        let registration = self.registration
        self.registration = nil
        lock.unlock()

        registration?.cancel()
        guard wasAttached else { return }
        let snapshot = ownershipStore.detachClient(
            sessionName: sessionName,
            clientID: clientID,
            fallbackGrid: fallbackGrid ?? .daemonFallback
        )
        broadcaster.broadcast(snapshot)
    }

    private func handleLegacyResize(cols: UInt16, rows: UInt16) {
        let grid = try! DisplayGrid(cols: cols, rows: rows)
        let kind = currentKind() ?? defaultKind
        ensureAttached(kind: kind, grid: grid)

        let snapshot = ownershipStore.snapshot(sessionName: sessionName, fallbackGrid: grid)
        if snapshot.ownerClientID == clientID {
            let result = ownershipStore.ownerResize(
                sessionName: sessionName,
                clientID: clientID,
                epoch: snapshot.epoch,
                grid: grid
            )
            if result.accepted {
                acceptOwnerGrid(grid)
                resize(cols, rows)
            }
            broadcaster.broadcast(result.snapshot)
            return
        }

        broadcaster.broadcast(snapshot)
    }

    private func ensureAttached(kind: DisplayClientKind, grid: DisplayGrid) {
        lock.lock()
        if attached {
            lock.unlock()
            return
        }
        attached = true
        attachedKind = kind
        lock.unlock()
        let snapshot = ownershipStore.attachClient(
            sessionName: sessionName,
            clientID: clientID,
            kind: kind,
            role: .interactive,
            visible: true,
            grid: grid
        )
        noteAcceptedOwnerGridIfCurrentOwner(snapshot: snapshot)
        broadcaster.broadcast(snapshot)
    }

    private func bindOrVerify(protocolClientID: DisplayClientID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if protocolClientID == clientID { return true }
        if let boundProtocolClientID {
            return boundProtocolClientID == protocolClientID
        }
        boundProtocolClientID = protocolClientID
        return true
    }

    private func currentKind() -> DisplayClientKind? {
        lock.lock()
        defer { lock.unlock() }
        return attachedKind
    }

    private func isCurrentOwner() -> Bool {
        ownershipStore.snapshot(sessionName: sessionName).ownerClientID == clientID
    }

    private func acceptOwnerGrid(_ grid: DisplayGrid) {
        lock.lock()
        lastAcceptedOwnerGrid = grid
        lock.unlock()
    }

    private func currentLastAcceptedOwnerGrid() -> DisplayGrid? {
        lock.lock()
        defer { lock.unlock() }
        return lastAcceptedOwnerGrid
    }

    private func noteAcceptedOwnerGridIfCurrentOwner(snapshot: DisplayOwnershipSnapshot) {
        guard snapshot.ownerClientID == clientID else { return }
        acceptOwnerGrid(snapshot.grid)
    }

    private func sendOwnershipSnapshot(_ snapshot: DisplayOwnershipSnapshot) {
        lock.withLock {
            if let epoch = imageUploadEpoch,
               snapshot.epoch > epoch || (snapshot.epoch == epoch && snapshot.ownerClientID != clientID) {
                imageUpload = .init()
                imageUploadEpoch = nil
            }
        }
        let shouldFollow = lock.withLock { attached && !detached }
            && !snapshot.isOwnerless && snapshot.ownerClientID != clientID
        if shouldFollow,
           ownershipStore.snapshot(sessionName: sessionName).grid == snapshot.grid {
            followDisplayGrid(snapshot)
        }
        sendText(WebControlEnvelope.ownership(localizedSnapshot(snapshot)).encoded())
    }

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
        lock.lock()
        defer { lock.unlock() }
        return boundProtocolClientID
    }
}

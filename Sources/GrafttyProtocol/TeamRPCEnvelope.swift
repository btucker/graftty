import Foundation

/// Requests and replies share the authenticated team's SSH subsystem.
public struct TeamRPCEnvelope: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case request, response }
    public var kind: Kind
    public var requestID: UUID
    public var payload: Data

    public init(kind: Kind, requestID: UUID, payload: Data) {
        self.kind = kind
        self.requestID = requestID
        self.payload = payload
    }
}

/// Correlates requests in both directions without opening a reverse connection.
public actor TeamRPCSession {
    public typealias Handler = @Sendable (Data) async -> Data
    public typealias Writer = @Sendable (Data) async throws -> Void
    public enum SessionError: Error, Equatable, Sendable {
        case channelClosed, timedOut, overloaded, malformedEnvelope, messageTooLarge
    }

    public nonisolated let id = UUID()
    private let handler: Handler
    private let writer: Writer
    private let responseTimeout: Duration
    private let onClose: @Sendable () async -> Void
    public static let maximumEnvelopeBytes = 4 * 1024 * 1024
    private var closed = false
    private struct Pending {
        var continuation: CheckedContinuation<Data, Error>?
        let deadline: Task<Void, Never>
        let write: Task<Void, Never>
        var writeFinished = false
    }
    private var pending: [UUID: Pending] = [:]
    private var incoming: [UUID: Task<Void, Never>] = [:]
    private static let maximumPending = 256

    public init(
        handler: @escaping Handler,
        writer: @escaping Writer,
        responseTimeout: Duration = .seconds(3),
        onClose: @escaping @Sendable () async -> Void = {}
    ) {
        self.handler = handler
        self.writer = writer
        self.responseTimeout = responseTimeout
        self.onClose = onClose
    }

    public func send(_ payload: Data) async throws -> Data {
        guard !closed else { throw SessionError.channelClosed }
        try Task.checkCancellation()
        guard pending.count < Self.maximumPending else { throw SessionError.overloaded }
        let requestID = UUID()
        let bytes = try JSONEncoder().encode(TeamRPCEnvelope(kind: .request, requestID: requestID, payload: payload))
        guard bytes.count <= Self.maximumEnvelopeBytes else { throw SessionError.messageTooLarge }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task {
                    do { try await Task.sleep(for: responseTimeout) } catch { return }
                    finish(requestID, result: .failure(SessionError.timedOut))
                }
                let write = Task {
                    defer { finishWrite(requestID) }
                    do {
                        try Task.checkCancellation()
                        guard !closed else { throw SessionError.channelClosed }
                        try await writer(bytes)
                    } catch {
                        finish(requestID, result: .failure(error))
                    }
                }
                pending[requestID] = Pending(continuation: continuation, deadline: deadline, write: write)
            }
        } onCancel: {
            Task { await self.finish(requestID, result: .failure(CancellationError())) }
        }
    }

    public func receive(_ bytes: Data) async {
        guard !closed else { return }
        guard bytes.count <= Self.maximumEnvelopeBytes else {
            close(error: SessionError.messageTooLarge)
            return
        }
        guard let envelope = try? JSONDecoder().decode(TeamRPCEnvelope.self, from: bytes) else {
            close(error: SessionError.malformedEnvelope)
            return
        }
        switch envelope.kind {
        case .response:
            finish(envelope.requestID, result: .success(envelope.payload))
        case .request:
            guard incoming.count < Self.maximumPending, incoming[envelope.requestID] == nil else {
                close(error: SessionError.overloaded)
                return
            }
            incoming[envelope.requestID] = Task {
                defer { incoming[envelope.requestID] = nil }
                guard !Task.isCancelled, !closed else { return }
                let response = await handler(envelope.payload)
                guard !Task.isCancelled, !closed else { return }
                do {
                    let bytes = try JSONEncoder().encode(TeamRPCEnvelope(kind: .response, requestID: envelope.requestID, payload: response))
                    guard bytes.count <= Self.maximumEnvelopeBytes else { throw SessionError.messageTooLarge }
                    try await writer(bytes)
                } catch {
                    close(error: error)
                }
            }
        }
    }

    public func close() { close(error: SessionError.channelClosed) }

    private func close(error: any Error) {
        guard !closed else { return }
        closed = true
        let requests = pending
        pending.removeAll()
        for request in requests.values {
            request.deadline.cancel()
            request.write.cancel()
            request.continuation?.resume(throwing: error)
        }
        incoming.values.forEach { $0.cancel() }
        incoming.removeAll()
        Task { [onClose] in await onClose() }
    }

    private func finish(_ requestID: UUID, result: Result<Data, Error>) {
        guard var request = pending[requestID], let continuation = request.continuation else { return }
        request.continuation = nil
        // Canceling an NIO write task does not cancel the queued write.
        // Keep its admission slot until the writer actually completes.
        pending[requestID] = request.writeFinished ? nil : request
        request.deadline.cancel()
        request.write.cancel()
        continuation.resume(with: result)
    }

    private func finishWrite(_ requestID: UUID) {
        guard var request = pending[requestID] else { return }
        request.writeFinished = true
        pending[requestID] = request.continuation == nil ? nil : request
    }
}

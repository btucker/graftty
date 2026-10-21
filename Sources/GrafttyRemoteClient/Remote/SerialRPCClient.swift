import Foundation

/// FIFO façade over a single-in-flight RPC channel driver.
///
/// Swift actors are reentrant at `await` boundaries, so a plain actor
/// forwarding to the driver would let a second caller reach the driver's
/// busy guard. This one links each request behind the previous before it
/// awaits the driver. `close()` bumps the connection generation and cancels
/// every queued request, so nothing queued against one connection can reach
/// a replacement driver.
actor SerialRPCClient<Request: Sendable, Response: Sendable> {
    struct Policy: Sendable {
        /// Thrown by calls made while closed, and by calls whose connection
        /// was closed before their response arrived.
        var closedError: any Error
        /// Maximum requests queued or in flight, with the error past it.
        var queueLimit: (count: Int, error: any Error)?
        /// A cancelled caller cancels its queued request and closes the
        /// driver, because the wire cannot discard one in-flight reply.
        /// Otherwise a cancelled caller still waits for its response.
        var closesOnCallerCancellation: Bool
    }

    private let openDriver: @Sendable () async throws -> Void
    private let sendDriver: @Sendable (Request) async throws -> Response
    private let closeDriver: @Sendable () -> Void
    private let policy: Policy
    private var operations: [UUID: Task<Response, Error>] = [:]
    private var tail: (id: UUID, task: Task<Response, Error>)?
    private var generation: UInt64 = 0
    private var isOpen = false

    init(
        policy: Policy,
        open: @escaping @Sendable () async throws -> Void,
        send: @escaping @Sendable (Request) async throws -> Response,
        close: @escaping @Sendable () -> Void
    ) {
        self.policy = policy
        self.openDriver = open
        self.sendDriver = send
        self.closeDriver = close
    }

    var pendingCount: Int { operations.count }

    func open() async throws {
        let epoch = generation
        try await openDriver()
        guard epoch == generation,
              !(policy.closesOnCallerCancellation && Task.isCancelled) else {
            closeDriver()
            throw policy.closedError
        }
        isOpen = true
    }

    func close() {
        generation &+= 1
        isOpen = false
        for task in operations.values { task.cancel() }
        operations.removeAll()
        tail = nil
        closeDriver()
    }

    /// Closes the driver immediately, then the queue once the actor is free.
    nonisolated func cancel() {
        closeDriver()
        Task { await close() }
    }

    func send(_ request: Request) async throws -> Response {
        guard isOpen,
              !(policy.closesOnCallerCancellation && Task.isCancelled) else {
            throw policy.closedError
        }
        if let limit = policy.queueLimit, operations.count >= limit.count {
            throw limit.error
        }
        let epoch = generation
        let previous = tail?.task
        let id = UUID()
        let task = Task { [sendDriver] in
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            let response = try await sendDriver(request)
            try Task.checkCancellation()
            return response
        }
        operations[id] = task
        tail = (id, task)
        defer {
            operations[id] = nil
            if tail?.id == id { tail = nil }
        }
        let response: Response
        if policy.closesOnCallerCancellation {
            response = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { [closeDriver] in
                task.cancel()
                closeDriver()
            }
        } else {
            response = try await task.value
        }
        guard isOpen, epoch == generation else { throw policy.closedError }
        return response
    }
}

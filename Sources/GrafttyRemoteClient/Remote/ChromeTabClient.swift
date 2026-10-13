import Foundation
import GrafttyProtocol

public protocol ChromeTabChannelDriver: Sendable {
    func open() async throws
    func close()
    func send(_ request: ChromeTabRequest) async throws -> ChromeTabResponse
}

extension ChromeTabChannelClient: ChromeTabChannelDriver {}

/// Serializes input behind frame pulls with a fixed queue bound.
public actor ChromeTabClient {
    public enum Failure: Error { case closed, queueFull }
    private let driver: any ChromeTabChannelDriver
    private var open = false
    private var generation: UInt64 = 0
    private var requests: [UUID: Task<ChromeTabResponse, Error>] = [:]
    private var tail: (id: UUID, task: Task<ChromeTabResponse, Error>)?
    public var pendingRequestCount: Int { requests.count }

    public init(driver: any ChromeTabChannelDriver) { self.driver = driver }
    public func open() async throws {
        let epoch = generation
        try await driver.open()
        guard generation == epoch, !Task.isCancelled else { driver.close(); throw Failure.closed }
        open = true
    }
    public nonisolated func cancel() {
        driver.close()
        Task { await close() }
    }
    public func close() {
        generation &+= 1; open = false
        for task in requests.values { task.cancel() }
        requests.removeAll(); tail = nil; driver.close()
    }
    public func send(_ request: ChromeTabRequest) async throws -> ChromeTabResponse {
        guard open, !Task.isCancelled else { throw Failure.closed }
        guard requests.count < 8 else { throw Failure.queueFull }
        let epoch = generation
        let previous = tail?.task
        let id = UUID()
        let task = Task { [driver] in
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            let response = try await driver.send(request)
            try Task.checkCancellation()
            return response
        }
        requests[id] = task; tail = (id, task)
        defer { requests[id] = nil; if tail?.id == id { tail = nil } }
        return try await withTaskCancellationHandler {
            let response = try await task.value
            guard generation == epoch, open else { throw Failure.closed }
            return response
        } onCancel: {
            task.cancel()
            // The wire has no request IDs. Close before accepting another reply.
            self.driver.close()
        }
    }
}

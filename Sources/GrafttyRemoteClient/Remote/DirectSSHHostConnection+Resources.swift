import Foundation
import GrafttyProtocol

extension DirectSSHHostConnection {
    /// Read one authenticated sample without retaining a background subscription.
    public func resourceObservation(timeout: Duration = .seconds(15)) async throws -> HostResourceObservation? {
        guard timeout > .zero else { throw ConnectionError.timedOut }
        let snapshots = AsyncStream<HostResourceObservation?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let client = try makePanesStateClient(onSnapshot: { _ in },
            onClosed: { _ in snapshots.continuation.finish() }, originAware: true, requestReply: true,
            onSidebarSnapshot: { sidebar in
                let receivedAt = Date().timeIntervalSince1970
                snapshots.continuation.yield(sidebar?.hostResources.map {
                    HostResourceObservation(sample: $0, receivedAt: receivedAt)
                })
            })
        defer { client.close(); snapshots.continuation.finish() }
        try await client.open()
        return try await withThrowingTaskGroup(of: HostResourceObservation?.self) { group in
            group.addTask {
                for await observation in snapshots.stream { return observation }
                try Task.checkCancellation()
                throw ConnectionError.notConnected
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ConnectionError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

}

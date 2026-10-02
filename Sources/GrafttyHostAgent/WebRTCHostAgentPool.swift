import Foundation
import GrafttyProtocol
import WebRTC

/// Admits one independent inbound connection agent per authenticated device.
/// Pending creation and negotiation reserve capacity before any actor hop.
public actor WebRTCHostAgentPool {
    internal typealias Negotiate = @Sendable (
        WebRTCHostAgent, RTCSessionDescription, RemoteDeviceID, Bool
    ) async throws -> RTCSessionDescription

    /// All mutable entry bookkeeping belongs to the pool actor. The task
    /// publishes one configured agent even if another offer arrives mid-init.
    private final class Entry {
        let agent: Task<WebRTCHostAgent, Never>
        var offersInFlight = 0
        var revision: UInt64 = 0
        var drainedWaiters: [CheckedContinuation<Void, Never>] = []

        init(makeAgent: @escaping @Sendable () async -> WebRTCHostAgent) {
            agent = Task { await makeAgent() }
        }
    }

    private let maxConnections: Int
    private let makeAgent: @Sendable () async -> WebRTCHostAgent
    private let negotiate: Negotiate
    private var entries: [RemoteDeviceID: Entry] = [:]
    private var isClosing = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        maxConnections: Int = 8,
        makeAgent: @escaping @Sendable () async -> WebRTCHostAgent
    ) {
        precondition(maxConnections > 0)
        self.maxConnections = maxConnections
        self.makeAgent = makeAgent
        self.negotiate = { agent, offer, deviceID, replacing in
            try await agent.acceptOffer(
                offer,
                clientDeviceID: deviceID,
                replacingExistingConnection: replacing
            )
        }
    }

    /// WebRTC-free negotiation seam for admission and reentrancy tests.
    internal init(
        maxConnections: Int = 8,
        makeAgent: @escaping @Sendable () async -> WebRTCHostAgent,
        negotiate: @escaping Negotiate
    ) {
        precondition(maxConnections > 0)
        self.maxConnections = maxConnections
        self.makeAgent = makeAgent
        self.negotiate = negotiate
    }

    public func acceptOffer(
        _ offer: RTCSessionDescription,
        clientDeviceID: RemoteDeviceID,
        replacingExistingConnection: Bool
    ) async throws -> RTCSessionDescription {
        guard !isClosing else { throw WebRTCHostAgent.HostError.busy }
        await prune()
        guard !isClosing else { throw WebRTCHostAgent.HostError.busy }

        let entry: Entry
        let isNew: Bool
        if let existing = entries[clientDeviceID] {
            entry = existing
            isNew = false
        } else {
            guard entries.count < maxConnections else {
                throw WebRTCHostAgent.HostError.busy
            }
            entry = Entry(makeAgent: makeAgent)
            entries[clientDeviceID] = entry
            isNew = true
        }
        entry.offersInFlight += 1
        entry.revision &+= 1
        defer { finishOffer(entry) }

        let agent = await entry.agent.value
        guard entries[clientDeviceID] === entry else {
            throw WebRTCHostAgent.HostError.superseded
        }
        do {
            let answer = try await negotiate(
                agent, offer, clientDeviceID, replacingExistingConnection
            )
            guard entries[clientDeviceID] === entry else {
                await agent.close()
                throw WebRTCHostAgent.HostError.superseded
            }
            return answer
        } catch {
            // A competing ordinary offer must never remove the active entry.
            // A signed replacement may also have superseded this first offer,
            // so only discard its entry if it has no newer live lifecycle.
            if isNew, entry.offersInFlight == 1 {
                let revision = entry.revision
                let state = await agent.state
                if entry.revision == revision,
                   entries[clientDeviceID] === entry,
                   entry.offersInFlight == 1,
                   Self.isDiscardable(state) {
                    entries.removeValue(forKey: clientDeviceID)
                    await agent.close()
                }
            }
            throw error
        }
    }

    public func agent(for deviceID: RemoteDeviceID) async -> WebRTCHostAgent? {
        guard let entry = entries[deviceID] else { return nil }
        let agent = await entry.agent.value
        return entries[deviceID] === entry ? agent : nil
    }

    /// Devices with retained connections, including offers still in progress.
    public var connectedDeviceIDs: [RemoteDeviceID] {
        Array(entries.keys)
    }

    public func closeAll() async {
        if isClosing {
            await withCheckedContinuation { closeWaiters.append($0) }
            return
        }
        isClosing = true
        let closingEntries = Array(entries.values)
        entries.removeAll()
        for entry in closingEntries {
            let agent = await entry.agent.value
            await agent.close()
            if entry.offersInFlight > 0 {
                await withCheckedContinuation { entry.drainedWaiters.append($0) }
            }
            // A replacement awaiting old SSH teardown can resume after the
            // first close. Drain offers before the final close so shutdown
            // cannot return with a late replacement lifecycle alive.
            await agent.close()
        }
        isClosing = false
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func prune() async {
        for (deviceID, entry) in entries {
            guard entry.offersInFlight == 0 else { continue }
            let revision = entry.revision
            let agent = await entry.agent.value
            let state = await agent.state
            guard entry.revision == revision,
                  entries[deviceID] === entry,
                  entry.offersInFlight == 0,
                  Self.isDiscardable(state)
            else { continue }
            entries.removeValue(forKey: deviceID)
            await agent.close()
        }
    }

    private func finishOffer(_ entry: Entry) {
        entry.offersInFlight -= 1
        if entry.offersInFlight == 0 {
            let waiters = entry.drainedWaiters
            entry.drainedWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private static func isDiscardable(_ state: WebRTCHostAgent.State) -> Bool {
        switch state {
        case .idle, .closed, .failed: true
        case .answering, .connected: false
        }
    }
}

import CryptoKit
import Foundation
import GrafttyKit
import GrafttyProtocol
import Testing
import WebRTC
@testable import GrafttyHostAgent

private actor PoolAgentFixtures {
    private var agents: [WebRTCHostAgent]
    private(set) var creationCount = 0

    init(_ agents: [WebRTCHostAgent]) { self.agents = agents }

    func next() -> WebRTCHostAgent {
        creationCount += 1
        return agents.removeFirst()
    }
}

private actor PoolOfferGate {
    private var arrived = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrived = true
        arrivals.forEach { $0.resume() }
        arrivals.removeAll()
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }

    func waitUntilArrived() async {
        if !arrived { await withCheckedContinuation { arrivals.append($0) } }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@Suite("Inbound host connections per paired device")
struct WebRTCHostAgentPoolTests {
    private static let first = RemoteDeviceID(value: "iphone")
    private static let second = RemoteDeviceID(value: "mac")
    private static let offer = RTCSessionDescription(type: .offer, sdp: "")

    @Test("@spec REMOTE-11.18: When two different paired devices send signaling offers, the host shall admit both devices and maintain their connections concurrently.")
    func differentDevicesConnectIndependently() async throws {
        let phone = makeAgent()
        let mac = makeAgent()
        let fixtures = PoolAgentFixtures([phone, mac])
        let pool = makePool(fixtures)
        async let phoneAnswer = pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: false)
        async let macAnswer = pool.acceptOffer(Self.offer, clientDeviceID: Self.second, replacingExistingConnection: false)
        _ = try await (phoneAnswer, macAnswer)
        #expect(Set(await pool.connectedDeviceIDs) == [Self.first, Self.second])
        #expect(await phone.state == .connected)
        #expect(await mac.state == .connected)
        #expect(await fixtures.creationCount == 2)
        await pool.closeAll()
    }

    @Test("@spec REMOTE-11.19: While the host connection pool is at its maximum live connections, the host shall reject an offer from a further device with retryable busy status and leave existing connections untouched.")
    func capacityRejectsOnlyFurtherDevices() async throws {
        let agent = makeAgent()
        let fixtures = PoolAgentFixtures([agent])
        let pool = makePool(fixtures, maxConnections: 1)
        _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: false)
        await #expect(throws: WebRTCHostAgent.HostError.busy) {
            _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.second, replacingExistingConnection: false)
        }
        #expect(await agent.state == .connected)
        #expect(await fixtures.creationCount == 1)
        _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: true)
        #expect(await pool.agent(for: Self.first) === agent)
        #expect(await fixtures.creationCount == 1)
        await pool.closeAll()
    }

    @Test("@spec REMOTE-11.20: When a pooled connection is idle, closed, or failed, the host shall discard its agent so that device can reconnect without replacement proof.", arguments: [WebRTCHostAgent.State.idle, .closed, .failed(reason: "ICE failed")])
    func discardedLifecycleCanReconnect(state: WebRTCHostAgent.State) async throws {
        let previous = makeAgent()
        let replacement = makeAgent()
        let fixtures = PoolAgentFixtures([previous, replacement])
        let pool = makePool(fixtures, maxConnections: 1)
        _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: false)
        await previous.setStateForTesting(state)
        _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: false)
        #expect(await pool.agent(for: Self.first) === replacement)
        #expect(await previous.state == .closed)
        #expect(await replacement.state == .connected)
        await pool.closeAll()
    }

    @Test("@spec REMOTE-11.21: When the host closes its connection pool, the host shall close every pooled connection and clear the pool.")
    func closeAllClosesEveryDevice() async throws {
        let phone = makeAgent()
        let mac = makeAgent()
        let pool = makePool(PoolAgentFixtures([phone, mac]))
        _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: false)
        _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.second, replacingExistingConnection: false)
        await pool.closeAll()
        #expect(await phone.state == .closed)
        #expect(await mac.state == .closed)
        #expect(await pool.connectedDeviceIDs.isEmpty)
        #expect(await pool.agent(for: Self.first) == nil)
        #expect(await pool.agent(for: Self.second) == nil)
    }

    @Test("@spec REMOTE-11.10: When a signed signaling offer requests reconnect for a paired device with an active connection, the host shall replace only that device's lifecycle, admit other devices independently, and reject ordinary same-device offers as busy.")
    func sameDeviceUsesItsExistingAgent() async throws {
        let agent = makeAgent()
        let otherAgent = makeAgent()
        let pool = makePool(PoolAgentFixtures([agent, otherAgent]))
        _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: false)
        _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.second, replacingExistingConnection: true)
        let otherGeneration = await otherAgent.connectionGenerationForTesting
        let generation = await agent.connectionGenerationForTesting
        await #expect(throws: WebRTCHostAgent.HostError.busy) {
            _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: false)
        }
        #expect(await pool.agent(for: Self.first) === agent)
        #expect(await agent.connectionGenerationForTesting == generation)
        _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: true)
        #expect(await agent.connectionGenerationForTesting == generation + 1)
        #expect(await otherAgent.state == .connected)
        #expect(await otherAgent.connectionGenerationForTesting == otherGeneration)
        await pool.closeAll()
    }

    @Test("An offer failure releases its reserved pool entry")
    func failedOfferReleasesCapacity() async throws {
        let failed = makeAgent()
        let replacement = makeAgent()
        await failed.failPeerConnectionAllocationForTesting()
        let fixtures = PoolAgentFixtures([failed, replacement])
        let pool = WebRTCHostAgentPool(maxConnections: 1, makeAgent: { await fixtures.next() })
        await #expect(throws: WebRTCHostAgent.HostError.peerConnectionInitFailed) {
            _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: false)
        }
        #expect(await pool.agent(for: Self.first) == nil)
        await replacement.failPeerConnectionAllocationForTesting()
        await #expect(throws: WebRTCHostAgent.HostError.peerConnectionInitFailed) {
            _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.second, replacingExistingConnection: false)
        }
        #expect(await fixtures.creationCount == 2)
    }

    @Test("@spec REMOTE-11.22: When different devices send concurrent first offers with one pool slot available, the host shall admit exactly one offer and count pending agent creation and negotiation toward capacity.", arguments: [false, true])
    func pendingWorkCountsTowardsLimit(duringNegotiation: Bool) async throws {
        let gate = PoolOfferGate()
        let agent = makeAgent()
        let pool = WebRTCHostAgentPool(maxConnections: 1, makeAgent: {
            if !duringNegotiation { await gate.wait() }
            return agent
        }, negotiate: { agent, offer, device, replacement in
            if duringNegotiation { await gate.wait() }
            return try await Self.negotiate(agent, offer, device, replacement)
        })
        let pending = Task { try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: false) }
        await gate.waitUntilArrived()
        await #expect(throws: WebRTCHostAgent.HostError.busy) {
            _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.second, replacingExistingConnection: false)
        }
        await gate.release()
        _ = try await pending.value
        #expect(await agent.state == .connected)
        await pool.closeAll()
    }

    @Test("A rejected competing offer cannot evict an in-flight connection")
    func busyDuringNegotiationPreservesEntry() async throws {
        let gate = PoolOfferGate()
        let agent = makeAgent()
        let pool = WebRTCHostAgentPool(makeAgent: { agent }, negotiate: { agent, _, device, replacement in
            _ = try await agent.prepareToAcceptOffer(clientDeviceID: device, replacingExistingConnection: replacement)
            await gate.wait()
            await agent.setStateForTesting(.connected)
            return RTCSessionDescription(type: .answer, sdp: "")
        })
        let pending = Task { try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: false) }
        await gate.waitUntilArrived()
        await #expect(throws: WebRTCHostAgent.HostError.busy) {
            _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: false)
        }
        #expect(await pool.agent(for: Self.first) === agent)
        await gate.release()
        _ = try await pending.value
        await pool.closeAll()
    }

    @Test("Closing during creation cannot leave a late connection alive")
    func closeAllDrainsPendingCreation() async throws {
        let gate = PoolOfferGate()
        let agent = makeAgent()
        let pool = WebRTCHostAgentPool(makeAgent: {
            await gate.wait()
            return agent
        }, negotiate: Self.negotiate)
        let pending = Task { try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: false) }
        await gate.waitUntilArrived()
        let closing = Task { await pool.closeAll() }
        // closeAll removes entries synchronously before waiting for creation.
        while await !pool.connectedDeviceIDs.isEmpty { await Task.yield() }
        await gate.release()
        await #expect(throws: WebRTCHostAgent.HostError.superseded) { _ = try await pending.value }
        await closing.value
        #expect(await agent.state == .closed)
    }

    @Test("A superseded first offer cannot discard its successful signed replacement")
    func failedFirstOfferPreservesReplacement() async throws {
        let gate = PoolOfferGate()
        let agent = makeAgent()
        let pool = WebRTCHostAgentPool(makeAgent: { agent }, negotiate: { agent, offer, device, replacement in
            if replacement { return try await Self.negotiate(agent, offer, device, true) }
            _ = try await agent.prepareToAcceptOffer(clientDeviceID: device, replacingExistingConnection: false)
            await gate.wait()
            throw WebRTCHostAgent.HostError.superseded
        })
        let pending = Task { try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: false) }
        await gate.waitUntilArrived()
        _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: true)
        await gate.release()
        await #expect(throws: WebRTCHostAgent.HostError.superseded) { _ = try await pending.value }
        #expect(await pool.agent(for: Self.first) === agent)
        #expect(await agent.state == .connected)
        await pool.closeAll()
    }

    @Test("Closing drains a suspended signed replacement before returning")
    func closeAllDrainsReplacement() async throws {
        let gate = PoolOfferGate()
        let agent = makeAgent()
        let pool = WebRTCHostAgentPool(makeAgent: { agent }, negotiate: { agent, offer, device, replacement in
            _ = try await agent.prepareToAcceptOffer(clientDeviceID: device, replacingExistingConnection: replacement)
            if replacement { await gate.wait() }
            // Model a replacement that resumes after asynchronous teardown.
            await agent.setStateForTesting(.connected)
            return RTCSessionDescription(type: .answer, sdp: "")
        })
        _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: false)
        let replacing = Task { try await pool.acceptOffer(Self.offer, clientDeviceID: Self.first, replacingExistingConnection: true) }
        await gate.waitUntilArrived()
        let closing = Task { await pool.closeAll() }
        while await !pool.connectedDeviceIDs.isEmpty { await Task.yield() }
        let alsoClosing = Task { await pool.closeAll() }
        await #expect(throws: WebRTCHostAgent.HostError.busy) {
            _ = try await pool.acceptOffer(Self.offer, clientDeviceID: Self.second, replacingExistingConnection: false)
        }
        await gate.release()
        await #expect(throws: WebRTCHostAgent.HostError.superseded) { _ = try await replacing.value }
        await closing.value
        await alsoClosing.value
        #expect(await agent.state == .closed)
        #expect(await pool.connectedDeviceIDs.isEmpty)
    }

    private static func negotiate(_ agent: WebRTCHostAgent, _ offer: RTCSessionDescription, _ device: RemoteDeviceID, _ replacement: Bool) async throws -> RTCSessionDescription {
        _ = try await agent.prepareToAcceptOffer(clientDeviceID: device, replacingExistingConnection: replacement)
        await agent.setStateForTesting(.connected)
        return RTCSessionDescription(type: .answer, sdp: "fixture")
    }

    private func makePool(_ fixtures: PoolAgentFixtures, maxConnections: Int = 8) -> WebRTCHostAgentPool {
        WebRTCHostAgentPool(maxConnections: maxConnections, makeAgent: { await fixtures.next() }, negotiate: Self.negotiate)
    }

    private func makeAgent() -> WebRTCHostAgent {
        WebRTCHostAgent(
            hostKey: Curve25519.Signing.PrivateKey(),
            trustedPeerStore: TrustedPeerStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            streamFactory: { _ in fatalError("No native WebRTC in pool tests") },
            panesStateSubscribe: { _ in .init(cancel: {}) },
            paneControlMutator: { _ in .ok },
            displayOwnershipStore: SessionDisplayOwnershipStore()
        )
    }
}

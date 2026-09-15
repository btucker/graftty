import Foundation
import GrafttyProtocol
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("Host-requested client reconnect")
@MainActor
struct RemoteClientReconnectTests {
    @Test(arguments: ["Laptop", "client-id"])
    func acknowledgesBeforeClosingSelectedClient(target: String) async throws {
        let router = RemoteTeamRouter()
        let events = ReconnectEvents()
        router.register(
            deviceID: RemoteDeviceID(value: "client-id"), connectionID: UUID(), label: "Laptop",
            closeForReconnect: { await events.append("close") }
        ) { data in
            #expect(try JSONDecoder().decode(RemoteTeamRequest.self, from: data) == .prepareReconnect)
            await events.append("ack")
            return try JSONEncoder().encode(RemoteTeamResponse.ok)
        }
        router.register(
            deviceID: RemoteDeviceID(value: "other"), connectionID: UUID(), label: "Other",
            closeForReconnect: { Issue.record("Closed the wrong viewer") }
        ) { _ in Issue.record("Contacted the wrong viewer"); return Data() }
        #expect(await router.reconnectClient(target: target) == .ok)
        #expect(await events.values == ["ack", "close"])
    }

    @Test func rejectsUnknownAmbiguousAndOutboundTargets() async {
        let router = RemoteTeamRouter()
        for id in ["one", "two"] {
            router.register(
                deviceID: RemoteDeviceID(value: id), connectionID: UUID(), label: "Laptop",
                closeForReconnect: { Issue.record("Closed an unresolved viewer") }
            ) { _ in Issue.record("Contacted an unresolved viewer"); return Data() }
        }
        router.register(deviceID: RemoteDeviceID(value: "host"), connectionID: UUID(), label: "Host") { _ in
            Issue.record("An outgoing connection is not a viewing client")
            return Data()
        }
        for target in ["missing", "Laptop", "host"] {
            guard case .error(let message) = await router.reconnectClient(target: target) else {
                Issue.record("Expected a targeting error"); continue
            }
            #expect(message.contains("one"))
            #expect(message.contains("two"))
        }
    }

    @Test(arguments: [false, true])
    func rejectedOrUnacknowledgedRequestDoesNotCloseClient(failsTransport: Bool) async throws {
        let router = RemoteTeamRouter()
        router.register(
            deviceID: RemoteDeviceID(value: "client"), connectionID: UUID(), label: "Laptop",
            closeForReconnect: { Issue.record("Closed without acknowledgement") }
        ) { _ in
            if failsTransport { throw URLError(.timedOut) }
            return try JSONEncoder().encode(RemoteTeamResponse.error("Unsupported request"))
        }
        guard case .error(let message) = await router.reconnectClient(target: "client") else {
            Issue.record("Expected an error"); return
        }
        #expect(message.contains(failsTransport ? "not acknowledged" : "Unsupported"))
    }

    @Test func replacementDuringRequestIsNotDisconnected() async throws {
        let router = RemoteTeamRouter()
        let device = RemoteDeviceID(value: "client")
        let oldID = UUID()
        router.register(
            deviceID: device, connectionID: oldID, label: "Laptop",
            closeForReconnect: { Issue.record("Closed an obsolete route") }
        ) { _ in
            await MainActor.run {
                router.unregister(deviceID: device, connectionID: oldID)
                router.register(
                    deviceID: device, connectionID: UUID(), label: "Laptop",
                    closeForReconnect: { Issue.record("Closed the replacement") }
                ) { _ in Data() }
            }
            return try JSONEncoder().encode(RemoteTeamResponse.ok)
        }
        guard case .error = await router.reconnectClient(target: "client") else {
            Issue.record("Expected a stale route error"); return
        }
    }
}

private actor ReconnectEvents {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

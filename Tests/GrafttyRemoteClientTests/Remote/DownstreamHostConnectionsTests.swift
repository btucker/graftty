import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyRemoteClient

@Suite("Downstream host connection controls")
@MainActor
struct DownstreamHostConnectionsTests {
    typealias Connections = DownstreamHostConnections<String>
    private let studio = Connections.Host(id: "studio", label: "Studio Mac")
    private let laptop = Connections.Host(id: "laptop", label: "Laptop")

    private func target(_ state: RemoteMacConnectionSummary.State = .offline, key: UInt8 = 1) throws -> RemoteMacConnectionSummary {
        .init(deviceID: .init(value: "worker"),
              fingerprint: try .init(rawBytes: Data(repeating: key, count: 32)),
              label: "Worker", lastKnownHost: "worker.local", state: state)
    }

    @Test("@spec REMOTE-13.49: While the Mac or mobile host manager is open, the application shall list each downstream host with its intermediary Mac and preserve separate routes to the same destination.")
    func alternateRoutesRemainVisible() async throws {
        let connections = Connections()
        let offline = try target()
        let live = try target(.connected)
        await connections.refresh(hosts: [studio, laptop]) { host, request in
            #expect(request == .listRemoteMacConnections)
            return .remoteMacConnections([host == "studio" ? offline : live])
        }
        #expect(connections.routes.map(\.host.label) == ["Studio Mac", "Laptop"])
        #expect(connections.routes.map(\.target.state) == [.offline, .connected])
        #expect(Set(connections.routes.map(\.id)).count == 2)
        await connections.refresh(hosts: [laptop]) { _, _ in .remoteMacConnections([live]) }
        #expect(connections.routes.map(\.host.id) == ["laptop"])
    }

    @Test("@spec REMOTE-13.50: When a user connects a downstream host from Mac or mobile, the application shall send its device ID and fingerprint through the selected intermediary, prevent duplicate pending requests on that route, and display rejected or unavailable replies.")
    func connectionUsesSelectedRouteAndReportsErrors() async throws {
        let connections = Connections()
        let target = try target()
        await connections.refresh(hosts: [studio, laptop]) { _, _ in .remoteMacConnections([target]) }
        let route = try #require(connections.routes.last)
        var requests = 0
        await connections.connect(route) { host, request in
            requests += 1
            #expect(host == "laptop")
            #expect(request == .connectRemoteMac(deviceID: target.deviceID, fingerprint: target.fingerprint))
            #expect(connections.connecting.contains(route.id))
            await connections.connect(route) { _, _ in Issue.record("Duplicate connect"); return .ok }
            return .error(code: "pairing-required", message: "Pair Worker again on Laptop.", forceAllowed: false, shortStatus: nil)
        }
        #expect(requests == 1)
        #expect(connections.connecting.isEmpty)
        #expect(connections.error?.contains("Pair Worker again on Laptop.") == true)
        await connections.connect(route) { _, _ in throw URLError(.notConnectedToInternet) }
        #expect(connections.error?.contains("Worker via Laptop") == true)
        await connections.connect(route) { _, _ in .ok }
        #expect(connections.error == nil)
        // Acceptance is asynchronous. Only a fresh host report proves connection.
        #expect(connections.routes.last?.target.state == .offline)
    }

    @Test("Downstream controls reject expired routes and changed fingerprints")
    func staleRouteCannotConnect() async throws {
        let connections = Connections()
        let old = try target()
        let replacement = try target(key: 2)
        await connections.refresh(hosts: [studio]) { _, _ in .remoteMacConnections([old]) }
        let route = try #require(connections.routes.first)
        await connections.refresh(hosts: [studio]) { _, _ in .remoteMacConnections([replacement]) }
        await connections.connect(route) { _, _ in Issue.record("Expired route was used"); return .ok }
        #expect(connections.error != nil)
        await connections.refresh(hosts: []) { _, _ in Issue.record("No hosts to poll"); return .ok }
        #expect(connections.routes.isEmpty)
    }

    @Test("Background polling does not publish cancelled or superseded snapshots")
    func oldPollCannotReplaceNewRoutes() async throws {
        let connections = Connections()
        let target = try target()
        await connections.refresh(hosts: [studio]) { _, _ in
            await connections.refresh(hosts: [laptop]) { _, _ in .remoteMacConnections([target]) }
            return .remoteMacConnections([target])
        }
        #expect(connections.routes.map(\.host.id) == ["laptop"])
    }

    @Test("@spec REMOTE-13.53: When an intermediary disconnects after reporting downstream hosts, the application shall retain its known routes for an explicit reconnect, keep background polling quiet, and remove the routes when that intermediary is forgotten.")
    func disconnectedIntermediaryKeepsDemandRoutes() async throws {
        let connections = Connections()
        let target = try target(.connecting)
        await connections.refresh(hosts: [studio]) { _, _ in .remoteMacConnections([target]) }
        let offline = Connections.Host(id: studio.id, label: studio.label, isConnected: false)
        await connections.refresh(hosts: [offline]) { _, _ in Issue.record("Polling woke an offline intermediary"); return .ok }
        let route = try #require(connections.routes.first)
        #expect(!route.host.isConnected)
        var sent = false
        await connections.connect(route) { host, _ in sent = true; #expect(host == studio.id); return .ok }
        #expect(sent)
        await connections.refresh(hosts: []) { _, _ in Issue.record("Forgotten host was polled"); return .ok }
        #expect(connections.routes.isEmpty)
    }

    @Test("A failed quiet poll retains routes for on-demand recovery until an authoritative empty list")
    func failedPollDoesNotEraseKnownRoute() async throws {
        let connections = Connections()
        let target = try target()
        await connections.refresh(hosts: [studio]) { _, _ in .remoteMacConnections([target]) }
        await connections.refresh(hosts: [studio]) { _, _ in throw URLError(.networkConnectionLost) }
        #expect(connections.routes.count == 1)
        #expect(connections.routes.first?.host.isConnected == false)
        let offline = Connections.Host(id: studio.id, label: studio.label, isConnected: false)
        await connections.refresh(hosts: [offline]) { _, _ in Issue.record("Offline poll"); return .ok }
        #expect(connections.routes.count == 1)
        await connections.refresh(hosts: [studio]) { _, _ in .remoteMacConnections([]) }
        #expect(connections.routes.isEmpty)
    }
}

import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@MainActor struct MCPConnectionSupervisorTests {
    @Test("@spec REMOTE-30.19: When the local CLI starts, stops, or lists parent MCP connections, the application shall exchange saved connection intent and sanitized lifecycle status over the control socket.")
    func controlRequestsRoundTrip() throws {
        let configuration = MCPConnectionConfiguration(provider: "aws", operationID: UUID(), policyPath: "/private/policy.json")
        for request in [MCPConnectionRequest.start(configuration), .stop(provider: "aws", operationID: configuration.operationID), .list] {
            let message = NotificationMessage.mcpConnection(request)
            #expect(try JSONDecoder().decode(NotificationMessage.self, from: JSONEncoder().encode(message)) == message)
        }
        let response = ResponseMessage.mcpConnections([.init(configuration: configuration, state: .retrying)])
        #expect(try JSONDecoder().decode(ResponseMessage.self, from: JSONEncoder().encode(response)) == response)
    }

    @Test("@spec REMOTE-30.17: When the parent owns an MCP connection, the application shall persist its provider binding and policy path, reuse an identical start, reconnect with fresh sessions after transport loss, and stop reconnecting after explicit removal or shutdown.")
    func ownsPersistentConnectionAndReconnects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let attempts = ConnectionAttempts()
        let configuration = MCPConnectionConfiguration(provider: "fixture", operationID: UUID(), policyPath: "/private/policy.json")
        let service = MCPConnectionSupervisor(directory: root, retryDelay: .milliseconds(5)) { _, ready in
            let count = await attempts.start()
            await ready()
            if count == 1 { throw MCPConnectionFailure.unavailable }
            do { try await Task.sleep(for: .seconds(30)) }
            catch { await attempts.closed(); throw error }
        }
        try service.start(configuration)
        try service.start(configuration)
        try await eventually { await attempts.count == 2 && service.statuses.first?.state == .connected }
        #expect(service.statuses.count == 1)
        await service.shutdown()
        #expect(await attempts.closes == 1)
        let restored = MCPConnectionSupervisor(directory: root, retryDelay: .milliseconds(5)) { _, ready in
            _ = await attempts.start(); await ready()
            try await Task.sleep(for: .seconds(30))
        }
        try restored.restore()
        try await eventually { restored.statuses.first?.state == .connected }
        try await restored.remove(provider: configuration.provider, operationID: configuration.operationID)
        #expect(restored.statuses.isEmpty)
        let empty = MCPConnectionSupervisor(directory: root) { _, _ in Issue.record("Removed connection restarted") }
        try empty.restore()
        #expect(empty.statuses.isEmpty)
        await empty.shutdown()
    }

    @Test("@spec REMOTE-30.18: If an app-owned MCP connection fails local enrollment, parent identity, or policy-file validation, then the application shall retain a sanitized blocked status without retrying, and shall reject conflicting configuration until the saved connection is removed.")
    func authorizationFailureDoesNotRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let attempts = ConnectionAttempts()
        let configuration = MCPConnectionConfiguration(provider: "fixture", operationID: UUID(), policyPath: "/private/policy.json")
        let service = MCPConnectionSupervisor(directory: root, retryDelay: .milliseconds(5)) { _, _ in
            _ = await attempts.start(); throw MCPConnectionFailure.authorization
        }
        try service.start(configuration)
        try await eventually { service.statuses.first?.state == .blocked }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await attempts.count == 1)
        var changed = configuration; changed.policyPath = "/other.json"
        #expect(throws: (any Error).self) { try service.start(changed) }
        try service.start(configuration)
        #expect(await attempts.count == 1)
        try await service.remove(provider: configuration.provider, operationID: configuration.operationID)
        await service.shutdown()
    }

    @Test func stopAcknowledgesBeforeSlowTransportCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = MCPConnectionConfiguration(provider: "fixture", operationID: UUID(), policyPath: "/private/policy.json")
        let service = MCPConnectionSupervisor(directory: root) { _, ready in
            await ready()
            do { try await Task.sleep(for: .seconds(30)) }
            catch {
                // Cleanup outlives cancellation, as with SSH/proxy teardown.
                await Task.detached { try? await Task.sleep(for: .milliseconds(200)) }.value
                throw error
            }
        }
        try service.start(configuration)
        try await eventually { service.statuses.first?.state == .connected }
        let response = await service.handle(.stop(provider: configuration.provider, operationID: configuration.operationID))
        guard case .mcpConnections(let statuses) = response else { Issue.record("Missing stop acknowledgement"); return }
        #expect(statuses.first?.state == .stopping)
        #expect(throws: (any Error).self) { try service.start(configuration) }
        await service.shutdown()
        let empty = MCPConnectionSupervisor(directory: root) { _, _ in Issue.record("Stopped connection restored") }
        try empty.restore()
        #expect(empty.statuses.isEmpty)
        await empty.shutdown()
    }

    @Test func releasingOwnerCancelsItsRunner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let attempts = ConnectionAttempts()
        var service: MCPConnectionSupervisor? = MCPConnectionSupervisor(directory: root) { _, ready in
            await ready()
            do { try await Task.sleep(for: .seconds(30)) }
            catch { await attempts.closed(); throw error }
        }
        weak let owner = service
        try service?.start(.init(provider: "fixture", operationID: UUID(), policyPath: "/policy.json"))
        try await eventually { service?.statuses.first?.state == .connected }
        service = nil
        #expect(owner == nil)
        try await eventually { await attempts.closes == 1 }
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await condition())
    }
}

private actor ConnectionAttempts {
    var count = 0
    var closes = 0
    func start() -> Int { count += 1; return count }
    func closed() { closes += 1 }
}

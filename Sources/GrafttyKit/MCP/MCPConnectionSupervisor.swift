import Foundation
import GrafttyProtocol

/// @spec REMOTE-30.17
/// When the parent owns an MCP connection, the application shall persist its provider binding and policy path, reuse an identical start, reconnect with fresh sessions after transport loss, and stop reconnecting after explicit removal or shutdown.
public struct MCPConnectionConfiguration: Codable, Equatable, Sendable {
    public var provider: String
    public var operationID: UUID
    public var policyPath: String
    public init(provider: String, operationID: UUID, policyPath: String) {
        self.provider = provider; self.operationID = operationID; self.policyPath = policyPath
    }
    var key: String { provider + ":" + operationID.uuidString }
    func validate() throws {
        guard provider.range(of: "^[a-z][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
              policyPath.hasPrefix("/"), policyPath.utf8.count <= 4096,
              !policyPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ProviderError("Expected a provider name, enrollment UUID and absolute parent policy path")
        }
    }
}

public enum MCPConnectionRequest: Codable, Equatable, Sendable {
    case start(MCPConnectionConfiguration)
    case stop(provider: String, operationID: UUID)
    case list
}

public enum MCPConnectionFailure: Error { case authorization, unavailable }
public struct MCPConnectionStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case connecting, connected, retrying, blocked, stopping }
    public let configuration: MCPConnectionConfiguration
    public var state: State
}

/// Owns one task per saved provider enrollment. Runners must close their entire
/// transport and upstream sessions before returning, including on cancellation.
@MainActor public final class MCPConnectionSupervisor {
    public typealias Runner = @Sendable (MCPConnectionConfiguration, @escaping @Sendable () async -> Void) async throws -> Void
    private struct Saved: Codable { var version = 1; var connections: [MCPConnectionConfiguration] }
    private struct Entry: Sendable {
        let id: UUID
        var status: MCPConnectionStatus
        var readyAt: ContinuousClock.Instant?
        var attempt: UUID?
        let task: Task<Void, Never>
    }
    private let store: JSONFileStore<Saved>
    private let runner: Runner
    private let retryDelay: Duration
    private var saved: [MCPConnectionConfiguration] = []
    private var entries: [String: Entry] = [:]
    private var restored = false
    private var shuttingDown = false
    public var statuses: [MCPConnectionStatus] { entries.values.map(\.status).sorted { $0.configuration.key < $1.configuration.key } }

    public init(directory: URL, retryDelay: Duration = .seconds(1), runner: @escaping Runner) {
        store = .init(fileURL: directory.appendingPathComponent("mcp-connections.json"), posixPermissions: 0o600)
        self.runner = runner; self.retryDelay = retryDelay
    }
    deinit { for entry in entries.values { entry.task.cancel() } }

    public func restore() throws {
        guard !restored, !shuttingDown else { return }
        let value = try store.load() ?? Saved(connections: [])
        guard value.version == 1, value.connections.count <= 32,
              Set(value.connections.map(\.key)).count == value.connections.count else { throw ProviderError("Invalid saved MCP connections") }
        try value.connections.forEach { try $0.validate() }
        saved = value.connections; restored = true
        for configuration in saved { launch(configuration) }
    }
    public func start(_ configuration: MCPConnectionConfiguration) throws {
        guard !shuttingDown else { throw ProviderError("Parent MCP service is stopping") }
        try configuration.validate(); try restore()
        if let entry = entries[configuration.key] {
            guard entry.status.configuration == configuration, entry.status.state != .stopping else {
                throw ProviderError("Remove the existing MCP connection before changing it")
            }
            return
        }
        guard saved.count < 32 else { throw ProviderError("At most 32 parent MCP connections can be saved") }
        let next = saved + [configuration]
        try store.save(Saved(connections: next)); saved = next
        launch(configuration)
    }
    public func remove(provider: String, operationID: UUID) async throws {
        let cleanup = try requestRemoval(provider: provider, operationID: operationID)
        await cleanup?.value
    }
    private func requestRemoval(provider: String, operationID: UUID) throws -> Task<Void, Never>? {
        try restore()
        let key = provider + ":" + operationID.uuidString
        let next = saved.filter { $0.key != key }
        try store.save(Saved(connections: next)); saved = next
        guard var entry = entries[key] else { return nil }
        entry.status.state = .stopping; entries[key] = entry
        entry.task.cancel()
        return Task { [weak self] in
            await entry.task.value
            if self?.entries[key]?.id == entry.id { self?.entries[key] = nil }
        }
    }
    public func handle(_ request: MCPConnectionRequest) async -> ResponseMessage {
        do {
            switch request {
            case .start(let configuration): try start(configuration)
            case .stop(let provider, let operationID): _ = try requestRemoval(provider: provider, operationID: operationID)
            case .list: try restore()
            }
            return .mcpConnections(statuses)
        } catch {
            return .error("Parent MCP connection could not be updated. Check saved configuration; stop an existing connection before changing it.")
        }
    }

    /// Leaves saved intent for the next app launch, but prevents further starts.
    public func cancel() {
        shuttingDown = true
        for key in Array(entries.keys) {
            entries[key]?.status.state = .stopping
            entries[key]?.task.cancel()
        }
    }
    public func shutdown() async {
        cancel()
        for entry in Array(entries.values) { await entry.task.value }
        entries = [:]
    }
    private func ready(key: String, id: UUID, attempt: UUID) {
        guard entries[key]?.id == id, entries[key]?.attempt == attempt, entries[key]?.task.isCancelled == false else { return }
        entries[key]?.status.state = .connected; entries[key]?.readyAt = .now
    }
    private func launch(_ configuration: MCPConnectionConfiguration) {
        let id = UUID(), key = configuration.key
        let run = runner, delay = retryDelay
        let task = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                let attempt = UUID()
                self?.entries[key]?.attempt = attempt
                self?.entries[key]?.status.state = .connecting
                do {
                    try await run(configuration) { [weak self] in await self?.ready(key: key, id: id, attempt: attempt) }
                } catch MCPConnectionFailure.authorization {
                    self?.entries[key]?.attempt = nil
                    if !Task.isCancelled { self?.entries[key]?.status.state = .blocked }
                    return
                } catch { }
                self?.entries[key]?.attempt = nil
                guard !Task.isCancelled else { return }
                if let ready = self?.entries[key]?.readyAt, ready.duration(to: .now) >= .seconds(30) { failures = 0 }
                self?.entries[key]?.readyAt = nil
                self?.entries[key]?.status.state = .retrying
                let backoff = min(delay * (1 << min(failures, 5)), .seconds(30))
                failures += 1
                do { try await Task.sleep(for: backoff) } catch { return }
            }
        }
        entries[key] = .init(id: id, status: .init(configuration: configuration, state: .connecting), task: task)
    }
}

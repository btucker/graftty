import Foundation
import GrafttyProtocol
import MCP

public enum MCPStdioBridge {
    public typealias Sender = @Sendable (MCPProxyRequest) async throws -> MCPProxyResponse
    /// One native MCP process/session. No logs or progress go to stdout.
    public static func run(scope: MCPProxyScope, transport: any Transport = StdioTransport(), send: @escaping Sender) async throws {
        let id = UUID()
        guard try await send(.open(sessionID: id, scope: scope)) == .opened else { throw MCPProxyError.unavailable }
        do {
            try await transport.connect()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await bytes in await transport.receive() {
                        try Task.checkCancellation()
                        guard MCPProxyBroker.validMessage(bytes) else { throw MCPProxyError.invalidRequest }
                        guard try await send(.send(sessionID: id, message: bytes)) == .accepted else { throw MCPProxyError.outcomeUnknown }
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        let result = try await send(.receive(sessionID: id))
                        guard case .messages(let messages) = result else { throw MCPProxyError.outcomeUnknown }
                        for bytes in messages { try await transport.send(bytes) }
                        if messages.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
                    }
                }
                do { _ = try await group.next() }
                catch { group.cancelAll(); await transport.disconnect(); throw error }
                group.cancelAll()
                await transport.disconnect()
            }
        } catch {
            await transport.disconnect()
            _ = try? await send(.close(sessionID: id))
            throw error
        }
        _ = try? await send(.close(sessionID: id))
    }
}

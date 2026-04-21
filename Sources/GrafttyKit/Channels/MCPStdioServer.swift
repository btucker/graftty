import Foundation

/// Minimal hand-rolled MCP JSON-RPC 2.0 server for the channels capability.
/// - Reads newline-delimited JSON requests/notifications via `handleLine`.
/// - Emits newline-delimited JSON responses and notifications via `output`.
///
/// Intentionally narrow: we only support `initialize` + `notifications/claude/channel`.
/// Unknown methods return error code -32601 ("Method not found"); malformed
/// input is dropped silently (no id to respond to).
public final class MCPStdioServer {
    private let name: String
    private let version: String
    private let instructions: String
    private let output: (Data) -> Void

    public init(name: String, version: String, instructions: String, output: @escaping (Data) -> Void) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.output = output
    }

    /// Process one line from stdin (or a test harness). Returns nothing —
    /// any response is written via the `output` closure.
    public func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["method"] as? String else {
            // Malformed input — drop silently.
            return
        }
        let id = obj["id"]
        switch method {
        case "initialize":
            respondToInitialize(id: id)
        case "notifications/initialized", "notifications/cancelled":
            break  // no-op
        default:
            if id != nil {
                respondWithMethodNotFound(id: id, method: method)
            }
        }
    }

    /// Emit a `notifications/claude/channel` event with the given body and
    /// meta attributes.
    public func emitChannelNotification(content: String, meta: [String: String]) {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/claude/channel",
            "params": [
                "content": content,
                "meta": meta,
            ] as [String: Any],
        ]
        writeJSON(payload)
    }

    // MARK: private

    private func respondToInitialize(id: Any?) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "experimental": [
                        "claude/channel": [:] as [String: Any],
                    ],
                ],
                "serverInfo": [
                    "name": name,
                    "version": version,
                ],
                "instructions": instructions,
            ] as [String: Any],
        ]
        writeJSON(response)
    }

    private func respondWithMethodNotFound(id: Any?, method: String) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": -32601,
                "message": "Method not found: \(method)",
            ] as [String: Any],
        ]
        writeJSON(response)
    }

    private func writeJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        var out = data
        out.append(0x0A)
        output(out)
    }
}

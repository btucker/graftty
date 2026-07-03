import Foundation

public enum FlowCLIOutput {
    public static func recommendationJSON(_ envelope: FlowRecommendationEnvelope) throws -> String {
        try flowJSONString(envelope)
    }

    public static func contextJSON(_ envelope: FlowContextEnvelope) throws -> String {
        try flowJSONString(envelope)
    }

    public static func statusLine(_ status: FlowStatus) -> String {
        var parts = [
            "enabled=\(status.enabled)",
            "running=\(status.running)",
            "promptMode=\(status.promptMode.rawValue)",
        ]
        if let message = status.message, !message.isEmpty {
            parts.append("message=\(message)")
        }
        return parts.joined(separator: " ")
    }

    private static func flowJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder.flowState.encode(value)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

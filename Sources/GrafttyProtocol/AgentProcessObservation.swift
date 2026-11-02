/// Provider observation is independent of assignment completion and viewer transport.
public enum AgentProcessObservation: String, Codable, Sendable, Hashable {
    case reachable, disconnected, exited
}

public enum AgentTextPreview {
    /// Stop at a Unicode scalar boundary and keep the UTF-8 payload within budget.
    public static func prefix(_ text: String, bytes: Int) -> String {
        var result = String.UnicodeScalarView()
        var remaining = max(0, bytes)
        for scalar in text.unicodeScalars {
            let size = scalar.utf8.count
            guard size <= remaining else { break }
            result.append(scalar)
            remaining -= size
        }
        return String(result)
    }
}

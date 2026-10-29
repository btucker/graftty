import Foundation

/// Provider user roles carry both human input and injected context. Classify
/// the delivery envelopes before displaying saved prompts as human messages.
public enum WorktreePromptContent {
    public struct Part: Equatable, Sendable {
        public enum Source: Codable, Hashable, Sendable { case user, agent(String?), generated }
        public let source: Source
        public let text: String

        public init(source: Source, text: String) { self.source = source; self.text = text }
    }

    public static func parts(in text: String) -> [Part] {
        parse(text, source: .user)
    }

    /// Retain mixed input without letting generated context consume its budget.
    /// Keep peer frames so restored inputs can still recover their provenance.
    static func retainedText(from parts: [Part]) -> String {
        parts.map { part in
            switch part.source {
            case .user: return part.text
            case .agent(let sender):
                let attribute = sender.map { " agent=\"\(escapeAttribute($0))\"" } ?? ""
                return "<graftty-peer-message\(attribute) graftty-history-encoding=\"xml-v1\">\n\(escapeAttribute(part.text))\n</graftty-peer-message>"
            case .generated: return ""
            }
        }.joined(separator: "\n\n")
    }

    private static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let opening = try! NSRegularExpression(
        pattern: #"^[\t ]*<(graftty-peer-message|graftty-system-message|graftty-forge-message|cross-session-message|system-reminder|environment_context|task-notification)(?=[\s>])[^>]*>"#)

    private static func parse(_ text: String, source: Part.Source) -> [Part] {
        var result: [Part] = []
        var plain = ""
        var cursor = text.startIndex
        var fence: String?
        func flush() {
            let value = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append(Part(source: source, text: value)) }
            plain = ""
        }
        while cursor < text.endIndex {
            let lineEnd = text[cursor...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            let line = String(text[cursor..<lineEnd])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                plain += line
                cursor = lineEnd
                continue
            }
            if fence == nil {
                if trimmed == "Another Claude session sent a message:",
                   text[lineEnd...].drop(while: { $0.isWhitespace }).hasPrefix("<cross-session-message") {
                    cursor = lineEnd
                    continue
                }
                if let match = opening.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let headerRange = Range(match.range, in: line),
                   let nameRange = Range(match.range(at: 1), in: line) {
                    flush()
                    let name = String(line[nameRange])
                    let header = String(line[headerRange])
                    let bodyStart = text.index(cursor,
                        offsetBy: line.distance(from: line.startIndex, to: headerRange.upperBound))
                    let close = text.range(of: "</\(name)>", range: bodyStart..<text.endIndex)
                    // A bounded durable input can end inside a generated frame.
                    // Its opening envelope still establishes non-human provenance.
                    let body = String(text[bodyStart..<(close?.lowerBound ?? text.endIndex)])
                    switch name {
                    case "graftty-peer-message":
                        let decoded = attribute("graftty-history-encoding", in: header) == "xml-v1" ? unescape(body) : body
                        let content = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !content.isEmpty { result.append(Part(source: .agent(attribute("agent", in: header)), text: content)) }
                    case "cross-session-message":
                        result += parse(body, source: .agent(attribute("from-name", in: header) ?? attribute("from", in: header)))
                    default: break // Generated system, forge, and hook context.
                    }
                    cursor = close?.upperBound ?? text.endIndex
                    continue
                }
            }
            plain += line
            cursor = lineEnd
        }
        flush()
        return result
    }

    private static func attribute(_ name: String, in header: String) -> String? {
        let pattern = "(?:^|\\s)" + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else { return nil }
        let value = unescape(String(header[range]))
        return value.isEmpty ? nil : value
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

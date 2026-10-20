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

    private static let opening = try! NSRegularExpression(
        pattern: #"^[\t ]*<(graftty-peer-message|graftty-system-message|graftty-forge-message|cross-session-message|system-reminder|environment_context)(?=[\s>])[^>]*>"#)

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
                   text[lineEnd...].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<cross-session-message") {
                    cursor = lineEnd
                    continue
                }
                let remainder = String(text[cursor...])
                if let match = opening.firstMatch(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)),
                   let headerRange = Range(match.range, in: remainder),
                   let nameRange = Range(match.range(at: 1), in: remainder) {
                    flush()
                    let name = String(remainder[nameRange])
                    let header = String(remainder[headerRange])
                    let bodyStart = headerRange.upperBound
                    let close = remainder.range(of: "</\(name)>", range: bodyStart..<remainder.endIndex)
                    // A bounded durable input can end inside a generated frame.
                    // Its opening envelope still establishes non-human provenance.
                    let body = String(remainder[bodyStart..<(close?.lowerBound ?? remainder.endIndex)])
                    switch name {
                    case "graftty-peer-message":
                        let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !content.isEmpty { result.append(Part(source: .agent(attribute("agent", in: header)), text: content)) }
                    case "cross-session-message":
                        result += parse(body, source: .agent(attribute("from-name", in: header) ?? attribute("from", in: header)))
                    default: break // Generated system, forge, and hook context.
                    }
                    let consumed = remainder.distance(from: remainder.startIndex, to: close?.upperBound ?? remainder.endIndex)
                    cursor = text.index(cursor, offsetBy: consumed)
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
        let value = String(header[range])
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return value.isEmpty ? nil : value
    }
}

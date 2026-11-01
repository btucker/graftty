import Foundation

/// Provider user roles carry both human input and injected context. Classify
/// the delivery envelopes before displaying saved prompts as human messages.
public enum WorktreePromptContent {
    public struct Part: Codable, Hashable, Sendable {
        public enum Source: Codable, Hashable, Sendable { case user, agent(String?), generated }
        public let source: Source
        public let text: String
        public let presentation: HarnessTimelinePresentation?
        public let wasTruncated: Bool?
        /// Keep the existing source encoding readable by older paired clients.
        /// Generated context with presentation is a visible session notice.
        var isHidden: Bool { source == .generated && presentation == nil }

        public init(source: Source, text: String, presentation: HarnessTimelinePresentation? = nil, wasTruncated: Bool? = nil) {
            self.source = source; self.text = text; self.presentation = presentation; self.wasTruncated = wasTruncated
        }
    }

    public static func parts(in text: String, runtime: String? = nil,
                             plugins: [any HarnessTimelinePlugin]? = nil) -> [Part] {
        let selected = HarnessTimelinePlugins.matching(runtime, in: plugins ?? HarnessTimelinePlugins.builtins)
        let opening = plugins == nil ? (builtinOpenings[runtime ?? ""] ?? sharedOpening) : opening(for: selected)
        return parse(text, source: .user, plugins: selected, opening: opening)
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

    private static let sharedEnvelopes: Set<String> = [
        "graftty-peer-message", "graftty-peer-messages", "graftty-system-message", "graftty-forge-message"
    ]
    private static func opening(for plugins: [any HarnessTimelinePlugin]) -> NSRegularExpression {
        let names = sharedEnvelopes.union(plugins.flatMap(\.envelopeNames)).sorted()
        return try! NSRegularExpression(pattern: #"^[\t ]*<("#
            + names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")(?=[\s>])[^>]*>"#)
    }
    private static let sharedOpening = opening(for: [])
    private static let builtinOpenings: [String: NSRegularExpression] = {
        let plugins = HarnessTimelinePlugins.builtins
        var result = ["": opening(for: plugins)]
        for plugin in plugins { result[plugin.runtime] = opening(for: [plugin]) }
        return result
    }()
    private static let inlineCode = try! NSRegularExpression(
        pattern: #"(?<!`)(`+)(?!`)[^\n]*?(?<!`)\1(?!`)"#)

    private struct Fence {
        private var marker: Character?
        private var length = 0

        /// Consume the delimiter lines and all content inside a Markdown fence.
        mutating func consume(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let marker {
                let run = trimmed.prefix(while: { $0 == marker })
                if run.count >= length, trimmed.dropFirst(run.count).isEmpty { self.marker = nil }
                return true
            }
            guard let first = trimmed.first, first == "`" || first == "~" else { return false }
            let count = trimmed.prefix(while: { $0 == first }).count
            guard count >= 3 else { return false }
            marker = first
            length = count
            return true
        }
    }

    private static func closingTag(_ name: String, in text: String, from start: String.Index,
                                   respectingFences: Bool = true) -> Range<String.Index>? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let tags = try! NSRegularExpression(pattern: "<\(escaped)(?=[\\s>])[^>]*>|</\(escaped)>")
        var cursor = start
        var depth = 0
        var fence = Fence()
        while cursor < text.endIndex {
            let lineEnd = text[cursor...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            if !respectingFences || !fence.consume(String(text[cursor..<lineEnd])) {
                var openingBoundary = cursor
                let lineRange = NSRange(cursor..<lineEnd, in: text)
                let code = inlineCode.matches(in: text, range: lineRange)
                for match in tags.matches(in: text, range: lineRange) {
                    if code.contains(where: { NSLocationInRange(match.range.location, $0.range) }) { continue }
                    guard let range = Range(match.range, in: text) else { continue }
                    if text[range].hasPrefix("</") {
                        if depth == 0 { return range }
                        depth -= 1
                        openingBoundary = range.upperBound
                    } else if text[openingBoundary..<range.lowerBound].allSatisfy(\.isWhitespace) {
                        // Match the parser's line-start rule, including adjacent
                        // envelopes after a nested close. Inline mentions stay literal.
                        depth += 1
                    }
                }
            }
            cursor = lineEnd
        }
        // If Markdown crosses the delivery boundary, recover the balanced
        // envelope close so the following human input retains its provenance.
        return respectingFences
            ? closingTag(name, in: text, from: start, respectingFences: false) : nil
    }

    private static func parse(_ text: String, source: Part.Source, plugins: [any HarnessTimelinePlugin],
                              opening: NSRegularExpression) -> [Part] {
        var suppressesGeneratedPreamble = false
        if source == .user,
           let part = plugins.lazy.compactMap({ $0.parseText(text.trimmingCharacters(in: .whitespacesAndNewlines)) }).first {
            if !part.isHidden { return [part] }
            suppressesGeneratedPreamble = true
        }
        var result: [Part] = []
        var plain = ""
        var cursor = text.startIndex
        var fence = Fence()
        func flush() {
            let value = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !suppressesGeneratedPreamble {
                if source == .user, let part = plugins.lazy.compactMap({ $0.parseText(value) }).first {
                    if !part.isHidden { result.append(part) }
                } else {
                    result.append(Part(source: source, text: value))
                }
            }
            plain = ""
        }
        while cursor < text.endIndex {
            let lineEnd = text[cursor...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            let line = String(text[cursor..<lineEnd])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fence.consume(line) {
                if plugins.contains(where: { $0.skipsLine(trimmed, following: text[lineEnd...]) }) {
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
                    let plugin = plugins.first(where: { $0.envelopeNames.contains(name) })
                    let close = plugin?.usesJSONBody(named: name) == true
                        ? jsonClosingTag(name, in: text, from: bodyStart) : closingTag(name, in: text, from: bodyStart)
                    // A bounded durable input can end inside a generated frame.
                    // Its opening envelope still establishes non-human provenance.
                    let body = String(text[bodyStart..<(close?.lowerBound ?? text.endIndex)])
                    switch name {
                    case "graftty-peer-message":
                        suppressesGeneratedPreamble = false
                        let decoded = attribute("graftty-history-encoding", in: header) == "xml-v1" ? unescape(body) : body
                        let content = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !content.isEmpty { result.append(Part(source: .agent(attribute("agent", in: header)), text: content)) }
                    case "graftty-peer-messages":
                        suppressesGeneratedPreamble = false
                        result += legacyPeerMessages(body)
                    case "graftty-system-message", "graftty-forge-message": break
                    default:
                        let part = plugin?.parseEnvelope(name: name, header: header, body: body)
                        let unwraps = plugin?.unwrapsNestedEnvelopes(named: name) == true
                        if part?.isHidden == true { break }
                        suppressesGeneratedPreamble = false
                        if let part, close != nil || (unwraps && Self.isAgent(part.source)) {
                            // A nested user-shaped envelope cannot change a peer's authorship.
                            if unwraps {
                                result += parse(part.text, source: part.source, plugins: plugins, opening: opening)
                            } else {
                                result.append(source == .user ? part : .init(source: source, text: part.text))
                            }
                        } else {
                            let end = close?.upperBound ?? text.endIndex
                            let raw = String(text[cursor..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                            result.append(.init(source: source, text: raw))
                        }
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

    private static func jsonClosingTag(_ name: String, in text: String, from start: String.Index) -> Range<String.Index>? {
        let closing = "</\(name)>"
        let scalars = text.unicodeScalars
        var quoted = false
        var escaped = false
        var cursor = start
        while cursor < text.endIndex {
            let character = scalars[cursor]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if scalars[cursor...].starts(with: closing.unicodeScalars) {
                return cursor..<scalars.index(cursor, offsetBy: closing.unicodeScalars.count)
            }
            cursor = scalars.index(after: cursor)
        }
        // An unterminated JSON string must not absorb later delivery frames.
        return closingTag(name, in: text, from: start)
    }

    private static func isAgent(_ source: Part.Source) -> Bool {
        if case .agent = source { return true }
        return false
    }

    private static func legacyPeerMessages(_ body: String) -> [Part] {
        let headings = legacyPeerHeading.matches(in: body, range: NSRange(body.startIndex..., in: body))
        guard !headings.isEmpty else {
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.init(source: .agent(nil), text: text)]
        }
        return headings.enumerated().compactMap { index, match in
            guard let heading = Range(match.range, in: body), let sender = Range(match.range(at: 1), in: body) else { return nil }
            let end = index + 1 < headings.count ? Range(headings[index + 1].range, in: body)!.lowerBound : body.endIndex
            let text = body[heading.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .init(source: .agent(String(body[sender])), text: text)
        }
    }

    private static let legacyPeerHeading = try! NSRegularExpression(pattern: #"(?m)^Worktree message from `([^`]+)`:[\t ]*\n"#)

    static func attribute(_ name: String, in header: String) -> String? {
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

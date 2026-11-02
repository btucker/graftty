import Foundation

/// Harness syntax belongs in plugins. Native clients consume only this shared content.
public protocol HarnessTimelinePlugin: Sendable {
    var runtime: String { get }
    var envelopeNames: Set<String> { get }
    /// nil preserves an unrecognized or malformed envelope verbatim.
    func parseEnvelope(name: String, header: String, body: String) -> WorktreePromptContent.Part?
    /// Transparent transport containers can contain Graftty's own delivery frames.
    func unwrapsNestedEnvelopes(named name: String) -> Bool
    /// JSON string values can contain literal envelope delimiters.
    func usesJSONBody(named name: String) -> Bool
    func parseText(_ text: String) -> WorktreePromptContent.Part?
    func skipsLine(_ line: String, following: Substring) -> Bool
    /// Only structured human activity belongs here, never arbitrary tool output.
    func transcriptInput(from record: [String: Any], state: inout HarnessTimelineTranscriptState) -> WorktreePromptContent.Part?
}

public extension HarnessTimelinePlugin {
    func parseText(_ text: String) -> WorktreePromptContent.Part? { nil }
    func unwrapsNestedEnvelopes(named name: String) -> Bool { false }
    func usesJSONBody(named name: String) -> Bool { false }
    func skipsLine(_ line: String, following: Substring) -> Bool { false }
    func transcriptInput(from record: [String: Any], state: inout HarnessTimelineTranscriptState) -> WorktreePromptContent.Part? { nil }
}

/// A transcript cursor persists pending questions across hook invocations.
public struct HarnessTimelineTranscriptState: Codable, Sendable {
    public struct Question: Codable, Sendable {
        public let id: String
        public let text: String
        public init(id: String, text: String) { self.id = id; self.text = text }
    }
    public var pendingQuestions: [String: [Question]] = [:]
    public init() {}

    public mutating func remember(_ questions: [Question], callID: String) {
        guard !questions.isEmpty, callID.utf8.count <= 512 else { return }
        // Unanswered calls must not grow a hook cursor indefinitely.
        if pendingQuestions.count >= 32, let key = pendingQuestions.keys.sorted().first {
            pendingQuestions.removeValue(forKey: key)
        }
        pendingQuestions[callID] = Array(questions.prefix(16)).map {
            .init(id: String($0.id.prefix(256)), text: String($0.text.prefix(2000)))
        }
    }
}

public enum HarnessTimelinePlugins {
    public static let builtins: [any HarnessTimelinePlugin] = [CodexTimelinePlugin(), ClaudeTimelinePlugin()]

    public static func matching(_ runtime: String?, in plugins: [any HarnessTimelinePlugin] = builtins) -> [any HarnessTimelinePlugin] {
        runtime.map { name in plugins.filter { $0.runtime == name } } ?? plugins
    }
}

/// Persisted semantic content. No provider tags or transport identifiers reach the view.
public struct HarnessTimelinePresentation: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case questionReply, command, commandOutput, interruption, review, voiceInput, context

        public var title: String {
            switch self {
            case .questionReply: "You answered"
            case .command: "You ran a command"
            case .commandOutput: "Command output"
            case .interruption: "You interrupted the turn"
            case .review: "Review result"
            case .voiceInput: "Voice input"
            case .context: "Context updated"
            }
        }
    }

    public struct Item: Codable, Hashable, Sendable {
        public let label: String
        public let value: String
        public init(label: String = "", value: String) { self.label = label; self.value = value }
    }

    public let kind: Kind
    public let items: [Item]
    public init(kind: Kind, items: [Item]) { self.kind = kind; self.items = items }
    public var text: String {
        items.map { $0.label.isEmpty ? $0.value : "\($0.label)\n\($0.value)" }.joined(separator: "\n\n")
    }

    func bounded(using budget: inout HarnessInputBudget) -> Self {
        var result: [Item] = []
        for item in items.prefix(16) {
            guard budget.hasSpace else { break }
            if !result.isEmpty { _ = budget.take("\n\n") }
            // Keep room for the answer when a provider repeats a long question.
            let label = budget.take(String(item.label.prefix(500)))
            if !label.isEmpty { _ = budget.take("\n") }
            result.append(.init(label: label, value: budget.take(item.value)))
        }
        return .init(kind: kind, items: result)
    }
}

struct HarnessInputBudget {
    var characters = 2000
    var bytes = 8000
    var hasSpace: Bool { characters > 0 && bytes > 0 }

    mutating func take(_ text: String) -> String {
        var result = ""
        for character in text {
            let size = String(character).utf8.count
            guard characters > 0, bytes >= size else { break }
            result.append(character)
            characters -= 1
            bytes -= size
        }
        return result
    }
}

extension WorktreePromptContent.Part {
    public init(source: Source, presentation: HarnessTimelinePresentation, wasTruncated: Bool? = nil) {
        self.init(source: source, text: presentation.text, presentation: presentation, wasTruncated: wasTruncated)
    }

    static var hidden: Self { .init(source: .generated, text: "") }

    func bounded(using budget: inout HarnessInputBudget) -> Self {
        let content = presentation?.bounded(using: &budget)
        let value = content?.text ?? budget.take(text)
        return .init(source: source, text: value, presentation: content,
                     wasTruncated: value != text || content != presentation || wasTruncated == true)
    }

    func markingTruncated() -> Self {
        .init(source: source, text: text, presentation: presentation, wasTruncated: true)
    }
}

enum HarnessEnvelope {
    /// Require direct sibling fields, so literals inside one field cannot replace another.
    static func siblingValues(_ names: [String], in text: String) -> [String]? {
        guard !names.isEmpty else { return nil }
        for (name, next) in zip(names, names.dropFirst()) {
            let boundary = "</" + NSRegularExpression.escapedPattern(for: name)
                + ">\\s*<" + NSRegularExpression.escapedPattern(for: next) + ">"
            let regex = try! NSRegularExpression(pattern: boundary)
            // These envelopes have no escaping contract. Multiple boundaries
            // are ambiguous, so leave the original message available verbatim.
            guard regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == 1 else { return nil }
        }
        let fields = names.map { name in
            let escaped = NSRegularExpression.escapedPattern(for: name)
            return "<\(escaped)>(.*?)</\(escaped)>\\s*"
        }.joined()
        guard let regex = try? NSRegularExpression(pattern: "(?s)\\A\\s*" + fields + "\\z"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1...names.count).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    static func value(_ name: String, in text: String) -> String? {
        let tag = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(pattern: "(?s)<\(tag)>(.*?)</\(tag)>"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

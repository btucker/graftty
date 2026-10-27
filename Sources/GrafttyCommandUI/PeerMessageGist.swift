import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// @spec CONTEXT-26
/// One display line for a peer message, and whether a model wrote it.
/// Human input never goes through this type.
public struct PeerMessageGist: Equatable, Sendable {
    public typealias Summarizer = @Sendable (String) async throws -> String?

    public let text: String
    public let isGenerated: Bool

    static let maxLength = 80

    /// The message itself when it already fits one line.
    static func verbatim(_ text: String) -> PeerMessageGist? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isNewline), text.count <= maxLength else { return nil }
        return PeerMessageGist(text: text, isGenerated: false)
    }

    /// The verbatim text, or else the message's first sentence or line.
    static func immediate(_ text: String) -> PeerMessageGist {
        if let verbatim = verbatim(text) { return verbatim }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trimmed.split(whereSeparator: \.isNewline).first ?? Substring(trimmed)
        // A sentence needs words, so a leading list marker such as "1." does not end one.
        var hasLetter = false
        let end = line.indices.first { index in
            hasLetter = hasLetter || line[index].isLetter
            let next = line.index(after: index)
            return hasLetter && ".!?".contains(line[index]) && (next == line.endIndex || line[next].isWhitespace)
        }
        return PeerMessageGist(text: clipped(String(end.map { line[...$0] } ?? line)), isGenerated: false)
    }

    static func clipped(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.count > maxLength else { return text }
        return text.prefix(maxLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    static let instructions = """
        Summarize the message from a coding agent in one plain line of at most 70 characters. \
        Reply with the summary only, with no preamble, quotes, or markdown.
        """

    /// Apple Intelligence on this device, or nil when it is unavailable.
    public static let onDevice: Summarizer = { text in
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: text).content
        }
        #endif
        return nil
    }
}

/// Generates each peer message's gist at most once per process.
public actor PeerMessageGistProvider {
    public static let shared = PeerMessageGistProvider(summarize: PeerMessageGist.onDevice)

    private let summarize: PeerMessageGist.Summarizer
    private let limit: Int
    /// A nil result means the model was unavailable, so the text is asked again later.
    private var cache: [String: Task<PeerMessageGist?, Never>] = [:]
    private var order: [String] = []

    public init(limit: Int = 256, summarize: @escaping PeerMessageGist.Summarizer) {
        self.limit = limit
        self.summarize = summarize
    }

    public func gist(for text: String) async -> PeerMessageGist {
        if let verbatim = PeerMessageGist.verbatim(text) { return verbatim }
        if let task = cache[text] { return await task.value ?? .immediate(text) }
        let summarize = summarize
        let task = Task<PeerMessageGist?, Never> {
            let reply: String?
            do {
                // Apple Intelligence may still be downloading or switched off; that is not a generation.
                guard let available = try await summarize(text) else { return nil }
                reply = available
            } catch {
                reply = nil
            }
            let summary = reply?.split(whereSeparator: \.isNewline).first?
                .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"“”")))
            guard let summary, !summary.isEmpty else { return PeerMessageGist.immediate(text) }
            return PeerMessageGist(text: PeerMessageGist.clipped(summary), isGenerated: true)
        }
        cache[text] = task
        order.append(text)
        if order.count > limit { cache[order.removeFirst()] = nil }
        guard let gist = await task.value else {
            if cache[text] == task {
                cache[text] = nil
                order.removeAll { $0 == text }
            }
            return .immediate(text)
        }
        return gist
    }
}

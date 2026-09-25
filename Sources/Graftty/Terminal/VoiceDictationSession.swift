import Foundation

/// Interprets complete utterances; a pause never implies permission to submit.
struct VoiceDictationSession {
    enum Action: Equatable {
        case none
        case preview(String)
        case write(String)
        case submit
    }

    private var finalized = Set<UUID>()
    private var hasWrittenText = false
    private var allowsSubmission = true
    private var cancelled = false

    mutating func receive(id: UUID, text: String, final: Bool) -> Action {
        guard !cancelled, !finalized.contains(id) else { return .none }
        let text = SurfaceNSView.singleLineNativeText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let command = text.lowercased().trimmingCharacters(in:
            CharacterSet(charactersIn: ".!? "))
        if final {
            finalized.insert(id)
            if command == "send prompt" {
                guard allowsSubmission else { return .none }
                cancelled = true
                return .submit
            }
            guard !text.isEmpty else { return .none }
            let delivery = (hasWrittenText ? " " : "") + text
            hasWrittenText = true
            return .write(delivery)
        }
        // Withhold command prefixes until recognition disambiguates them.
        if text.isEmpty || "send prompt".hasPrefix(command) { return .preview("") }
        return .preview((hasWrittenText ? " " : "") + text)
    }

    mutating func stopSubmitting() { allowsSubmission = false }
    mutating func cancel() { cancelled = true }
}

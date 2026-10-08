import Speech

/// Speech reports completed utterances separately from completion of the task.
final class VoiceSpeechTaskDelegate: NSObject, SFSpeechRecognitionTaskDelegate {
    enum Event: Sendable, Equatable {
        case result(id: UUID, text: String, final: Bool)
        case finished(error: String?)
        case cancelled
    }

    private let onEvent: @MainActor @Sendable (Event) -> Void
    @MainActor private var utterance = UUID()

    init(onEvent: @escaping @MainActor @Sendable (Event) -> Void) {
        self.onEvent = onEvent
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask,
                               didHypothesizeTranscription transcription: SFTranscription) {
        deliverResult(transcription.formattedString, final: false)
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask,
                               didFinishRecognition recognitionResult: SFSpeechRecognitionResult) {
        deliverResult(recognitionResult.bestTranscription.formattedString, final: true)
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        deliver(.finished(error: successfully ? nil : task.error?.localizedDescription
            ?? "Speech recognition did not finish. Try dictating again."))
    }

    func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
        deliver(.cancelled)
    }

    private func deliver(_ event: Event) {
        // The recognizer uses the main operation queue, preserving the order
        // of utterance delivery and task completion without asynchronous hops.
        MainActor.assumeIsolated { onEvent(event) }
    }

    private func deliverResult(_ text: String, final: Bool) {
        MainActor.assumeIsolated {
            let id = utterance
            if final { utterance = UUID() }
            onEvent(.result(id: id, text: text, final: final))
        }
    }
}

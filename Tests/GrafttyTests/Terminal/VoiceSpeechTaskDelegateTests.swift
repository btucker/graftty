import Speech
import Testing
@testable import Graftty

@MainActor
struct VoiceSpeechTaskDelegateTests {
    @Test("@spec KEY-4.9: When on-device speech recognition completes an utterance before its task ends, the application shall commit that utterance once, preserve it across later previews, and recognize a standalone Send prompt command.")
    func completedUtterancesSurviveTranscriptReset() {
        var session = VoiceDictationSession()
        var writes: [String] = []
        var preview = ""
        var submissions = 0
        let delegate = VoiceSpeechTaskDelegate { event in
            guard case .result(let utterance, let text, let final) = event else { return }
            switch session.receive(id: utterance, text: text, final: final) {
            case .none: break
            case .preview(let text): preview = text
            case .write(let text): writes.append(text); preview = ""
            case .submit: submissions += 1; preview = ""
            }
        }
        let task = SpeechTask()
        delegate.speechRecognitionTask(task, didHypothesizeTranscription: Transcript("make a"))
        delegate.speechRecognitionTask(task, didHypothesizeTranscription: Transcript("make an example"))
        delegate.speechRecognitionTask(task, didFinishRecognition: Result("Make an example.", final: false))
        delegate.speechRecognitionTask(task, didHypothesizeTranscription: Transcript("with tests"))
        #expect(writes == ["Make an example."])
        #expect(preview == " with tests")
        #expect(submissions == 0)

        delegate.speechRecognitionTask(task, didFinishRecognition: Result("With tests.", final: false))
        delegate.speechRecognitionTask(task, didHypothesizeTranscription: Transcript("Send prompt."))
        delegate.speechRecognitionTask(task, didFinishRecognition: Result("Send prompt.", final: false))
        delegate.speechRecognitionTask(task, didFinishRecognition: Result("", final: true))
        #expect(writes == ["Make an example.", " With tests."])
        #expect(preview.isEmpty)
        #expect(submissions == 1)
    }

    @Test("A final result precedes task completion, while a failure or cancellation never finalizes a hypothesis")
    func completionOrderAndFailures() throws {
        var events: [VoiceSpeechTaskDelegate.Event] = []
        let delegate = VoiceSpeechTaskDelegate { events.append($0) }
        let task = SpeechTask()
        delegate.speechRecognitionTask(task, didHypothesizeTranscription: Transcript("hello"))
        delegate.speechRecognitionTask(task, didFinishRecognition: Result("Hello.", final: true))
        delegate.speechRecognitionTask(task, didFinishSuccessfully: true)
        let id: UUID
        if case .result(let utterance, "hello", false) = events.first { id = utterance }
        else { Issue.record("Expected a provisional transcript"); return }
        #expect(events == [.result(id: id, text: "hello", final: false),
                           .result(id: id, text: "Hello.", final: true), .finished(error: nil)])
        events.removeAll()
        delegate.speechRecognitionTask(task, didHypothesizeTranscription: Transcript("unfinished"))
        delegate.speechRecognitionTask(task, didFinishSuccessfully: false)
        delegate.speechRecognitionTaskWasCancelled(task)
        #expect(events.count == 3)
        if case .result(_, "unfinished", false) = events[0] {} else { Issue.record("Expected a preview") }
        if case .finished(let error) = events[1] { #expect(error != nil) }
        else { Issue.record("Expected a recognition failure") }
        #expect(events[2] == .cancelled)
    }
}

private final class SpeechTask: SFSpeechRecognitionTask {
    override var error: Error? { nil }
}

private final class Transcript: SFTranscription {
    private let text: String
    init(_ text: String) { self.text = text; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var formattedString: String { text }
}

private final class Result: SFSpeechRecognitionResult {
    private let transcript: Transcript
    private let requestIsFinal: Bool
    init(_ text: String, final: Bool) {
        transcript = Transcript(text)
        requestIsFinal = final
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var bestTranscription: SFTranscription { transcript }
    override var isFinal: Bool { requestIsFinal }
}

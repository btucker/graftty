import Foundation
import Testing
@testable import Graftty

struct VoiceDictationTests {
    @Test("@spec KEY-4.1: While Graftty dictation is listening, the application shall preview revised speech without writing provisional text to the terminal.")
    func previews() {
        var session = VoiceDictationSession()
        let id = UUID()
        #expect(session.receive(id: id, text: "make a", final: false) == .preview("make a"))
        #expect(session.receive(id: id, text: "make an example", final: false) == .preview("make an example"))
        #expect(session.receive(id: id, text: "send", final: false) == .preview(""))
        #expect(session.receive(id: id, text: "Send prompt.", final: false) == .preview(""))
    }

    @Test("@spec KEY-4.2: When a finalized dictation utterance consists of Send prompt, the application shall submit once and stop listening without inserting the command words.")
    func sendsOnlyFinalStandaloneCommand() {
        var session = VoiceDictationSession()
        let id = UUID()
        #expect(session.receive(id: id, text: "Send prompt!", final: false) == .preview(""))
        #expect(session.receive(id: id, text: "Send prompt!", final: true) == .submit)
        #expect(session.receive(id: id, text: "Send prompt!", final: true) == .none)
        #expect(session.receive(id: UUID(), text: "more", final: true) == .none)
        for ordinary in ["change the send prompt button", "send prompt tomorrow", "send", "send, prompt"] {
            var other = VoiceDictationSession()
            #expect(other.receive(id: UUID(), text: ordinary, final: true) == .write(ordinary))
        }
    }

    @Test("@spec KEY-4.3: When ordinary dictation finalizes at a pause, the application shall insert single-line text once, separate successive utterances with a space, and keep listening without submitting.")
    func commits() {
        var session = VoiceDictationSession()
        let first = UUID()
        #expect(session.receive(id: first, text: "hello\nworld\u{1b}", final: true) == .write("hello world"))
        #expect(session.receive(id: first, text: "hello", final: true) == .none)
        #expect(session.receive(id: UUID(), text: "next", final: false) == .preview(" next"))
        #expect(session.receive(id: UUID(), text: "next", final: true) == .write(" next"))
        #expect(session.receive(id: UUID(), text: "send prompt", final: true) == .submit)
    }

    @Test("@spec KEY-4.4: When dictation stops or its terminal becomes unavailable, the application shall reject later recognition callbacks and shall not submit the terminal input.")
    func cancellationAndManualStop() {
        var session = VoiceDictationSession()
        session.stopSubmitting()
        #expect(session.receive(id: UUID(), text: "send prompt", final: true) == .none)
        session.cancel()
        #expect(session.receive(id: UUID(), text: "late speech", final: true) == .none)
        var ordinary = VoiceDictationSession()
        ordinary.stopSubmitting()
        #expect(ordinary.receive(id: UUID(), text: "last words", final: true) == .write("last words"))
    }
}

import AVFoundation
import Testing
@testable import Graftty

@Suite("@spec KEY-4.8: While recognition finalizes an utterance, the application shall retain subsequent microphone audio for the next utterance or stop with an error if buffering capacity is exceeded.")
struct VoiceAudioFeederTests {
    private func buffer(value: Float, seconds: Double = 0.2) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(seconds * 16_000))!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].update(repeating: value, count: Int(buffer.frameLength))
        return buffer
    }

    @Test func retainsCopiesInOrderAcrossRequestBoundary() {
        let feeder = VoiceAudioFeeder()
        let token = feeder.token
        var first: [Float] = []
        var second: [Float] = []
        var ended = 0
        feeder.begin(append: { first.append($0.floatChannelData![0][0]) }, endAudio: { ended += 1 })
        #expect(feeder.append(buffer(value: 0.1), token: token))
        feeder.endRequest()
        feeder.endRequest()
        let reusedTapBuffer = buffer(value: 0.2)
        #expect(feeder.append(reusedTapBuffer, token: token))
        reusedTapBuffer.floatChannelData![0].update(repeating: 0.3, count: Int(reusedTapBuffer.frameLength))
        #expect(feeder.append(reusedTapBuffer, token: token))
        #expect(feeder.hasPendingSpeech)
        feeder.begin(append: { second.append($0.floatChannelData![0][0]) }, endAudio: {})
        #expect(feeder.append(buffer(value: 0.4), token: token))
        #expect(first == [0.1])
        #expect(second == [0.2, 0.3, 0.4])
        #expect(ended == 1)
        #expect(!feeder.hasPendingSpeech)
    }

    @Test func refusesOverflowWithoutDiscardingAcceptedAudio() {
        let feeder = VoiceAudioFeeder()
        let token = feeder.token
        #expect(feeder.append(buffer(value: 0.1, seconds: 5), token: token))
        #expect(!feeder.append(buffer(value: 0.2), token: token))
        var seconds: Double = 0
        feeder.begin(append: { seconds += Double($0.frameLength) / $0.format.sampleRate }, endAudio: {})
        #expect(seconds == 5)
    }

    @Test func cancellationDiscardsQueuedAudioAndSilenceDoesNotCountAsSpeech() {
        let feeder = VoiceAudioFeeder()
        let token = feeder.token
        #expect(feeder.append(buffer(value: 0), token: token))
        #expect(!feeder.hasPendingSpeech)
        #expect(feeder.append(buffer(value: 0.1), token: token))
        #expect(feeder.hasPendingSpeech)
        feeder.reset()
        #expect(!feeder.hasPendingSpeech)
        var received = false
        feeder.begin(append: { _ in received = true }, endAudio: {})
        #expect(!received)
    }

    @Test func ignoresLateTapFromCancelledSessionEvenAfterRestart() {
        let feeder = VoiceAudioFeeder()
        let oldToken = feeder.token
        feeder.reset()
        var received: [Float] = []
        feeder.begin(append: { received.append($0.floatChannelData![0][0]) }, endAudio: {})
        #expect(!feeder.append(buffer(value: 0.1), token: oldToken))
        #expect(feeder.append(buffer(value: 0.2), token: feeder.token))
        #expect(received == [0.2])
    }

}

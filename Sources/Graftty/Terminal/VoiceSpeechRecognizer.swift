import AVFoundation
import Foundation
import Speech

/// Keeps recording across utterance boundaries, buffering audio while Speech
/// finalizes the preceding request. The caller interprets the resulting text.
@MainActor
final class VoiceSpeechRecognizer: VoiceSpeechRecognizing {
    enum Failure: LocalizedError {
        case microphonePermission, speechPermission, unavailableLanguage, unavailableRecognizer
        case unavailableMicrophone, noSpeech, finalizationTimeout, audioBacklog

        var errorDescription: String? {
            switch self {
            case .microphonePermission:
                return "Allow Graftty to use the microphone in System Settings > Privacy & Security > Microphone."
            case .speechPermission:
                return "Allow Graftty to recognize speech in System Settings > Privacy & Security > Speech Recognition."
            case .unavailableLanguage:
                return "On-device speech recognition is unavailable for your system language. Enable Dictation in System Settings > Keyboard and download its language, then try again."
            case .unavailableRecognizer:
                return "Speech recognition is unavailable. Try again in a moment."
            case .unavailableMicrophone:
                return "No microphone is available. Select an input in System Settings > Sound."
            case .noSpeech:
                return "No speech was detected. Check your microphone and try again."
            case .audioBacklog:
                return "Speech recognition could not keep up with the microphone. Please try again."
            case .finalizationTimeout:
                return "Speech recognition did not finish. Try dictating again."
            }
        }
    }

    private var generation = UUID()
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var deadline: Task<Void, Never>?
    private var activityMonitor: Task<Void, Never>?
    private var onResult: ((UUID, String, Bool) -> Void)?
    private var utterance = UUID()
    nonisolated private let feeder = VoiceAudioFeeder()
    private var awaitingFinal = false
    private var onError: ((String) -> Void)?
    private var onFinished: (() -> Void)?
    private var finishing = false
    private var startedAt: TimeInterval = 0
    private var lastSpeechAt: TimeInterval?
    private var voicedDuration: TimeInterval = 0

    func start(
        onResult: @escaping (UUID, String, Bool) -> Void,
        onError: @escaping (String) -> Void,
        onReady: @escaping () throws -> Void = {}
    ) async throws {
        cancel()
        let token = generation
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        try validate(token)
        guard microphoneAllowed else { throw Failure.microphonePermission }
        let speechAuthorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try validate(token)
        guard speechAuthorization == .authorized else { throw Failure.speechPermission }
        // Let the permission sheet dismiss before the caller validates focus.
        await Task.yield()
        try validate(token)
        guard let recognizer = SFSpeechRecognizer(locale: .current),
              recognizer.supportsOnDeviceRecognition else { throw Failure.unavailableLanguage }
        guard recognizer.isAvailable else { throw Failure.unavailableRecognizer }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.unavailableMicrophone }
        try onReady()
        try validate(token)
        self.engine = engine
        self.recognizer = recognizer
        self.onResult = onResult
        self.onError = onError
        beginUtterance(token: token)

        let audioToken = feeder.token
        let audioFeeder = feeder
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let accepted = audioFeeder.append(buffer, token: audioToken)
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            let audible = Self.hasSpeechEnergy(buffer)
            let time = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, !self.finishing else { return }
                guard accepted else { self.fail(Failure.audioBacklog.localizedDescription); return }
                if audible {
                    self.voicedDuration += duration
                    self.lastSpeechAt = time
                }
            }
        }
        do {
            engine.prepare()
            try engine.start()
            startActivityMonitor(token: token)
        } catch {
            cancel()
            throw error
        }
    }

    private func startActivityMonitor(token: UUID) {
        activityMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, self.generation == token, !self.finishing else { return }
                guard !self.awaitingFinal else { continue }
                let time = ProcessInfo.processInfo.systemUptime
                if self.voicedDuration >= 0.15,
                   let lastSpeechAt = self.lastSpeechAt, time - lastSpeechAt >= 1 {
                    self.endUtterance()
                } else if time - self.startedAt >= 50 {
                    // Keep tasks below Speech's per-request duration limit.
                    self.endUtterance()
                } else if self.voicedDuration < 0.15, time - self.startedAt >= 30 {
                    self.fail(Failure.noSpeech.localizedDescription)
                }
            }
        }
    }

    private func beginUtterance(token: UUID) {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = ["Send prompt"]
        self.request = request
        utterance = UUID()
        let utteranceID = utterance
        awaitingFinal = false
        startedAt = ProcessInfo.processInfo.systemUptime
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.utterance == utteranceID else { return }
                if let text {
                    let callback = self.onResult
                    var completion: (() -> Void)?
                    if isFinal {
                        let bufferedSpeech = self.awaitingFinal && self.feeder.hasPendingSpeech
                        if !self.awaitingFinal {
                            self.voicedDuration = 0
                            self.lastSpeechAt = nil
                        }
                        self.deadline?.cancel()
                        self.deadline = nil
                        self.feeder.endRequest()
                        self.recognitionTask = nil
                        self.request = nil
                        // Invalidate this task before delivering a final, since
                        // the caller may cancel or start another session.
                        self.utterance = UUID()
                        if self.finishing && !bufferedSpeech {
                            completion = self.onFinished
                            self.cancel()
                        }
                    }
                    callback?(utteranceID, text, isFinal)
                    completion?()
                    if isFinal {
                        guard self.generation == token else { return }
                        self.beginUtterance(token: token)
                        if self.finishing { self.endUtterance() }
                        return
                    }
                }
                if let failure { self.fail(failure) }
            }
        }
        feeder.begin(append: { request.append($0) }, endAudio: { request.endAudio() })
    }

    /// Ends capture, retaining the recognition task until its final result.
    /// Never treats a partial transcript as final if Speech fails or times out.
    func finish(onFinished: @escaping () -> Void = {}) {
        guard !finishing else { return }
        guard request != nil else {
            cancel()
            onFinished()
            return
        }
        self.onFinished = onFinished
        finishing = true
        stopRecording()
        endUtterance()
    }

    private func endUtterance() {
        guard request != nil, !awaitingFinal else { return }
        awaitingFinal = true
        voicedDuration = 0
        lastSpeechAt = nil
        feeder.endRequest()
        let token = generation
        let utteranceID = utterance
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.generation == token, self.utterance == utteranceID else { return }
            self.fail(Failure.finalizationTimeout.localizedDescription)
        }
    }

    func cancel() {
        generation = UUID()
        deadline?.cancel()
        deadline = nil
        stopRecording()
        feeder.reset()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer = nil
        onResult = nil
        onError = nil
        onFinished = nil
        finishing = false
        awaitingFinal = false
        voicedDuration = 0
        lastSpeechAt = nil
    }

    private func stopRecording() {
        activityMonitor?.cancel()
        activityMonitor = nil
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    private func validate(_ token: UUID) throws {
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
    }

    private func fail(_ message: String) {
        let callback = onError
        cancel()
        callback?(message)
    }

    nonisolated fileprivate static func hasSpeechEnergy(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return false }
        let count = Int(buffer.frameLength)
        // Use the loudest channel so a stereo microphone's quiet channel does
        // not hide speech. This detects pauses, not words or intent.
        for channel in 0..<Int(buffer.format.channelCount) {
            var energy: Float = 0
            for frame in 0..<count {
                let sample = channels[channel][frame * buffer.stride]
                energy += sample * sample
            }
            if energy / Float(count) > 0.000009 { return true }
        }
        return false
    }
}

/// The audio tap and main actor share this feeder. Holding its lock across append
/// and endAudio ensures Speech never receives audio after a request has ended.
final class VoiceAudioFeeder: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()

    var token: UUID {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }
    private var appendAudio: ((AVAudioPCMBuffer) -> Void)?
    private var endAudio: (() -> Void)?
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingDuration: TimeInterval = 0
    private var pendingSpeechDuration: TimeInterval = 0

    var hasPendingSpeech: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingSpeechDuration >= 0.15
    }

    func begin(append: @escaping (AVAudioPCMBuffer) -> Void, endAudio: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        appendAudio = append
        self.endAudio = endAudio
        for buffer in pending { append(buffer) }
        pending.removeAll(keepingCapacity: true)
        pendingDuration = 0
        pendingSpeechDuration = 0
    }

    func append(_ buffer: AVAudioPCMBuffer, token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard token == generation else { return false }
        if let appendAudio {
            appendAudio(buffer)
            return true
        }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        guard pendingDuration + duration <= 5,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return false }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<source.count {
            guard let input = source[index].mData, let output = destination[index].mData else { return false }
            memcpy(output, input, Int(source[index].mDataByteSize))
        }
        pending.append(copy)
        pendingDuration += duration
        if VoiceSpeechRecognizer.hasSpeechEnergy(buffer) { pendingSpeechDuration += duration }
        return true
    }

    func endRequest() {
        lock.lock()
        defer { lock.unlock() }
        endAudio?()
        appendAudio = nil
        endAudio = nil
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        generation = UUID()
        appendAudio = nil
        endAudio = nil
        pending.removeAll()
        pendingDuration = 0
        pendingSpeechDuration = 0
    }
}

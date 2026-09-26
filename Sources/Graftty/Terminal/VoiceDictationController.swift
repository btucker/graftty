import AppKit
import Combine

@MainActor
protocol VoiceSpeechRecognizing: AnyObject {
    func start(onResult: @escaping (UUID, String, Bool) -> Void,
               onError: @escaping (String) -> Void,
               onReady: @escaping () throws -> Void) async throws
    func finish(onFinished: @escaping () -> Void)
    func cancel()
}

/// The closures retain no terminal handle, so closing a pane ends its eligibility.
@MainActor
struct VoiceDictationTarget {
    var isAvailable: () -> Bool
    var preview: (String) -> Void
    var write: (String) -> Bool
    var submit: () -> Void
    var claim: () -> Bool
    var setInterruption: ((() -> Void)?) -> Void
    var suppressKeyRelease: (UInt16) -> Void

    init(handle: SurfaceHandle) {
        isAvailable = { [weak handle] in
            guard let view = handle?.view as? SurfaceNSView else { return false }
            return view.surface != nil && !view.isReadonly && view.window?.isKeyWindow == true
                && view.window?.firstResponder === view
                && !view.isHiddenOrHasHiddenAncestor && !view.hasMarkedText()
        }
        preview = { [weak handle] text in
            guard let view = handle?.view as? SurfaceNSView, let surface = view.surface else { return }
            view.surfaceOperations.preedit(surface, text)
        }
        write = { [weak handle] text in handle?.writeText(text) ?? false }
        submit = { [weak handle] in handle?.pressReturn() }
        claim = { [weak handle] in
            guard let handle else { return false }
            return !handle.canTakeDisplayControl() || handle.takeDisplayControl()
        }
        setInterruption = { [weak handle] callback in
            (handle?.view as? SurfaceNSView)?.voiceInputInterrupted = callback
        }
        suppressKeyRelease = { [weak handle] keyCode in
            (handle?.view as? SurfaceNSView)?.suppressCompositionKeyRelease(keyCode)
        }
    }

    init(isAvailable: @escaping () -> Bool, preview: @escaping (String) -> Void,
         write: @escaping (String) -> Bool, submit: @escaping () -> Void,
         claim: @escaping () -> Bool, setInterruption: @escaping ((() -> Void)?) -> Void,
         suppressKeyRelease: @escaping (UInt16) -> Void) {
        self.isAvailable = isAvailable
        self.preview = preview
        self.write = write
        self.submit = submit
        self.claim = claim
        self.setInterruption = setInterruption
        self.suppressKeyRelease = suppressKeyRelease
    }
}

/// Owns one opt-in microphone session and pins all input to its original pane.
@MainActor
final class VoiceDictationController: ObservableObject {
    @Published private(set) var isListening = false
    @Published var errorMessage: String?
    private var session = VoiceDictationSession()
    private var recognizer: (any VoiceSpeechRecognizing)?
    private let makeRecognizer: @MainActor () -> any VoiceSpeechRecognizing
    private var target: VoiceDictationTarget?
    private var generation = UUID()
    private var stopping = false
    private var ready = false
    private var keyMonitor: Any?
    private var inactiveObserver: NSObjectProtocol?
    private var startTask: Task<Void, Never>?

    init(makeRecognizer: @escaping @MainActor () -> any VoiceSpeechRecognizing = { VoiceSpeechRecognizer() }) {
        self.makeRecognizer = makeRecognizer
    }

    func toggle(target: SurfaceHandle?) {
        if !isListening, let view = target?.view as? SurfaceNSView {
            view.window?.makeFirstResponder(view)
        }
        toggle(inputTarget: target.map(VoiceDictationTarget.init(handle:)))
    }

    func toggle(inputTarget: VoiceDictationTarget?) {
        if isListening {
            guard !stopping else { return }
            stopping = true
            session.stopSubmitting()
            let current = generation
            recognizer?.finish { [weak self] in
                guard let self, self.generation == current else { return }
                self.cancel()
            }
            return
        }
        errorMessage = nil
        guard let inputTarget, inputTarget.isAvailable() else {
            errorMessage = "Select a writable terminal and finish any text composition before starting dictation."
            return
        }
        target = inputTarget
        session = VoiceDictationSession()
        generation = UUID()
        let current = generation
        stopping = false
        ready = false
        isListening = true
        let driver = makeRecognizer()
        recognizer = driver
        startTask = Task { [weak self] in
            do {
                try await driver.start(onResult: { [weak self] id, text, final in
                    guard let self, self.generation == current, self.ready else { return }
                    self.receive(id: id, text: text, final: final)
                }, onError: { [weak self] message in
                    guard let self, self.generation == current else { return }
                    self.cancel()
                    self.errorMessage = message
                }, onReady: { [weak self] in
                    guard let self, self.generation == current, !Task.isCancelled,
                          self.target?.isAvailable() == true else { throw CancellationError() }
                    self.ready = true
                    self.installInterruptionHandlers()
                })
            } catch {
                guard let self, self.generation == current else { return }
                self.cancel()
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
    }

    private func installInterruptionHandlers() {
        target?.setInterruption { [weak self] in self?.cancel() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consume = MainActor.assumeIsolated { self?.handleKeyDown(event.keyCode) ?? false }
            return consume ? nil : event
        }
        inactiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    /// Consume Escape through its release; other physical keys cancel and pass on.
    func handleKeyDown(_ keyCode: UInt16) -> Bool {
        guard isListening, ready else { return false }
        let consume = keyCode == 53
        if consume { target?.suppressKeyRelease(keyCode) }
        cancel()
        return consume
    }

    private func receive(id: UUID, text: String, final: Bool) {
        guard isListening, let target, target.isAvailable() else {
            cancel()
            return
        }
        switch session.receive(id: id, text: text, final: final) {
        case .none: break
        case .preview(let text): target.preview(text)
        case .write(let text):
            target.preview("")
            guard target.claim(), target.write(text) else {
                cancel()
                errorMessage = "Dictation stopped because the terminal could not accept input."
                return
            }
        case .submit:
            let canSend = target.claim()
            cancel()
            if canSend { target.submit() }
            else { errorMessage = "Dictation stopped because this terminal is controlled elsewhere." }
        }
    }

    func cancel() {
        generation = UUID()
        session.cancel()
        recognizer?.cancel()
        recognizer = nil
        startTask?.cancel()
        startTask = nil
        target?.preview("")
        target?.setInterruption(nil)
        target = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let inactiveObserver { NotificationCenter.default.removeObserver(inactiveObserver) }
        inactiveObserver = nil
        isListening = false
        stopping = false
        ready = false
    }
}

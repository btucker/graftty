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
            guard let view = handle?.view as? SurfaceNSView else { return }
            view.showVoicePreview(text)
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
    var isListening: Bool { run != nil }
    /// Hides by itself after `errorLifetime`, or at the next click (KEY-4.11, KEY-4.12).
    @Published var errorMessage: String? {
        didSet { scheduleErrorDismissal() }
    }
    private let errorLifetime: Duration
    private var errorDismissal: Task<Void, Never>?
    private var clickMonitor: Any?
    private let makeRecognizer: @MainActor () -> any VoiceSpeechRecognizing

    /// One dictation, from the toggle that starts it until it is cancelled.
    private struct Run {
        enum Stage {
            /// The recognizer has not yet reported that it is listening.
            case starting
            case ready(Interruption)
            /// The user toggled off; the recognizer is delivering its last
            /// result. `nil` when that happened before the recognizer was ready.
            case stopping(Interruption?)
        }
        /// What ends a ready dictation early: a key press or the app going inactive.
        struct Interruption {
            let keyMonitor: Any?
            let inactiveObserver: NSObjectProtocol
        }
        let id = UUID()
        let recognizer: any VoiceSpeechRecognizing
        let target: VoiceDictationTarget
        var session = VoiceDictationSession()
        var startTask: Task<Void, Never>?
        var stage = Stage.starting

        /// Whether recognition results and interrupting keys are accepted.
        var isReady: Bool {
            switch stage {
            case .starting, .stopping(nil): false
            case .ready, .stopping: true
            }
        }
    }
    /// `nil` while idle. Only starting and ending a dictation publish.
    private var run: Run? {
        willSet { if (newValue == nil) != (run == nil) { objectWillChange.send() } }
    }

    init(makeRecognizer: @escaping @MainActor () -> any VoiceSpeechRecognizing = { VoiceSpeechRecognizer() },
         errorLifetime: Duration = .seconds(6)) {
        self.makeRecognizer = makeRecognizer
        self.errorLifetime = errorLifetime
    }

    /// A click anywhere in the app dismisses a showing error.
    func handleMouseDown() {
        errorMessage = nil
    }

    private func scheduleErrorDismissal() {
        errorDismissal?.cancel()
        errorDismissal = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard errorMessage != nil else { return }
        let lifetime = errorLifetime
        errorDismissal = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.errorMessage = nil
        }
        // Clicks pass through untouched; they only hide the message.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseDown() }
            return event
        }
    }

    func toggle(target: SurfaceHandle?) {
        if run == nil, let view = target?.view as? SurfaceNSView {
            view.window?.makeFirstResponder(view)
        }
        toggle(inputTarget: target.map(VoiceDictationTarget.init(handle:)))
    }

    func toggle(inputTarget: VoiceDictationTarget?) {
        if let current = run {
            let interruption: Run.Interruption?
            switch current.stage {
            case .starting: interruption = nil
            case .ready(let installed): interruption = installed
            case .stopping: return
            }
            run?.stage = .stopping(interruption)
            run?.session.stopSubmitting()
            current.recognizer.finish { [weak self] in
                guard let self, self.run?.id == current.id else { return }
                self.cancel()
            }
            return
        }
        errorMessage = nil
        guard let inputTarget, inputTarget.isAvailable() else {
            errorMessage = "Select a writable terminal and finish any text composition before starting dictation."
            return
        }
        let driver = makeRecognizer()
        let started = Run(recognizer: driver, target: inputTarget)
        let current = started.id
        run = started
        run?.startTask = Task { [weak self] in
            do {
                try await driver.start(onResult: { [weak self] id, text, final in
                    guard let self, let run = self.run, run.id == current, run.isReady else { return }
                    self.receive(id: id, text: text, final: final)
                }, onError: { [weak self] message in
                    guard let self, self.run?.id == current else { return }
                    self.cancel()
                    self.errorMessage = message
                }, onReady: { [weak self] in
                    guard let self, let run = self.run, run.id == current, !Task.isCancelled,
                          run.target.isAvailable() else { throw CancellationError() }
                    let interruption = self.installInterruptionHandlers(for: run.target)
                    if case .starting = run.stage { self.run?.stage = .ready(interruption) }
                    else { self.run?.stage = .stopping(interruption) }
                })
            } catch {
                guard let self, self.run?.id == current else { return }
                self.cancel()
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
    }

    private func installInterruptionHandlers(for target: VoiceDictationTarget) -> Run.Interruption {
        target.setInterruption { [weak self] in self?.cancel() }
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consume = MainActor.assumeIsolated { self?.handleKeyDown(event.keyCode) ?? false }
            return consume ? nil : event
        }
        let inactiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        return .init(keyMonitor: keyMonitor, inactiveObserver: inactiveObserver)
    }

    /// Consume Escape through its release; other physical keys cancel and pass on.
    func handleKeyDown(_ keyCode: UInt16) -> Bool {
        guard let run, run.isReady else { return false }
        let consume = keyCode == 53
        if consume { run.target.suppressKeyRelease(keyCode) }
        cancel()
        return consume
    }

    private func receive(id: UUID, text: String, final: Bool) {
        guard let target = run?.target, target.isAvailable() else {
            cancel()
            return
        }
        switch run?.session.receive(id: id, text: text, final: final) ?? .none {
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
        guard let ended = run else { return }
        run = nil
        ended.recognizer.cancel()
        ended.startTask?.cancel()
        ended.target.preview("")
        ended.target.setInterruption(nil)
        switch ended.stage {
        case .ready(let interruption), .stopping(let interruption?):
            if let keyMonitor = interruption.keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            NotificationCenter.default.removeObserver(interruption.inactiveObserver)
        case .starting, .stopping(nil):
            break
        }
    }
}

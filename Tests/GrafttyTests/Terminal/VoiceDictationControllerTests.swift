import AppKit
import Testing
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@MainActor
struct VoiceDictationControllerTests {
    @Test("The selected pane is unavailable after keyboard focus moves to a search field")
    func concreteTargetRequiresKeyboardFocus() throws {
        _ = NSApplication.shared
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try #require(SurfaceHandle(
            terminalID: PaneSlotID(id: UUID()), app: fakeApp(),
            worktreePath: "/tmp/voice-focus-test", socketPath: "/tmp/graftty.sock",
            surfaceFactory: harness.factory
        ))
        let view = try #require(handle.view as? SurfaceNSView)
        view.surfaceOperations = .init(setSize: { _, _, _ in }, size: { _ in .zero }, refresh: { _ in })
        view.surfaceOperations.setFocus = { _, _ in }
        let window = VoiceTargetTestWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                                           styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { view.surface = nil; window.close() }
        let content = NSView(frame: window.frame)
        window.contentView = content
        content.addSubview(view)
        let field = NSTextField(frame: .init(x: 0, y: 0, width: 100, height: 24))
        content.addSubview(field)
        window.makeFirstResponder(view)
        let target = VoiceDictationTarget(handle: handle)
        #expect(target.isAvailable())
        window.makeFirstResponder(field)
        #expect(!target.isAvailable())
    }

    @Test("Cancelling authorization rejects a later grant and recognition callbacks")
    func cancelledAuthorization() async {
        let fixture = VoiceControllerFixture()
        fixture.controller.toggle(inputTarget: fixture.target)
        await fixture.waitForAuthorization()
        #expect(fixture.interruption == nil)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(fixture.controller.isListening)
        fixture.controller.cancel()
        await fixture.authorize()
        fixture.driver.result?(UUID(), "late text", true)
        fixture.driver.result?(UUID(), "send prompt", true)
        #expect(!fixture.controller.isListening)
        #expect(fixture.writes.isEmpty)
        #expect(fixture.submissions == 0)
        #expect(!fixture.driver.ready)
    }

    @Test("Authorization rechecks whether the pinned pane is available")
    func targetUnavailableDuringAuthorization() async {
        let fixture = VoiceControllerFixture()
        fixture.controller.toggle(inputTarget: fixture.target)
        await fixture.waitForAuthorization()
        fixture.available = false
        await fixture.authorize()
        #expect(!fixture.driver.ready)
        #expect(!fixture.controller.isListening)
        #expect(fixture.interruption == nil)
    }

    @Test("Target interruption cancels capture and rejects late callbacks")
    func interruptedTarget() async {
        let fixture = VoiceControllerFixture()
        await fixture.start()
        fixture.interruption?()
        fixture.driver.result?(UUID(), "late text", true)
        #expect(fixture.driver.cancelled)
        #expect(!fixture.controller.isListening)
        #expect(fixture.writes.isEmpty)
        #expect(fixture.interruption == nil)
    }

    @Test("A stale callback cannot write into a newly started session")
    func priorGeneration() async {
        let fixture = VoiceControllerFixture()
        await fixture.start()
        let previousCallback = fixture.driver.result
        fixture.controller.cancel()
        await fixture.start()
        previousCallback?(UUID(), "stale", true)
        #expect(fixture.writes.isEmpty)
        #expect(fixture.controller.isListening)
        fixture.controller.cancel()
    }

    @Test("Unavailable or readonly panes reject results before delivery")
    func unavailableTarget() async {
        let fixture = VoiceControllerFixture()
        await fixture.start()
        fixture.available = false
        fixture.driver.result?(UUID(), "hello", true)
        #expect(fixture.writes.isEmpty)
        #expect(!fixture.controller.isListening)
    }

    @Test("Failed delivery stops dictation before a later submission command")
    func failedWrite() async {
        let fixture = VoiceControllerFixture()
        await fixture.start()
        fixture.acceptWrite = false
        fixture.driver.result?(UUID(), "hello", true)
        fixture.driver.result?(UUID(), "send prompt", true)
        #expect(fixture.submissions == 0)
        #expect(!fixture.controller.isListening)
        #expect(fixture.controller.errorMessage != nil)
    }

    @Test("Manual Stop drains final text while suppressing submission")
    func manualStop() async {
        let fixture = VoiceControllerFixture()
        await fixture.start()
        fixture.controller.toggle(inputTarget: nil)
        #expect(fixture.driver.finished != nil)
        fixture.driver.result?(UUID(), "last words", true)
        fixture.driver.result?(UUID(), "send prompt", true)
        #expect(fixture.writes == ["last words"])
        #expect(fixture.submissions == 0)
        fixture.driver.finished?()
        #expect(!fixture.controller.isListening)
    }

    @Test("Final command submits once after capture has stopped")
    func submitOnce() async {
        let fixture = VoiceControllerFixture()
        await fixture.start()
        let id = UUID()
        fixture.driver.result?(id, "send prompt", true)
        fixture.driver.result?(id, "send prompt", true)
        #expect(fixture.submissions == 1)
        #expect(fixture.stoppedWhenSubmitted)
        #expect(!fixture.controller.isListening)
        #expect(fixture.writes.isEmpty)
    }

    @Test("Escape suppresses its release; ordinary keys cancel and pass through")
    func physicalKeys() async {
        let fixture = VoiceControllerFixture()
        await fixture.start()
        #expect(fixture.controller.handleKeyDown(53))
        #expect(fixture.suppressedKeys == [53])
        await fixture.start()
        #expect(!fixture.controller.handleKeyDown(0))
        #expect(!fixture.controller.isListening)
        #expect(fixture.suppressedKeys == [53])
    }

    @Test("A consumed Escape does not send its repeat or release to Ghostty")
    func consumedEscapeLifecycle() throws {
        _ = NSApplication.shared
        let view = SurfaceNSView(frame: .zero)
        var forwarded = 0
        view.surfaceOperations.key = { _, _ in forwarded += 1; return true }
        view.surface = UnsafeMutableRawPointer(bitPattern: 1)
        defer { view.surface = nil }
        view.suppressCompositionKeyRelease(53)
        let repeated = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: true, keyCode: 53))
        let release = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        view.keyDown(with: repeated)
        view.keyUp(with: release)
        #expect(forwarded == 0)
    }

    @Test("Losing key-window focus interrupts voice input immediately")
    func keyWindowLoss() {
        _ = NSApplication.shared
        let view = SurfaceNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        var interrupted = false
        view.voiceInputInterrupted = { interrupted = true }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(interrupted)
        window.close()
    }
}

@MainActor
private final class VoiceControllerFixture {
    let driver = FakeVoiceRecognizer()
    lazy var controller = VoiceDictationController(makeRecognizer: { [driver] in driver })
    var available = true
    var acceptWrite = true
    var writes: [String] = []
    var submissions = 0
    var stoppedWhenSubmitted = false
    var interruption: (() -> Void)?
    var suppressedKeys: [UInt16] = []

    var target: VoiceDictationTarget {
        VoiceDictationTarget(
            isAvailable: { [unowned self] in available },
            preview: { _ in },
            write: { [unowned self] text in
                guard acceptWrite else { return false }
                writes.append(text)
                return true
            },
            submit: { [unowned self] in
                submissions += 1
                stoppedWhenSubmitted = driver.cancelled && !controller.isListening
            },
            claim: { true },
            setInterruption: { [unowned self] in interruption = $0 },
            suppressKeyRelease: { [unowned self] in suppressedKeys.append($0) }
        )
    }

    func waitForAuthorization() async {
        for _ in 0..<100 {
            if driver.authorization != nil { return }
            await Task.yield()
        }
        Issue.record("Recognizer never requested authorization")
    }

    func authorize() async {
        let continuation = driver.authorization
        driver.authorization = nil
        continuation?.resume()
        for _ in 0..<100 {
            if driver.startReturned { return }
            await Task.yield()
        }
        Issue.record("Recognizer start did not finish")
    }

    func start() async {
        controller.toggle(inputTarget: target)
        await waitForAuthorization()
        await authorize()
    }
}

@MainActor
private final class FakeVoiceRecognizer: VoiceSpeechRecognizing {
    var authorization: CheckedContinuation<Void, Never>?
    var result: ((UUID, String, Bool) -> Void)?
    var finished: (() -> Void)?
    var ready = false
    var cancelled = false
    var startReturned = false

    func start(onResult: @escaping (UUID, String, Bool) -> Void,
               onError: @escaping (String) -> Void,
               onReady: @escaping () throws -> Void) async throws {
        ready = false
        cancelled = false
        startReturned = false
        result = onResult
        defer { startReturned = true }
        await withCheckedContinuation { authorization = $0 }
        try onReady()
        ready = true
    }

    func finish(onFinished: @escaping () -> Void) { finished = onFinished }
    func cancel() { cancelled = true }
}

@MainActor
private final class VoiceTargetTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

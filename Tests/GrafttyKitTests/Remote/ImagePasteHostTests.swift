import Foundation
import AppKit
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@MainActor
struct ImagePasteHostTests {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        func record(_ event: String) { lock.withLock { events.append(event) } }
        var snapshot: [String] { lock.withLock { events } }
    }

    final class DelayedDispatcher: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: (@Sendable () -> Void)?
        func schedule(_ action: @escaping @Sendable () -> Void) {
            lock.withLock { pending = action }
        }
        func run() {
            let action = lock.withLock {
                let action = pending
                pending = nil
                return action
            }
            action?()
        }
    }

    private func make(
        _ recorder: Recorder, clipboardSucceeds: Bool = true,
        store: SessionDisplayOwnershipStore = .init(), supportsImagePaste: Bool = true,
        dispatcher: DelayedDispatcher? = nil
    ) -> TerminalAttachCoordinator {
        let coordinator = TerminalAttachCoordinator(
            sessionName: "image-pane", clientID: DisplayClientID("phone"), defaultKind: .ios,
            ownershipStore: store, broadcaster: DisplayOwnershipBroadcaster(store: store),
            sendText: { text in
                if case .imagePaste(.result(_, let error)) = try? WebControlEnvelope.parse(Data(text.utf8)) {
                    recorder.record(error == nil ? "success" : "error")
                }
            }, resize: { _ in },
            write: { data in recorder.record(data == Data([0x16]) ? "ctrl-v" : "unexpected-input") },
            supportsImagePaste: supportsImagePaste,
            pasteImage: { _ in
                recorder.record("clipboard")
                return clipboardSucceeds
            },
            dispatchImageCommit: { action in
                if let dispatcher { dispatcher.schedule(action) } else { action() }
            }
        )
        coordinator.handleControl(.hello(clientID: DisplayClientID("phone"), kind: .ios,
            role: .interactive, visible: true, cols: 80, rows: 24))
        coordinator.handleControl(.takeControl(clientID: DisplayClientID("phone"), kind: .ios, cols: 80, rows: 24))
        return coordinator
    }

    private func upload(to coordinator: TerminalAttachCoordinator) {
        let id = UUID()
        coordinator.handleControl(.imagePaste(.begin(id: id, byteCount: 3)))
        coordinator.handleControl(.imagePaste(.chunk(id: id, offset: 0, data: Data([1, 2, 3]))))
        coordinator.handleControl(.imagePaste(.commit(id: id)))
    }

    @Test("""
    @spec IOS-11.17: When an image upload completes for the controlling client, the host shall write the image to its clipboard before sending Ctrl+V to that client's attached pane, without sending Enter or restoring the clipboard.
    """)
    func clipboardBeforeKeystroke() async {
        let recorder = Recorder()
        let coordinator = make(recorder)
        upload(to: coordinator)
        for _ in 0..<100 where recorder.snapshot.count < 3 { await Task.yield() }
        #expect(recorder.snapshot == ["clipboard", "ctrl-v", "success"])
    }

    @Test("""
    @spec IOS-11.18: If the host cannot write a clipboard image or the originating attachment loses control or disconnects, then the application shall report failure and shall not send Ctrl+V.
    """)
    func failureDoesNotSendKeystroke() async {
        let recorder = Recorder()
        let coordinator = make(recorder, clipboardSucceeds: false)
        upload(to: coordinator)
        for _ in 0..<100 where recorder.snapshot.count < 2 { await Task.yield() }
        #expect(recorder.snapshot == ["clipboard", "error"])
    }

    @Test
    func disconnectedUploadDoesNotTouchClipboard() async {
        let recorder = Recorder()
        let coordinator = make(recorder)
        upload(to: coordinator)
        coordinator.detach()
        for _ in 0..<100 { await Task.yield() }
        #expect(!recorder.snapshot.contains("clipboard"))
        #expect(!recorder.snapshot.contains("ctrl-v"))
    }

    @Test
    func ownershipLossBeforeClipboardWriteRejectsPaste() async {
        let recorder = Recorder()
        let store = SessionDisplayOwnershipStore()
        let coordinator = make(recorder, store: store)
        upload(to: coordinator)
        _ = store.detachClient(sessionName: "image-pane", clientID: DisplayClientID("phone"), fallbackGrid: .daemonFallback)
        for _ in 0..<100 { await Task.yield() }
        #expect(recorder.snapshot == ["error"])
    }

    @Test
    func ownershipLossBeforeInputEnqueueRejectsPaste() async {
        let recorder = Recorder()
        let store = SessionDisplayOwnershipStore()
        let dispatcher = DelayedDispatcher()
        let coordinator = make(recorder, store: store, dispatcher: dispatcher)
        upload(to: coordinator)
        for _ in 0..<100 where recorder.snapshot.isEmpty { await Task.yield() }
        #expect(recorder.snapshot == ["clipboard"])
        _ = store.detachClient(sessionName: "image-pane", clientID: DisplayClientID("phone"), fallbackGrid: .daemonFallback)
        dispatcher.run()
        #expect(recorder.snapshot == ["clipboard", "error"])
    }

    @Test
    func disconnectedAttachmentBeforeInputEnqueueRejectsPaste() async {
        let recorder = Recorder()
        let dispatcher = DelayedDispatcher()
        let coordinator = make(recorder, dispatcher: dispatcher)
        upload(to: coordinator)
        for _ in 0..<100 where recorder.snapshot.isEmpty { await Task.yield() }
        #expect(recorder.snapshot == ["clipboard"])
        coordinator.detach()
        dispatcher.run()
        #expect(recorder.snapshot == ["clipboard", "error"])
    }

    @Test
    func acknowledgesOnlyAfterInputEnqueue() async {
        let recorder = Recorder()
        let dispatcher = DelayedDispatcher()
        let coordinator = make(recorder, dispatcher: dispatcher)
        upload(to: coordinator)
        for _ in 0..<100 where recorder.snapshot.isEmpty { await Task.yield() }
        #expect(recorder.snapshot == ["clipboard"])
        dispatcher.run()
        #expect(recorder.snapshot == ["clipboard", "ctrl-v", "success"])
    }

    @Test
    func relayedSessionRejectsClipboardMutation() async {
        let recorder = Recorder()
        let coordinator = make(recorder, supportsImagePaste: false)
        upload(to: coordinator)
        for _ in 0..<100 { await Task.yield() }
        #expect(!recorder.snapshot.contains("clipboard"))
        #expect(!recorder.snapshot.contains("ctrl-v"))
    }

    @Test
    func nativeClipboardContainsReadableImageAndRejectsInvalidData() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32
        ))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(HostImagePasteboard.write(png, to: pasteboard))
        #expect(NSImage(pasteboard: pasteboard) != nil)
        #expect(pasteboard.data(forType: .tiff) != nil)
        let changeCount = pasteboard.changeCount
        #expect(!HostImagePasteboard.write(Data([1, 2, 3]), to: pasteboard))
        #expect(pasteboard.changeCount == changeCount)
    }
}

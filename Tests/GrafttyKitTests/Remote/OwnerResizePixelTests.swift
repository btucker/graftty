import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

@Suite("@spec REMOTE-9.12: When the host receives an owner resize carrying pixel dimensions, the application shall apply them to the attached PTY together with the grid, and shall treat absent or invalid pixel fields as unspecified so older clients keep grid-only behavior.")
struct OwnerResizePixelTests {
    private let client = DisplayClientID("phone")

    @Test func encodesPixelsOnlyWhenSpecified() throws {
        let withPixels = WebControlEnvelope.ownerResize(
            clientID: client, epoch: 3, cols: 50, rows: 40, xpixel: 1150, ypixel: 1880
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(withPixels.encoded().utf8)) as? [String: Any]
        )
        #expect(json["xpixel"] as? Int == 1150)
        #expect(json["ypixel"] as? Int == 1880)
        #expect(try WebControlEnvelope.parse(Data(withPixels.encoded().utf8)) == withPixels)

        // A grid-only resize keeps the exact pre-pixel wire shape.
        let gridOnly = WebControlEnvelope.ownerResize(clientID: client, epoch: 3, cols: 50, rows: 40)
        #expect(gridOnly.encoded() == #"{"clientID":"phone","cols":50,"epoch":3,"rows":40,"type":"ownerResize"}"#)
    }

    @Test func legacyJSONWithoutPixelsParsesAsUnspecified() throws {
        let legacy = #"{"clientID":"phone","cols":80,"epoch":2,"rows":24,"type":"ownerResize"}"#
        let parsed = try WebControlEnvelope.parse(Data(legacy.utf8))
        #expect(parsed == .ownerResize(clientID: client, epoch: 2, cols: 80, rows: 24, xpixel: 0, ypixel: 0))
    }

    @Test(arguments: [
        #""xpixel":-5,"ypixel":900"#,
        #""xpixel":"wide","ypixel":900"#,
        #""xpixel":70000,"ypixel":900"#,
        #""xpixel":true,"ypixel":900"#,
        #""xpixel":12.5,"ypixel":900"#,
        #""xpixel":null,"ypixel":900"#,
    ])
    func invalidPixelFieldsParseAsUnspecified(fields: String) throws {
        let json = #"{"clientID":"phone","cols":80,"epoch":2,"rows":24,"type":"ownerResize","#
            + fields + "}"
        let parsed = try WebControlEnvelope.parse(Data(json.utf8))
        guard case let .ownerResize(_, _, cols, rows, xpixel, ypixel) = parsed else {
            Issue.record("expected ownerResize, got \(parsed)")
            return
        }
        #expect(cols == 80 && rows == 24)
        #expect(xpixel == 0)
        #expect(ypixel == 900)
    }

    @Test func coordinatorAppliesOwnerResizePixelsToPTY() throws {
        let store = SessionDisplayOwnershipStore()
        let recorder = WindowSizeRecorder()
        let coordinator = TerminalAttachCoordinator(
            sessionName: "main",
            clientID: DisplayClientID("server-phone"),
            defaultKind: .ios,
            ownershipStore: store,
            broadcaster: DisplayOwnershipBroadcaster(),
            sendText: { _ in },
            resize: { recorder.record($0) },
            write: { _ in }
        )
        coordinator.handleControl(.hello(
            clientID: client, kind: .ios, role: .interactive, visible: true, cols: 80, rows: 24
        ))
        coordinator.handleControl(.takeControl(clientID: client, kind: .ios, cols: 80, rows: 24))
        let epoch = store.snapshot(sessionName: "main").epoch

        coordinator.handleControl(.ownerResize(
            clientID: client, epoch: epoch, cols: 50, rows: 40, xpixel: 1150, ypixel: 1880
        ))
        // Same grid, new pixel size (e.g. a font-size change) still flows.
        coordinator.handleControl(.ownerResize(
            clientID: client, epoch: epoch, cols: 50, rows: 40, xpixel: 1000, ypixel: 1600
        ))
        // An older client's grid-only resize stays grid-only.
        coordinator.handleControl(.ownerResize(clientID: client, epoch: epoch, cols: 60, rows: 30))

        #expect(recorder.sizes == [
            PtyProcess.WindowSize(cols: 80, rows: 24),
            PtyProcess.WindowSize(cols: 50, rows: 40, xpixel: 1150, ypixel: 1880),
            PtyProcess.WindowSize(cols: 50, rows: 40, xpixel: 1000, ypixel: 1600),
            PtyProcess.WindowSize(cols: 60, rows: 30),
        ])
    }

    private final class WindowSizeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _sizes: [PtyProcess.WindowSize] = []
        var sizes: [PtyProcess.WindowSize] { lock.withLock { _sizes } }
        func record(_ size: PtyProcess.WindowSize) { lock.withLock { _sizes.append(size) } }
    }
}

import Foundation
import Testing
@testable import GrafttyKit

struct WorktreeSleepWakeTests {
    @Test("@spec SLEEP-14: When a remote terminal requests attachment, the host shall complete wake admission before starting either terminal transport and reject attachment if resume fails.")
    func remoteAdmission() async {
        let registry = RemoteAttachmentRegistry()
        var requested: [String] = []
        let recorder = WakeRecorder()
        registry.wakeBeforeAttach = { session in recorder.record(session); return false }
        let config = ZmxAttachEngine.Config(zmxExecutable: URL(fileURLWithPath: "/nonexistent"),
            zmxDir: URL(fileURLWithPath: "/tmp/nonexistent"), sessionName: "sleep-test")
        let ordinary = ZmxAttachEngine(config: config)
        ordinary.attachmentRegistry = registry
        do { try ordinary.start(); Issue.record("Attachment should reject failed wake admission") }
        catch ZmxAttachEngine.Error.wakeFailed { }
        catch { Issue.record("Unexpected error: \(error)") }
        let paged = PagedZmxAttachEngine(config: config)
        paged.attachmentRegistry = registry
        do { try await paged.start(); Issue.record("Paged attachment should reject failed wake admission") }
        catch PagedZmxAttachEngine.Error.unsupported { }
        catch { Issue.record("Unexpected error: \(error)") }
        requested = recorder.sessions
        #expect(requested == ["sleep-test", "sleep-test"])
        #expect(!registry.isRemoteAttached(sessionName: "sleep-test"))
    }
}

private final class WakeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var sessions: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ session: String) { lock.lock(); defer { lock.unlock() }; recorded.append(session) }
}

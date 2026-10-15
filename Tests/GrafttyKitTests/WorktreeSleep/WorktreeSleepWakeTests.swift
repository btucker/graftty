import Foundation
import Testing
@testable import GrafttyKit

struct WorktreeSleepWakeTests {
    @Test("@spec SLEEP-34: If a terminal closes while wake admission is pending, then the host shall discard delayed input without using its released descriptor or recording new uncommitted bytes.")
    func closeDuringAdmissionRejectsDelayedInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sleep-close-input-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("zmx")
        try "#!/bin/sh\nexec /bin/cat\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let registry = RemoteAttachmentRegistry()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        registry.wakeBeforeInput = { _ in entered.signal(); return release.wait(timeout: .now() + 3) == .success }
        let engine = ZmxAttachEngine(config: .init(zmxExecutable: executable, zmxDir: directory, sessionName: "sleep-test"))
        engine.attachmentRegistry = registry
        let input = ZmxInputState()
        engine.inputState = input
        try engine.start()
        defer { release.signal(); engine.close() }
        DispatchQueue.global().async { engine.write(Data("must-not-write".utf8)); finished.signal() }
        #expect(entered.wait(timeout: .now() + 2) == .success)
        engine.close()
        release.signal()
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(input.uncommittedBytes(forSession: "sleep-test") == 0)
    }

    @Test("@spec SLEEP-33: When an attached remote terminal sends more input, the host shall renew input admission before forwarding bytes, even after a newer shell prompt was observed.")
    func remoteInputAdmissionIsRepeated() async throws {
        let registry = RemoteAttachmentRegistry()
        let recorder = WakeRecorder()
        registry.wakeBeforeInput = { session in recorder.record(session); return recorder.acceptsInput }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sleep-input-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("zmx")
        try "#!/bin/sh\nexec /bin/cat\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let config = ZmxAttachEngine.Config(zmxExecutable: executable, zmxDir: directory, sessionName: "sleep-test")
        let ordinary = ZmxAttachEngine(config: config)
        ordinary.attachmentRegistry = registry
        ordinary.onPTYData = { recorder.receive($0) }
        try ordinary.start()
        defer { ordinary.close() }
        ordinary.write(Data("blocked-one\n".utf8))
        ordinary.write(Data("blocked-two\n".utf8))
        recorder.acceptsInput = true
        ordinary.write(Data("allowed\n".utf8))
        let deadline = Date().addingTimeInterval(2)
        while !recorder.output.contains("allowed") && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(recorder.output.contains("allowed"))
        #expect(!recorder.output.contains("blocked"))
        recorder.acceptsInput = false
        let paged = PagedZmxAttachEngine(config: config)
        paged.attachmentRegistry = registry
        do { try await paged.send(Data("blocked-three".utf8)); Issue.record("Input should reject failed wake admission") }
        catch PagedZmxAttachEngine.Error.closed { }
        #expect(recorder.sessions == Array(repeating: "sleep-test", count: 4))
    }

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
    private var accepted = false
    private var received = Data()
    var acceptsInput: Bool {
        get { lock.lock(); defer { lock.unlock() }; return accepted }
        set { lock.lock(); defer { lock.unlock() }; accepted = newValue }
    }
    var output: String { lock.lock(); defer { lock.unlock() }; return String(decoding: received, as: UTF8.self) }
    func receive(_ data: Data) { lock.lock(); defer { lock.unlock() }; received.append(data) }
    var sessions: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ session: String) { lock.lock(); defer { lock.unlock() }; recorded.append(session) }
}

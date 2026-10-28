import Foundation
import Testing

#if os(macOS)
import Darwin
import XCTest

// The tools ABI is documented by swift-testing/Documentation/ABI. A synchronous
// record callback lets the serial runner pause between suites without racing
// buffered console output. dlsym avoids depending on build-from-source SPI.
private typealias DispatchProbeEntryPoint = @convention(thin) @Sendable (
    UnsafeRawBufferPointer?,
    @escaping @Sendable (UnsafeRawBufferPointer) -> Void
) async throws -> Bool

extension DispatchWorkProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_GCD_PROBE_FILTER"] != nil))
    func runBatch() async throws {
        try #require(Bundle(for: DispatchWorkProbeXCTestTests.self).bundleURL.lastPathComponent == "GrafttyPackageTests.xctest",
                "Use the native SwiftPM build system to retain the CI single-bundle process shape")
        let environment = ProcessInfo.processInfo.environment
        let output = try #require(environment["GRAFTTY_GCD_PROBE_OUTPUT"])
        let pattern = try #require(environment["GRAFTTY_GCD_PROBE_FILTER"])
        let parallel = environment["GRAFTTY_GCD_PROBE_PARALLEL"] == "1"
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swt_abiv0_getEntryPoint"))
        let getter = unsafeBitCast(symbol, to: (@convention(c) () -> UnsafeRawPointer).self)
        let entry = unsafeBitCast(getter(), to: DispatchProbeEntryPoint.self)
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let state = DispatchWorkProbeState(output: output,
            script: repository.appendingPathComponent("scripts/ci/gcd_probe.py").path, sampleRunEnd: parallel)
        let configuration = try JSONSerialization.data(withJSONObject: [
            "parallel": parallel, "filter": [pattern], "eventStreamVersion": 0,
            "skip": [environment["GRAFTTY_GCD_PROBE_SELF_CHECK"] == "1"
                ? "^(?:GrafttyKitTests\\.)?DispatchWorkProbeTests(/|$)"
                : "^(?:GrafttyKitTests\\.)?DispatchWorkProbe(?:Tests|Fixture)(/|$)"],
            "xunitOutput": output + "/results.xml",
        ])
        // Allocate stable storage across the asynchronous ABI call.
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: configuration.count, alignment: 1)
        defer { buffer.deallocate() }
        configuration.copyBytes(to: buffer)
        defer { DispatchWorkProbeFixture.gate.signal() }
        let passed = try await entry(UnsafeRawBufferPointer(buffer)) { record in
            state.receive(Data(record))
        }
        if environment["GRAFTTY_GCD_PROBE_SELF_CHECK"] == "1" {
            #expect(DispatchWorkProbeFixture.releaseAndWait())
            try state.sampleReleasedFixture()
        }
        #expect(passed)
        #expect(state.errors.isEmpty, "\(state.errors)")
    }
}

final class DispatchWorkProbeState: @unchecked Sendable {
    // The event handler can receive discovery records from multiple threads.
    // Locking also serializes samples and preserves the observed suite order.
    private let lock = NSLock()
    private var suites: Set<String> = []
    private var sequence = 0
    private var failures: [String] = []
    private let output: String
    private let script: String
    private let sampleRunEnd: Bool

    init(output: String, script: String, sampleRunEnd: Bool = false) {
        self.output = output
        self.script = script
        self.sampleRunEnd = sampleRunEnd
    }

    var errors: [String] { lock.withLock { failures } }

    func sampleReleasedFixture() throws {
        try lock.withLock { try sample(suite: "<released fixture>", phase: "released") }
    }

    func receive(_ data: Data) {
        lock.withLock {
            do {
                guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ProbeError.failure("Invalid event record")
                }
                let events = output + "/events.jsonl"
                let fd = open(events, O_WRONLY | O_CREAT | O_APPEND, 0o600)
                guard fd >= 0 else { throw ProbeError.failure("Cannot open event evidence") }
                defer { close(fd) }
                let line = data + Data([10])
                let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                guard written == line.count else { throw ProbeError.failure("Cannot write event evidence") }
                guard let payload = record["payload"] as? [String: Any] else {
                    throw ProbeError.failure("Missing event payload")
                }
                let kind = payload["kind"] as? String
                if record["kind"] as? String == "test", kind == "suite", let id = payload["id"] as? String {
                    suites.insert(id)
                } else if record["kind"] as? String == "event" {
                    if kind == "runStarted" {
                        try sample(suite: "<baseline>", phase: "before")
                    } else if kind == "testEnded", let id = payload["testID"] as? String, suites.contains(id) {
                        try sample(suite: id, phase: "after")
                    } else if kind == "runEnded", sampleRunEnd {
                        try sample(suite: "<run ended>", phase: "finished")
                    }
                }
            } catch {
                failures.append(String(describing: error))
            }
        }
    }

    private func sample(suite: String, phase: String) throws {
        sequence += 1
        let arguments = ["/usr/bin/env", "python3", "-B", script, "snapshot", String(getpid()), output, suite, phase, String(sequence)]
        try Self.runChild(arguments, timeout: .seconds(30))
    }

    static func runChild(_ arguments: [String], timeout: Duration) throws {
        let allocated = arguments.map { strdup($0) }
        let allocatedEnvironment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) }
        defer {
            allocated.forEach { free($0) }
            allocatedEnvironment.forEach { free($0) }
        }
        var argv = allocated + [nil]
        var envp = allocatedEnvironment + [nil]
        var child: pid_t = 0
        let spawned = argv.withUnsafeMutableBufferPointer {
            argv in envp.withUnsafeMutableBufferPointer {
                posix_spawn(&child, "/usr/bin/env", nil, nil, argv.baseAddress!, $0.baseAddress!)
            }
        }
        guard spawned == 0 else { throw ProbeError.failure("Child spawn failed: \(spawned)") }
        let deadline = ContinuousClock.now + timeout
        var status: Int32 = 0
        while true {
            let waited = waitpid(child, &status, WNOHANG)
            if waited == child { break }
            if waited < 0, errno != EINTR { throw ProbeError.failure("Child wait failed: \(errno)") }
            if ContinuousClock.now >= deadline {
                kill(child, SIGKILL)
                while waitpid(child, &status, 0) < 0 && errno == EINTR { }
                throw ProbeError.failure("Child exceeded \(timeout)")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard status == 0 else { throw ProbeError.failure("Child failed: wait status \(status)") }
    }

    private enum ProbeError: Error { case failure(String) }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_GCD_PROBE_SELF_CHECK"] == "1"))
private struct DispatchWorkProbeFixture {
    static let gate = DispatchSemaphore(value: 0)
    static let finished = DispatchSemaphore(value: 0)

    static func releaseAndWait() -> Bool {
        gate.signal()
        return finished.wait(timeout: .now() + 5) == .success
    }

    @Test
    func leavesOneBlockedWorkerForTheObserver() throws {
        let started = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            // A failed diagnostic must still let this owned worker exit.
            _ = Self.gate.wait(timeout: .now() + 120)
            Self.finished.signal()
        }
        #expect(started.wait(timeout: .now() + 5) == .success)
    }
}

// CI runs each XCTest target in its own process after the Swift Testing
// batches. The opt-in driver recreates that target suite and attaches a
// synchronous observer, retaining setUp/tearDown and the normal class order.
final class DispatchWorkProbeXCTestTests: XCTestCase {
    @MainActor
    func testRunTarget() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let encoded = environment["GRAFTTY_GCD_PROBE_XCTEST_CLASSES"] else {
            throw XCTSkip("Opt-in dispatch diagnostic")
        }
        let classes = try JSONDecoder().decode([String].self, from: Data(encoded.utf8))
        let output = try XCTUnwrap(environment["GRAFTTY_GCD_PROBE_OUTPUT"])
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let state = DispatchWorkProbeState(output: output, script: repository.appendingPathComponent("scripts/ci/gcd_probe.py").path)
        let observer = DispatchWorkProbeXCTestObserver(state: state)
        let suite = XCTestSuite(name: "Dispatch diagnostic target")
        for name in classes {
            let type = try XCTUnwrap(NSClassFromString(name) as? XCTestCase.Type, "Cannot resolve XCTest class \(name)")
            suite.addTest(XCTestSuite(forTestCaseClass: type))
        }
        XCTestObservationCenter.shared.addTestObserver(observer)
        defer { XCTestObservationCenter.shared.removeTestObserver(observer) }
        observer.snapshot(suite: "<baseline>", phase: "before")
        suite.run()
        XCTAssertEqual(suite.testRun?.totalFailureCount, 0)
        XCTAssertTrue(state.errors.isEmpty, "\(state.errors)")
    }
}

private final class DispatchWorkProbeXCTestObserver: NSObject, XCTestObservation {
    let state: DispatchWorkProbeState
    init(state: DispatchWorkProbeState) { self.state = state }

    func snapshot(suite: String, phase: String) {
        // Feed the same boundary handler used by Swift Testing.
        let test: [String: Any] = ["kind": "test", "payload": ["kind": "suite", "id": suite]]
        let event: [String: Any] = ["kind": "event", "payload": ["kind": phase == "before" ? "runStarted" : "testEnded", "testID": suite]]
        for record in [test, event] {
            do { state.receive(try JSONSerialization.data(withJSONObject: record)) }
            catch { XCTFail("Cannot encode XCTest boundary: \(error)") }
        }
    }

    func testSuiteDidFinish(_ testSuite: XCTestSuite) {
        if testSuite.name != "Dispatch diagnostic target" {
            snapshot(suite: testSuite.name, phase: "after")
        }
    }
}
#endif

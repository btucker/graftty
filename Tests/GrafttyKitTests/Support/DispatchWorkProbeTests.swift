import Foundation
import Testing

@Suite("@spec TECH-6.6: When the macOS dispatch diagnostic runs a CI capture, the tool shall require the paging renderer configuration, apply CI skip conditions, and preserve CI process order through the final parallel ownership gate.")
struct DispatchWorkProbeTests {
    @Test("@spec TECH-6.5: When the macOS dispatch diagnostic samples a completed suite, the tool shall report blocked dispatch workers separately from idle workers, unclassified workers, and dedicated threads, retain raw stacks and suite order, and reject missing suite samples.")
    func verifiesDiagnostic() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        #if os(macOS)
        try DispatchWorkProbeState.runChild(["/usr/bin/env", "python3", "-B",
            repository.appendingPathComponent("scripts/ci/test_gcd_probe.py").path], timeout: .seconds(15))
        #else
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["python3", "-B", repository.appendingPathComponent("scripts/ci/test_gcd_probe.py").path]
        try child.run()
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        #endif
    }
}

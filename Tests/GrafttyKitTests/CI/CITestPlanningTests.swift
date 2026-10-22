import Foundation
import Testing

struct CITestPlanningTests {
    @Test("@spec TECH-6.3: When CI partitions Swift tests, the workflow shall select every discovered non-ownership test exactly once, preserve the separate ownership corpus gate, and reject an empty discovery result.")
    func partitionsDiscoveredTestsWithoutSubstringMatches() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-B", repository.appendingPathComponent("scripts/ci/test_test_plan.py").path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

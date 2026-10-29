import Foundation
import Testing

@Suite("Native snapshot link clicks")
struct NativeLinkClickTests {
    @Test("""
    @spec EDITOR-1.10: When a native terminal restores a snapshot containing an OSC 7 working-directory URI, the application shall resolve local relative file links without aborting, preserve absolute and OSC8 link activation, and remain usable after repeated restoration.
    """, .enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_LINK_CLICK_TEST_DIR"] != nil))
    func restoredWorkingDirectoryLinks() throws {
        let artifacts = try #require(ProcessInfo.processInfo.environment["GRAFTTY_LINK_CLICK_TEST_DIR"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [artifacts + "/test-link-clicks.py",
                             artifacts + "/link-click-probe", artifacts + "/make-link-fixture"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
    }
}

import XCTest
@testable import GrafttyKit

final class ShellEnvProbeTests: XCTestCase {
    func test_parseValueOutputDropsGhosttyOSCWhenEditorUnset() {
        let raw = "\u{1B}]1337;RemoteHost=btucker@m4-mbp.localdomain\u{07}\u{1B}]1337;CurrentDir=/\u{07}\u{1B}]1337;ShellIntegrationVersion=14;shell=zsh\u{07}\n"

        XCTAssertNil(LoginShellEnvProbe.parseValueOutput(Data(raw.utf8)))
    }

    func test_parseValueOutputDropsVisibleGhosttyOSCLeakWhenControlBytesAreMissing() {
        let raw = "]1337;RemoteHost=btucker@m4-mbp.localdomain]1337;CurrentDir=/]1337;ShellIntegrationVersion=14;shell=zsh\n"

        XCTAssertNil(LoginShellEnvProbe.parseValueOutput(Data(raw.utf8)))
    }

    func test_parseValueOutputKeepsEditorSurroundedByGhosttyOSC() {
        let raw = "\u{1B}]1337;RemoteHost=btucker@m4-mbp.localdomain\u{07}nvim\n\u{1B}]1337;CurrentDir=/\u{07}"

        XCTAssertEqual(LoginShellEnvProbe.parseValueOutput(Data(raw.utf8)), "nvim")
    }
}

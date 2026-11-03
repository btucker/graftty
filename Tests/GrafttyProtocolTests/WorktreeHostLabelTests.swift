import Testing
@testable import GrafttyProtocol

@Suite("@spec LAYOUT-2.207: While a worktree is open, the application shall name its host when it's remote, and name this Mac only when the project also lives on another host.")
struct WorktreeHostLabelTests {
    @Test func remoteAlwaysShowsHost() {
        #expect(WorktreeHostLabel.text(isLocal: false, hostLabel: "build-box", projectIsOnSeveralHosts: false) == "build-box")
        #expect(WorktreeHostLabel.text(isLocal: false, hostLabel: "build-box", projectIsOnSeveralHosts: true) == "build-box")
    }
    @Test func localShowsThisMacOnlyWhenMultiHost() {
        #expect(WorktreeHostLabel.text(isLocal: true, hostLabel: "MacBook", projectIsOnSeveralHosts: false) == nil)
        #expect(WorktreeHostLabel.text(isLocal: true, hostLabel: "MacBook", projectIsOnSeveralHosts: true) == "This Mac")
    }
}

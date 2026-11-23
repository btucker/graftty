import Testing
@testable import GrafttyRunner

struct RunnerCommandNameTests {
    @Test("@spec DIST-4.14: The Linux runner executable shall name itself graftty-runner in its usage text.")
    func usageNamesTheRunner() {
        let help = GrafttyRunnerCommand.helpMessage()
        #expect(help.contains("graftty-runner"))
        #expect(!help.contains("graftty-host"))
    }
}

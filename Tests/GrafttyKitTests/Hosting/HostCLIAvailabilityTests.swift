import Testing
import Foundation
@testable import GrafttyKit

@Suite("HostCLIAvailability — provider metadata")
struct HostCLIAvailabilityMetadataTests {
    @Test func githubMetadata() {
        let m = HostCLIAvailability.metadata(for: .github)
        #expect(m?.cli == "gh")
        #expect(m?.displayName == "GitHub")
        #expect(m?.prTerm == "pull request")
        #expect(m?.brewCommand == "brew install gh")
        #expect(m?.installURL.absoluteString == "https://cli.github.com")
    }

    @Test func gitlabMetadata() {
        let m = HostCLIAvailability.metadata(for: .gitlab)
        #expect(m?.cli == "glab")
        #expect(m?.displayName == "GitLab")
        #expect(m?.prTerm == "merge request")
        #expect(m?.brewCommand == "brew install glab")
        #expect(m?.installURL.absoluteString == "https://gitlab.com/gitlab-org/cli#installation")
    }

    @Test func unsupportedHasNoMetadata() {
        #expect(HostCLIAvailability.metadata(for: .unsupported) == nil)
    }
}

@Suite("HostCLIAvailability.isAvailable — notFound is the only 'missing' signal")
struct HostCLIAvailabilityProbeTests {
    @Test func reportsAvailableWhenBinarySucceeds() async {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: ["--version"],
            output: CLIOutput(stdout: "gh version 2.50.0\n", stderr: "", exitCode: 0)
        )
        let available = await HostCLIAvailability.isAvailable(command: "gh", executor: fake)
        #expect(available == true)
    }

    @Test func reportsUnavailableOnNotFound() async {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: ["--version"],
            error: .notFound(command: "gh")
        )
        let available = await HostCLIAvailability.isAvailable(command: "gh", executor: fake)
        #expect(available == false)
    }

    @Test func reportsAvailableOnNonZeroExit() async {
        // A present-but-failing binary (e.g. a wrapper that errors when
        // not authenticated) is still "installed" — the nudge addresses
        // missing-binary only.
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: ["--version"],
            output: CLIOutput(stdout: "", stderr: "boom", exitCode: 1)
        )
        let available = await HostCLIAvailability.isAvailable(command: "gh", executor: fake)
        #expect(available == true)
    }

    @Test func reportsAvailableOnLaunchFailure() async {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: ["--version"],
            error: .launchFailed(command: "gh", message: "permission denied")
        )
        let available = await HostCLIAvailability.isAvailable(command: "gh", executor: fake)
        #expect(available == true)
    }

    @Test func usesProvidedCommandName() async {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "glab",
            args: ["--version"],
            error: .notFound(command: "glab")
        )
        let available = await HostCLIAvailability.isAvailable(command: "glab", executor: fake)
        #expect(available == false)
    }
}

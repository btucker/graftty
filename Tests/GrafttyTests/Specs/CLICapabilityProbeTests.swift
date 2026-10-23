import ArgumentParser
import Testing
import GrafttyKit
@testable import GrafttyCLI

@Suite("@spec ATTN-1.30: When a CLI command needs app capabilities, the CLI shall check all of them with one `capabilities` request, and if the running app answers that request with anything other than a capability list, then the CLI shall fall back to the single-capability probes that older apps answer.")
struct CLICapabilityProbeTests {
    @Test func oneRequestCoversEveryNeededCapability() throws {
        let command = try WorktreeAdd.parse(["fix", "--remote", "Studio", "--agent", "codex", "--base", "main"])
        #expect(command.requiredCapabilities == [.remoteWorktree, .worktreeCreateIdempotency, .agentPromptStaging,
                                                 .worktreeBase])
        var probes: [NotificationMessage] = []
        try CapabilityProbe.require(command.requiredCapabilities, send: {
            probes.append($0)
            // A newer app may list names this CLI does not know.
            return .capabilities(ControlCapability.allCases.map(\.rawValue) + ["from_the_future"])
        })
        #expect(probes == [.capabilities])
    }

    @Test func aMissingCapabilityFailsWithoutFurtherProbes() {
        var probes: [NotificationMessage] = []
        #expect(throws: ExitCode(1)) {
            try CapabilityProbe.require([.worktreeCreateIdempotency, .worktreeBase], send: {
                probes.append($0)
                return .capabilities(["worktree_create_idempotency"])
            })
        }
        #expect(probes == [.capabilities])
    }

    @Test func anOlderAppIsProbedOneCapabilityAtATime() throws {
        var probes: [NotificationMessage] = []
        try CapabilityProbe.require([.remoteWorktree, .worktreeCreateIdempotency], send: { request in
            probes.append(request)
            // Apps before ATTN-2.27 drop the unknown request without answering.
            if request == .capabilities { throw CLIError.socketClosedWithoutResponse }
            return .ok
        })
        #expect(probes == [.capabilities, .remoteWorktreeCapability, .worktreeCreateIdempotencyCapability])
    }
}

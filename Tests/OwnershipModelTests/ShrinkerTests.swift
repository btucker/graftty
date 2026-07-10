import Testing
import GrafttyProtocol

@Suite("Shrinker")
struct ShrinkerTests {
    @Test func reducesToMinimalReproducingTrace() {
        // A planted violation: "any trace containing a release of c7".
        let shrunk = shrinkWithPredicate(seed: 3, opCount: 50) { ops in
            ops.contains { if case let .release(id) = $0, id == DisplayClientID("c7") { return true }; return false }
        }
        #expect(shrunk != nil)
        #expect(shrunk!.ops.count == 1)
        if case let .release(id) = shrunk!.ops[0] { #expect(id == DisplayClientID("c7")) } else { Issue.record("wrong op") }
    }

    @Test func s5RegressionTestUsesReplayWebOps() {
        // Verify that asRegressionTest() for an S5 violation emits a test that
        // uses replayWebOps (exercising followers) rather than StoreWorld (which
        // only checks S1–S4 and would silently pass for an S5 violation).
        let webOps: [WebControlEnvelope] = [
            .hello(clientID: DisplayClientID("web-a"), kind: .web, role: .interactive,
                   visible: true, cols: 80, rows: 24),
        ]
        let shrunk = ShrunkFailure(
            ops: [.hello(DisplayClientID("web-a"))],
            webOps: webOps,
            schedule: [0],
            violation: .s5SupersededApplied(
                target: DisplayClientID("follower-0"), applied: 1, highest: 2
            ),
            transcript: []
        )
        let emitted = shrunk.asRegressionTest()
        #expect(emitted.contains("replayWebOps"))
        #expect(!emitted.contains("StoreWorld"))
        #expect(emitted.contains("import Testing"))
        #expect(emitted.contains("import GrafttyProtocol"))
        #expect(emitted.contains("@testable import GrafttyKit"))
    }

    @Test func interleavingDependentS5EmitsDisabledTest() {
        // When webOps is nil (interleaving-dependent), asRegressionTest() must
        // emit a .disabled test rather than a green no-op.
        let shrunk = ShrunkFailure(
            ops: [.hello(DisplayClientID("web-a"))],
            webOps: nil,
            schedule: [0],
            violation: .s5SupersededApplied(
                target: DisplayClientID("follower-0"), applied: 1, highest: 2
            ),
            transcript: []
        )
        let emitted = shrunk.asRegressionTest()
        #expect(emitted.contains(".disabled("))
        #expect(!emitted.contains("replayWebOps"))
        #expect(!emitted.contains("StoreWorld"))
    }
}

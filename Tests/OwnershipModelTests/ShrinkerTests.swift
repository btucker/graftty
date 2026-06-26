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
}

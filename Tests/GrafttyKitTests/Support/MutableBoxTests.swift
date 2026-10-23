import Testing
import GrafttyTestSupport

@Suite("MutableBox")
struct MutableBoxTests {
    @Test("Concurrent read-modify-writes through withValue lose no updates")
    func concurrentIncrementsLoseNoUpdates() async {
        let box = MutableBox(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<2_000 { box.withValue { $0 += 1 } }
                }
            }
        }
        #expect(box.value == 16_000)
    }
}

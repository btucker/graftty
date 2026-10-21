import Foundation
import Testing
@testable import GrafttyKit

@Suite("Legacy terminal output queue", .timeLimit(.minutes(1)))
struct TerminalOutputBufferTests {
    @Test func blockingProducerResumesWithoutLossWhenConsumerDrains() async {
        let queue = TerminalOutputBuffer(byteLimit: 8, frameLimit: 2)
        let finished = LockedFlag()
        let producer = Thread {
            for value in UInt8(0)..<64 {
                guard queue.append(Data(repeating: value, count: 4)) else { return }
            }
            queue.finish()
            finished.set()
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { queue.finish(discard: true) }
        }
        defer { watchdog.cancel(); queue.finish(discard: true) }
        producer.start()
        var result = [UInt8]()
        while let chunk = await queue.next() { result.append(contentsOf: chunk) }
        #expect(result == (UInt8(0)..<64).flatMap { Array(repeating: $0, count: 4) })
        // EOF is published just before the producer's final marker.
        let deadline = ContinuousClock.now + .seconds(1)
        while !finished.value && ContinuousClock.now < deadline { await Task.yield() }
        #expect(finished.value)
    }

    @Test func discardWakesBlockedProducerAndReleasesData() async {
        let queue = TerminalOutputBuffer(byteLimit: 4, frameLimit: 1)
        #expect(queue.append(Data([1, 2, 3, 4])))
        let returned = LockedFlag()
        let producer = Thread {
            #expect(!queue.append(Data([5])))
            returned.set()
        }
        producer.start()
        queue.finish(discard: true)
        #expect(await queue.next() == nil)
        let deadline = ContinuousClock.now + .seconds(1)
        while !returned.value && ContinuousClock.now < deadline { await Task.yield() }
        #expect(returned.value)
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.withLock { flag } }
        func set() { lock.withLock { flag = true } }
    }
}

import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

@MainActor
struct InMemoryTerminalRetirementTests {
    @Test("A split packet retires its sequence only after its last chunk, before a following exit")
    func chunkedPacketKeepsItsSequence() {
        var operations = InMemoryTerminalPendingOperations()
        let packet = Data(repeating: 65, count: 65 * 4096 + 1)
        operations.append(.write(packet))
        operations.append(.processExit(exitCode: 7, runtimeMilliseconds: 0))
        var delivered = Data()
        for _ in 0..<65 {
            guard case let .write(chunk)? = operations.popFirst(maximumWriteSize: 4096) else {
                Issue.record("expected a write chunk before process exit")
                return
            }
            delivered.append(chunk)
            #expect(chunk.count == 4096)
            #expect(operations.count == 2)
            #expect(operations.retiredSequence == 0)
            #expect(operations.writeByteCount == packet.count - delivered.count)
        }
        guard case let .write(tail)? = operations.popFirst(maximumWriteSize: 4096) else {
            Issue.record("expected the final packet byte")
            return
        }
        delivered.append(tail)
        #expect(delivered == packet)
        #expect(operations.retiredSequence == 1)
        #expect(operations.count == 1)
        #expect(operations.writeByteCount == 0)
        guard case let .processExit(code, _)? = operations.popFirst() else {
            Issue.record("expected process exit after the full packet")
            return
        }
        #expect(code == 7)
        #expect(operations.retiredSequence == 2)
        #expect(operations.isEmpty)
    }

    @Test("A stale owner joins its active writer during a reentrant replacement")
    func staleOwnerJoinsItsWriter() {
        let started = DispatchSemaphore(value: 0)
        let space = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let accessHolder = TeardownValues<InMemoryTerminalSurfaceAccess>()
        let ticks = TeardownValues<Bool>()
        let access = InMemoryTerminalSurfaceAccess(
            write: { _, _ in
                started.signal()
                space.wait()
                finished.signal()
            },
            processExit: { _, _, _ in },
            tick: { _ in
                if ticks.values.isEmpty {
                    ticks.append(true)
                    let access = accessHolder.values[0]
                    #expect(!access.clearSurface(ifMatches: UnsafeMutableRawPointer(bitPattern: 1)!))
                    #expect(finished.wait(timeout: .now()) == .success)
                }
                space.signal()
            }
        )
        accessHolder.append(access)
        defer { accessHolder.removeAll() }
        access.setSurface(UnsafeMutableRawPointer(bitPattern: 1)!)
        access.enqueueWrite(Data("active".utf8))
        #expect(started.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { space.signal() }
        access.setSurface(UnsafeMutableRawPointer(bitPattern: 2)!)
        #expect(access.currentSurface == UnsafeMutableRawPointer(bitPattern: 2)!)
        access.waitForPendingOutput()
    }
}

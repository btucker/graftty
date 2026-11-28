import Foundation
import GrafttyTailcat
import Testing

@Suite("Runner Tailcat link")
struct RunnerTailcatLinkTests {
    @Test("@spec REMOTE-33.1: When the runner is built for Linux, the application shall carry a Tailcat byte stream between a server and a client peer in the runner process.",
          .timeLimit(.minutes(2)))
    func carriesBytesBetweenPeers() async throws {
        let server = try TailcatPeer.server(identity: .generate())
        let listener = try await server.listen(port: 8801)
        let client = try TailcatPeer.client(address: try await server.address())
        async let accepted = listener.accept()
        let dialed = try await client.dial(port: 8801)
        let inbound = try await accepted
        if ProcessInfo.processInfo.environment["GRAFTTY_TAILCAT_REQUIRE_RELAY"] == "1" {
            #expect(try await client.routeKind() == "relay")
        }
        let payload = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let reader = Task.detached { () throws -> Data in
            var received = Data()
            while received.count < payload.count,
                  let chunk = try inbound.file.read(upToCount: 64 * 1024), !chunk.isEmpty {
                received.append(chunk)
            }
            return received
        }
        try dialed.file.write(contentsOf: payload)
        #expect(try await reader.value == payload)
        await dialed.close()
        await inbound.close()
        await client.close()
        await server.close()
    }
}

import Darwin
import Foundation

enum TailcatDeviceCheck {
    struct Result {
        let byteCount: Int
        let route: String
        let elapsed: Duration
    }

    static func run() async throws -> Result {
        let server = try TailcatPeer.server()
        do {
            let listener = try await server.listen(port: 8801)
            let client = try await TailcatPeer.client(address: server.address())
            do {
                async let acceptance = listener.accept()
                let outgoing = try await client.dial(port: 8801)
                let incoming = try await acceptance
                let route = try await client.routeKind()
                let payload = Data((0..<1024).map { UInt8(truncatingIfNeeded: $0) })
                let start = ContinuousClock.now
                try outgoing.file.write(contentsOf: payload)
                let request = try readExactly(payload.count, from: incoming.file)
                try incoming.file.write(contentsOf: request)
                guard try readExactly(payload.count, from: outgoing.file) == payload else {
                    throw POSIXError(.EBADMSG)
                }
                let elapsed = start.duration(to: .now)
                await outgoing.close()
                await incoming.close()
                await client.close()
                await server.close()
                return Result(byteCount: payload.count, route: route, elapsed: elapsed)
            } catch {
                await client.close()
                throw error
            }
        } catch {
            await server.close()
            throw error
        }
    }

    private static func readExactly(_ count: Int, from file: FileHandle) throws -> Data {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        guard setsockopt(file.fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                         socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var result = Data()
        while result.count < count {
            guard let bytes = try file.read(upToCount: count - result.count), !bytes.isEmpty else {
                throw POSIXError(.ECONNRESET)
            }
            result.append(bytes)
        }
        return result
    }
}

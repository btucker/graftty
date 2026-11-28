#if canImport(GrafttyTailcat)
import Foundation
import GrafttyProtocol
import GrafttyTailcat

extension DirectSSHHostConnection {
    /// Dials a runner's Tailcat endpoint and runs the pinned SSH client over
    /// the stream. The Tailcat peer and stream close with this connection.
    public func connect(tailcat endpoint: TailcatEndpoint) async throws {
        let peer = try TailcatPeer.client(address: endpoint.address)
        let pipe: TailcatPipe
        do { pipe = try await peer.dial(port: endpoint.port) } catch { await peer.close(); throw error }
        do {
            try await connect(input: pipe.file, output: pipe.file)
            try pipe.file.close()
        } catch {
            await pipe.close()
            await peer.close()
            throw error
        }
        onClose {
            await pipe.close()
            await peer.close()
        }
    }
}
#endif

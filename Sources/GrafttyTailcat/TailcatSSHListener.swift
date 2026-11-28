import Foundation
import GrafttyProtocol

/// A Tailcat listener's persistent identity and the address it last served.
/// Both are secrets: store them as credentials and never log them.
public struct TailcatListenerState: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let identity: TailcatServerIdentity
    public let address: String
    public var description: String { "TailcatListenerState(redacted)" }
    public var debugDescription: String { description }

    public init(identity: TailcatServerIdentity, address: String) {
        self.identity = identity
        self.address = address
    }
}

public protocol TailcatListenerStateStore: Sendable {
    func load() throws -> TailcatListenerState?
    func save(_ state: TailcatListenerState) throws
}

/// Owner-only file storage, for platforms without Keychain.
public struct TailcatListenerStateFile: TailcatListenerStateStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> TailcatListenerState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(TailcatListenerState.self, from: Data(contentsOf: url))
    }

    public func save(_ state: TailcatListenerState) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let staged = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: staged.path, contents: try JSONEncoder().encode(state),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }
}

/// Serves SSH over Tailcat with a persistent identity, for the Mac host and
/// the runner. Each accepted stream goes to `accept`, which returns a waiter
/// that finishes when that SSH connection closes.
public struct TailcatSSHListener: Sendable {
    public typealias Accept = @Sendable (FileHandle) async throws -> @Sendable () async -> Void

    private let store: any TailcatListenerStateStore
    private let port: UInt16
    private let accept: Accept

    public init(store: any TailcatListenerStateStore, port: UInt16, accept: @escaping Accept) {
        self.store = store
        self.port = port
        self.accept = accept
    }

    /// Listens until cancelled or until Tailcat fails. `onReady` receives the
    /// endpoint once the address is known and saved.
    public func run(onReady: @Sendable (TailcatEndpoint) async -> Void) async throws {
        let saved = try store.load()
        let identity = try saved?.identity ?? TailcatServerIdentity.generate()
        let peer = try TailcatPeer.server(identity: identity, previousAddress: saved?.address)
        do {
            let listener = try await peer.listen(port: port)
            let address = try await peer.address()
            try Task.checkCancellation()
            try store.save(TailcatListenerState(identity: identity, address: address))
            await onReady(TailcatEndpoint(address: address, port: port))
            while !Task.isCancelled {
                let pipe = try await listener.accept()
                do {
                    let closed = try await accept(pipe.file)
                    try pipe.file.close()
                    Task {
                        await closed()
                        await pipe.close()
                    }
                } catch { await pipe.close() }
            }
        } catch {
            await peer.close()
            throw error
        }
        await peer.close()
    }
}

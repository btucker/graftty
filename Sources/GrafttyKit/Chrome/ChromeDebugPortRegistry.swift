import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Protects local CDP sockets from the general authenticated TCP tunnel.
public final class ChromeDebugPortRegistry: @unchecked Sendable {
    public static let shared = ChromeDebugPortRegistry(profileRoot:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Graftty/ChromeMux", isDirectory: true))
    private struct Entry {
        let port: Int
        let isAlive: @Sendable () -> Bool
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    public init(profileRoot: URL? = nil) {
        // Protection must exist before a paired tunnel opens after app restart.
        guard let profileRoot,
              let profiles = try? FileManager.default.contentsOfDirectory(at: profileRoot, includingPropertiesForKeys: nil) else { return }
        for profile in profiles {
            let name = profile.lastPathComponent
            guard name.count == 64, name.allSatisfy({ "0123456789abcdef".contains($0) }),
                  let port = Self.debugPort(in: profile), Self.ownsDebugPort(profile: profile, port: port) else { continue }
            entries[UUID()] = Entry(port: port, isAlive: { Self.ownsDebugPort(profile: profile, port: port) })
        }
    }

    static func debugPort(in profile: URL) -> Int? {
        guard let bytes = try? Data(contentsOf: profile.appendingPathComponent("DevToolsActivePort")), bytes.count < 1024,
              let value = String(data: bytes, encoding: .utf8),
              let first = value.split(separator: "\n").first, let port = Int(first), (1...65535).contains(port) else { return nil }
        return port
    }

    static func ownsDebugPort(profile: URL, port: Int) -> Bool {
        guard debugPort(in: profile) == port,
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path),
              let raw = destination.split(separator: "-").last, let pid = Int32(raw), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public func register(port: Int, owner: UUID, isAlive: @escaping @Sendable () -> Bool = { true }) {
        lock.lock(); defer { lock.unlock() }
        // Reconnecting a restored profile replaces its startup registration.
        entries = entries.filter { $0.key != owner && $0.value.port != port }
        entries[owner] = Entry(port: port, isAlive: isAlive)
    }
    public func unregister(owner: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries[owner] = nil
    }
    public func contains(port: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var protected = false
        for (owner, entry) in entries where entry.port == port {
            if entry.isAlive() { protected = true }
            else { entries[owner] = nil }
        }
        return protected
    }
}

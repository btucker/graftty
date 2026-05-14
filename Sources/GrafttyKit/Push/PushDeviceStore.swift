import Foundation

public final class PushDeviceStore: @unchecked Sendable {
    public static let defaultFileURL: URL = {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Graftty/push-devices.json")
    }()

    private static let retention: TimeInterval = 90 * 86_400

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL = PushDeviceStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func register(_ device: PushDevice) throws {
        try mutate { all in
            all.removeAll { $0.token == device.token }
            all.append(device)
        }
    }

    public func remove(token: String) throws {
        try mutate { all in
            all.removeAll { $0.token == token }
        }
    }

    public func liveDevices(now: Date = Date()) -> [PushDevice] {
        (try? load()).map { $0.filter { now.timeIntervalSince($0.lastRegisteredAt) <= Self.retention } } ?? []
    }

    private func mutate(_ apply: (inout [PushDevice]) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var all = (try? load()) ?? []
        apply(&all)
        try write(all)
    }

    private func load() throws -> [PushDevice] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.iso8601().decode([PushDevice].self, from: data)
    }

    private func write(_ devices: [PushDevice]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder.iso8601().encode(devices)
        let tmp = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
    }
}

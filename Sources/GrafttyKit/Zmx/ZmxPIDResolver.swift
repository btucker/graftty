import Foundation

/// Background lookup for port scans. Cache each log independently so growth
/// in the current log does not cause an unchanged rotated log to be reparsed.
public actor ZmxPIDResolver {
    private struct Key: Hashable, Sendable {
        var file: URL
        var sessionName: String
    }

    private enum Signature: Equatable, Sendable {
        case missing
        case file(inode: UInt64, size: UInt64, modified: Date, permissions: UInt16)
    }

    private struct Entry: Sendable {
        var signature: Signature?
        var pid: Int32?
    }

    private var cache: [Key: Entry] = [:]
    private var inFlight: [Key: Task<Entry, Never>] = [:]
    private let readLog: @Sendable (URL) -> String?

    public init() {
        readLog = { try? String(contentsOf: $0, encoding: .utf8) }
    }

    init(readLog: @escaping @Sendable (URL) -> String?) {
        self.readLog = readLog
    }

    public func shellPID(logFile: URL, sessionName: String) async -> Int32? {
        if let pid = await lookup(Key(file: logFile, sessionName: sessionName)) {
            return pid
        }
        return await lookup(Key(file: ZmxPIDLookup.rotatedLogURL(for: logFile), sessionName: sessionName))
    }

    private func lookup(_ key: Key) async -> Int32? {
        if let task = inFlight[key] { return await task.value.pid }
        let previous = cache[key]
        let readLog = self.readLog
        let task = Task {
            await OffMainIO.run {
                let signature = Self.signature(of: key.file)
                if let signature, let previous, signature == previous.signature { return previous }
                if signature == .missing { return Entry(signature: .missing, pid: nil) }
                guard let contents = readLog(key.file) else {
                    // Transient read failures must not become permanent cached misses.
                    return Entry(signature: nil, pid: nil)
                }
                guard signature == Self.signature(of: key.file) else {
                    // Do not return a PID read from a file that changed during I/O.
                    return Entry(signature: nil, pid: nil)
                }
                let pid = ZmxPIDLookup.shellPID(fromLogContents: contents, sessionName: key.sessionName)
                return Entry(signature: signature, pid: pid)
            }
        }
        inFlight[key] = task
        let entry = await task.value
        inFlight[key] = nil
        // Bound retained metadata as panes are opened and closed throughout the app's lifetime.
        if cache[key] == nil && cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        if entry.signature != nil { cache[key] = entry }
        else { cache[key] = nil }
        return entry.pid
    }

    private static func signature(of file: URL) -> Signature? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date,
                  let permissions = attributes[.posixPermissions] as? NSNumber else { return nil }
            return .file(inode: inode.uint64Value, size: size.uint64Value,
                         modified: modified, permissions: permissions.uint16Value)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError {
                return .missing
            }
            return nil
        }
    }
}

import CryptoKit
import Darwin
import Foundation
import GrafttyProtocol

public enum AttentionFileStopAction: Equatable, Sendable {
    case requestRecap
    case queued
}

public struct AttentionFileStopEvent: Codable, Sendable {
    public let worktree: String
    public let agentID: String?
    public let runtime: TeamHookRuntime
    public let sessionID: String?
    public let paneSessionName: String?
    public let recap: AttentionRecap?
    public let stoppedAt: Date
}

public enum AttentionFileHandoffError: Error {
    case unsafeDirectory
    case invalidRecap
}

/// Transfers only stopped-turn Attention data through files writable by a
/// sandboxed agent. Team and worktree commands keep using the control socket.
public struct AttentionFileHandoff: Sendable {
    public static var defaultRootDirectory: URL {
        URL(fileURLWithPath: "/private/tmp/graftty-attention-\(geteuid())", isDirectory: true)
    }

    public let rootDirectory: URL

    public init(rootDirectory: URL = defaultRootDirectory) {
        self.rootDirectory = rootDirectory
    }

    public func stage(_ recap: AttentionRecap, worktree: String, agentID: String) throws {
        guard recap.isValid, !worktree.isEmpty, !agentID.isEmpty else {
            throw AttentionFileHandoffError.invalidRecap
        }
        try ensureDirectory()
        let data = try JSONEncoder().encode(recap)
        try data.write(to: reportURL(worktree: worktree, agentID: agentID), options: .atomic)
    }

    public func stop(
        worktree: String,
        agentID: String?,
        runtime: TeamHookRuntime,
        sessionID: String?,
        paneSessionName: String?,
        stopHookActive: Bool,
        turnID: String? = nil
    ) throws -> AttentionFileStopAction {
        try ensureDirectory()
        let marker = turnID.map { _ in markerURL(worktree: worktree, agentID: agentID, sessionID: sessionID) }
        if let marker, let turnID,
           (try? String(contentsOf: marker, encoding: .utf8)) == turnID {
            return .queued
        }
        let report = agentID.map { reportURL(worktree: worktree, agentID: $0) }
        let recap = try report.flatMap { url -> AttentionRecap? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try JSONDecoder().decode(AttentionRecap.self, from: Data(contentsOf: url))
        }
        if recap == nil, agentID != nil, !stopHookActive { return .requestRecap }
        let event = AttentionFileStopEvent(
            worktree: worktree,
            agentID: agentID,
            runtime: runtime,
            sessionID: sessionID,
            paneSessionName: paneSessionName,
            recap: recap,
            stoppedAt: Date()
        )
        let micros = Int64(event.stoppedAt.timeIntervalSince1970 * 1_000_000)
        let name = "stop-\(micros)-\(UUID().uuidString).json"
        try JSONEncoder().encode(event).write(
            to: rootDirectory.appendingPathComponent(name), options: .atomic
        )
        if let marker, let turnID {
            try? Data(turnID.utf8).write(to: marker, options: .atomic)
        }
        if recap != nil, let report { try? FileManager.default.removeItem(at: report) }
        return .queued
    }

    /// Replays durable events after a restart and removes each file only after
    /// its handler returns. Repeating a card after an app crash is safer than
    /// silently losing the stopped turn.
    @discardableResult
    public func consumeStops(_ handle: (AttentionFileStopEvent) -> Void) throws -> Int {
        try ensureDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasPrefix("stop-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var count = 0
        for file in files.prefix(100) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 16_384 else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let event: AttentionFileStopEvent
            do {
                event = try JSONDecoder().decode(AttentionFileStopEvent.self, from: Data(contentsOf: file))
            } catch {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            guard !event.worktree.isEmpty, event.recap?.isValid != false else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            handle(event)
            try FileManager.default.removeItem(at: file)
            count += 1
        }
        return count
    }

    private func reportURL(worktree: String, agentID: String) -> URL {
        rootDirectory.appendingPathComponent("report-\(key(for: "\(worktree)\0\(agentID)")).json")
    }

    private func markerURL(worktree: String, agentID: String?, sessionID: String?) -> URL {
        rootDirectory.appendingPathComponent(
            "turn-\(key(for: "\(worktree)\0\(sessionID ?? agentID ?? "unknown")")).txt"
        )
    }

    private func key(for input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var info = stat()
        guard lstat(rootDirectory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0 else {
            throw AttentionFileHandoffError.unsafeDirectory
        }
    }
}

/// A directory event makes stopped cards prompt; the timer catches missed
/// vnode events and files left behind by an app restart.
public final class AttentionFileHandoffObserver: @unchecked Sendable {
    private let handoff: AttentionFileHandoff
    private let queue = DispatchQueue(label: "com.graftty.attention-file-handoff", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?

    public init(handoff: AttentionFileHandoff = AttentionFileHandoff()) {
        self.handoff = handoff
    }

    public func start(_ onChange: @escaping @Sendable () -> Void) throws {
        try handoff.ensureDirectory()
        queue.sync {
            guard timer == nil else { return }
            let fd = open(handoff.rootDirectory.path, O_EVTONLY)
            if fd >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd, eventMask: [.write], queue: queue
                )
                source.setEventHandler(handler: onChange)
                source.setCancelHandler { _ = close(fd) }
                source.resume()
                self.source = source
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
            timer.setEventHandler(handler: onChange)
            timer.resume()
            self.timer = timer
            onChange()
        }
    }

    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            timer?.cancel()
            timer = nil
        }
    }
}

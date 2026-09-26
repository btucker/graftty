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

public struct AttentionFileProgressEvent: Codable, Sendable {
    public let worktree: String
    public let agentID: String?
    public let runtime: TeamHookRuntime
    public let sessionID: String?
    public let progressedAt: Date
}

public enum AttentionFileActivityEvent: Sendable {
    case stop(AttentionFileStopEvent)
    case progress(AttentionFileProgressEvent)

    var occurredAt: Date {
        switch self {
        case .stop(let event): event.stoppedAt
        case .progress(let event): event.progressedAt
        }
    }
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

    /// A native provider session can lack wrapper registration (for example,
    /// one started before Graftty refreshed its plugin). Its Stop hook may
    /// also be absent, so publish the explicit report as a stopped card now.
    /// The receipt prevents a later matching Stop hook from replacing it.
    public func publishUnmanaged(
        _ recap: AttentionRecap,
        worktree: String,
        agentID: String,
        runtime: TeamHookRuntime,
        sessionID: String?,
        paneSessionName: String?
    ) throws {
        guard recap.isValid, !worktree.isEmpty, !agentID.isEmpty else {
            throw AttentionFileHandoffError.invalidRecap
        }
        try ensureDirectory()
        let receipt = publishedURL(worktree: worktree, agentID: agentID)
        try Data(String(Date().timeIntervalSince1970).utf8).write(to: receipt, options: .atomic)
        do {
            try enqueueStop(AttentionFileStopEvent(
                worktree: worktree, agentID: agentID, runtime: runtime,
                sessionID: sessionID, paneSessionName: paneSessionName,
                recap: recap, stoppedAt: Date()
            ))
        } catch {
            try? FileManager.default.removeItem(at: receipt)
            throw error
        }
    }

    public func stop(
        worktree: String,
        agentID: String?,
        runtime: TeamHookRuntime,
        sessionID: String?,
        paneSessionName: String?,
        stopHookActive: Bool,
        turnID: String? = nil,
        stoppedAt: Date = Date()
    ) throws -> AttentionFileStopAction {
        try ensureDirectory()
        let marker = turnID.map { _ in markerURL(worktree: worktree, agentID: agentID, sessionID: sessionID) }
        if let marker, let turnID,
           (try? String(contentsOf: marker, encoding: .utf8)) == turnID {
            return .queued
        }
        if let agentID {
            let receipt = publishedURL(worktree: worktree, agentID: agentID)
            if let timestamp = try? String(contentsOf: receipt, encoding: .utf8),
               let reportedAt = TimeInterval(timestamp),
               (0..<600).contains(Date().timeIntervalSince1970 - reportedAt) {
                if let marker, let turnID {
                    try? Data(turnID.utf8).write(to: marker, options: .atomic)
                }
                try? FileManager.default.removeItem(at: receipt)
                return .queued
            }
            try? FileManager.default.removeItem(at: receipt)
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
            stoppedAt: stoppedAt
        )
        try enqueueStop(event)
        if let marker, let turnID {
            try? Data(turnID.utf8).write(to: marker, options: .atomic)
        }
        if recap != nil, let report { try? FileManager.default.removeItem(at: report) }
        return .queued
    }

    /// Turn-start hooks use this path because a sandboxed agent may be
    /// unable to reach the control socket that clears its prior stopped card.
    public func progress(
        worktree: String,
        agentID: String?,
        runtime: TeamHookRuntime,
        sessionID: String?,
        progressedAt: Date = Date()
    ) throws {
        guard !worktree.isEmpty else { throw AttentionFileHandoffError.invalidRecap }
        try ensureDirectory()
        let event = AttentionFileProgressEvent(
            worktree: worktree, agentID: agentID, runtime: runtime,
            sessionID: sessionID, progressedAt: progressedAt
        )
        let micros = Int64(progressedAt.timeIntervalSince1970 * 1_000_000)
        let name = "progress-\(micros)-\(UUID().uuidString).json"
        try JSONEncoder().encode(event).write(
            to: rootDirectory.appendingPathComponent(name), options: .atomic
        )
    }

    /// Replays durable events after a restart and removes each file only after
    /// its handler returns. Repeating a card after an app crash is safer than
    /// silently losing the stopped turn.
    @discardableResult
    public func consumeStops(_ handle: (AttentionFileStopEvent) -> Void) throws -> Int {
        try consumeFiles(includeProgress: false) { event in
            if case .stop(let stop) = event { handle(stop) }
        }
    }

    @discardableResult
    public func consumeActivities(_ handle: (AttentionFileActivityEvent) -> Void) throws -> Int {
        try consumeFiles(includeProgress: true, handle)
    }

    private func consumeFiles(
        includeProgress: Bool,
        _ handle: (AttentionFileActivityEvent) -> Void
    ) throws -> Int {
        try ensureDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter {
            $0.pathExtension == "json" && ($0.lastPathComponent.hasPrefix("stop-")
                || (includeProgress && $0.lastPathComponent.hasPrefix("progress-")))
        }
        var events: [(URL, AttentionFileActivityEvent)] = []
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 16_384 else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let data = try Data(contentsOf: file)
            let event: AttentionFileActivityEvent?
            if file.lastPathComponent.hasPrefix("stop-") {
                event = (try? JSONDecoder().decode(AttentionFileStopEvent.self, from: data))
                    .map { AttentionFileActivityEvent.stop($0) }
            } else {
                event = (try? JSONDecoder().decode(AttentionFileProgressEvent.self, from: data))
                    .map { AttentionFileActivityEvent.progress($0) }
            }
            guard let event else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            events.append((file, event))
        }
        events.sort { $0.1.occurredAt < $1.1.occurredAt }
        var count = 0
        for (file, event) in events.prefix(100) {
            let isValid: Bool
            switch event {
            case .stop(let stop): isValid = !stop.worktree.isEmpty && stop.recap?.isValid != false
            case .progress(let progress): isValid = !progress.worktree.isEmpty
            }
            guard isValid else {
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

    private func publishedURL(worktree: String, agentID: String) -> URL {
        rootDirectory.appendingPathComponent("published-\(key(for: "\(worktree)\0\(agentID)")).txt")
    }

    private func enqueueStop(_ event: AttentionFileStopEvent) throws {
        let micros = Int64(event.stoppedAt.timeIntervalSince1970 * 1_000_000)
        let name = "stop-\(micros)-\(UUID().uuidString).json"
        try JSONEncoder().encode(event).write(
            to: rootDirectory.appendingPathComponent(name), options: .atomic
        )
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

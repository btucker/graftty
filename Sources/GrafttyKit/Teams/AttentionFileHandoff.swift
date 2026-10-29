#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
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
    public var recapReportedAt: Date? = nil
    public var turnID: String? = nil
}

/// The CLI publishes this independently of the provider's eventual Stop.
public struct AttentionFileRecapEvent: Codable, Sendable, Equatable {
    public let worktree: String
    public let agentID: String
    public let recap: AttentionRecap
    public let reportedAt: Date
}

public struct AttentionFileProgressEvent: Codable, Sendable {
    public let worktree: String
    public let agentID: String?
    public let runtime: TeamHookRuntime
    public let sessionID: String?
    public let progressedAt: Date
    public let userInput: WorktreeHistory.UserInput?
}

public struct AttentionFileResponseEvent: Codable, Sendable {
    public let worktree: String
    public let response: WorktreeHistory.AgentResponse
}

public enum AttentionFileActivityEvent: Sendable {
    case recap(AttentionFileRecapEvent)
    case stop(AttentionFileStopEvent)
    case progress(AttentionFileProgressEvent)
    case response(AttentionFileResponseEvent)

    var occurredAt: Date {
        switch self {
        case .recap(let event): event.reportedAt
        case .stop(let event): event.stoppedAt
        case .progress(let event): event.progressedAt
        case .response(let event): Date(timeIntervalSinceReferenceDate: event.response.timestamp)
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
        rootDirectory(environment: ProcessInfo.processInfo.environment)
    }

    public static func rootDirectory(environment: [String: String]) -> URL {
        if let path = environment["GRAFTTY_ATTENTION_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #if os(Linux)
        return URL(fileURLWithPath: "/tmp/graftty-attention-\(geteuid())", isDirectory: true)
        #else
        return URL(fileURLWithPath: "/private/tmp/graftty-attention-\(geteuid())", isDirectory: true)
        #endif
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
        let lease = try ExclusiveFileLock(url: rootDirectory.appendingPathComponent(".handoff.lock"))
        defer { withExtendedLifetime(lease) {} }
        let data = try JSONEncoder().encode(recap)
        try data.write(to: reportURL(worktree: worktree, agentID: agentID), options: .atomic)
    }

    /// Publish the brief now and retain the full report as the current turn's
    /// receipt. Stop verifies it and attaches `need` to completion attention.
    public func publish(_ recap: AttentionRecap, worktree: String, agentID: String) throws {
        guard recap.isValid, !worktree.isEmpty, !agentID.isEmpty else {
            throw AttentionFileHandoffError.invalidRecap
        }
        try ensureDirectory()
        let lease = try ExclusiveFileLock(url: rootDirectory.appendingPathComponent(".handoff.lock"))
        defer { withExtendedLifetime(lease) {} }
        let event = AttentionFileRecapEvent(worktree: worktree, agentID: agentID, recap: recap, reportedAt: Date())
        let data = try JSONEncoder().encode(event)
        let name = "recap-\(UUID().uuidString).json"
        // Commit the receipt only after the publication event is durable. If
        // writing the receipt fails, Stop can still request its fallback.
        try data.write(to: rootDirectory.appendingPathComponent(name), options: .atomic)
        try data.write(to: reportURL(worktree: worktree, agentID: agentID), options: .atomic)
    }

    /// Read-only transport fallback. A report remains readable even if the
    /// directory can no longer accept the completion event.
    public func publishedReport(worktree: String, agentID: String) -> AttentionFileRecapEvent? {
        guard let data = try? Data(contentsOf: reportURL(worktree: worktree, agentID: agentID)),
              let report = try? JSONDecoder().decode(AttentionFileRecapEvent.self, from: data),
              report.worktree == worktree, report.agentID == agentID, report.recap.isValid else { return nil }
        return report
    }

    /// A socket completion must also retire its matching file receipt. Never
    /// delete a newer report that arrived while the socket request was running.
    public func acknowledgeSocketStop(worktree: String, agentID: String?, sessionID: String?,
                                      turnID: String?, reportedAt: Date?) throws {
        try ensureDirectory()
        let lease = try ExclusiveFileLock(url: rootDirectory.appendingPathComponent(".handoff.lock"))
        defer { withExtendedLifetime(lease) {} }
        if let agentID, let reportedAt,
           publishedReport(worktree: worktree, agentID: agentID)?.reportedAt == reportedAt {
            try FileManager.default.removeItem(at: reportURL(worktree: worktree, agentID: agentID))
        }
        if agentID != nil || sessionID != nil || turnID != nil {
            try Data((turnID ?? "current").utf8).write(
                to: markerURL(worktree: worktree, agentID: agentID, sessionID: sessionID), options: .atomic)
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
        let lease = try ExclusiveFileLock(url: rootDirectory.appendingPathComponent(".handoff.lock"))
        defer { withExtendedLifetime(lease) {} }
        let marker = agentID != nil || sessionID != nil || turnID != nil
            ? markerURL(worktree: worktree, agentID: agentID, sessionID: sessionID) : nil
        let completedTurn = turnID ?? "current"
        if let marker, (try? String(contentsOf: marker, encoding: .utf8)) == completedTurn {
            return .queued
        }
        if let agentID {
            let receipt = publishedURL(worktree: worktree, agentID: agentID)
            if let timestamp = try? String(contentsOf: receipt, encoding: .utf8),
               let reportedAt = TimeInterval(timestamp),
               (0..<600).contains(Date().timeIntervalSince1970 - reportedAt) {
                if let marker { try? Data(completedTurn.utf8).write(to: marker, options: .atomic) }
                try? FileManager.default.removeItem(at: receipt)
                return .queued
            }
            try? FileManager.default.removeItem(at: receipt)
        }
        let report = agentID.map { reportURL(worktree: worktree, agentID: $0) }
        let data = report.flatMap { try? Data(contentsOf: $0) }
        let published = data.flatMap { try? JSONDecoder().decode(AttentionFileRecapEvent.self, from: $0) }
        // Raw recap files were staged by older CLIs. Keep accepting those.
        let recap = published?.recap ?? data.flatMap { try? JSONDecoder().decode(AttentionRecap.self, from: $0) }
        if recap == nil, agentID?.isEmpty == false, !stopHookActive { return .requestRecap }
        let event = AttentionFileStopEvent(
            worktree: worktree,
            agentID: agentID,
            runtime: runtime,
            sessionID: sessionID,
            paneSessionName: paneSessionName,
            recap: recap,
            stoppedAt: stoppedAt,
            recapReportedAt: published?.reportedAt,
            turnID: turnID
        )
        try enqueueStop(event)
        if let marker { try? Data(completedTurn.utf8).write(to: marker, options: .atomic) }
        if let report { try? FileManager.default.removeItem(at: report) }
        return .queued
    }

    /// Turn-start hooks use this path because a sandboxed agent may be
    /// unable to reach the control socket that clears its prior stopped card.
    public func progress(
        worktree: String,
        agentID: String?,
        runtime: TeamHookRuntime,
        sessionID: String?,
        progressedAt: Date = Date(),
        userPrompt: String? = nil,
        startsTurn: Bool = false
    ) throws {
        guard !worktree.isEmpty else { throw AttentionFileHandoffError.invalidRecap }
        try ensureDirectory()
        let lease = try ExclusiveFileLock(url: rootDirectory.appendingPathComponent(".handoff.lock"))
        defer { withExtendedLifetime(lease) {} }
        if startsTurn {
            var receipts = [markerURL(worktree: worktree, agentID: agentID, sessionID: sessionID)]
            if let agentID {
                receipts += [reportURL(worktree: worktree, agentID: agentID),
                             publishedURL(worktree: worktree, agentID: agentID)]
            }
            for url in receipts where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        let event = AttentionFileProgressEvent(
            worktree: worktree, agentID: agentID, runtime: runtime,
            sessionID: sessionID, progressedAt: progressedAt,
            userInput: userPrompt.map { .init(text: $0, at: progressedAt, runtime: runtime.rawValue) }
        )
        let micros = Int64(progressedAt.timeIntervalSince1970 * 1_000_000)
        let name = "progress-\(micros)-\(UUID().uuidString).json"
        try JSONEncoder().encode(event).write(
            to: rootDirectory.appendingPathComponent(name), options: .atomic
        )
    }

    public func response(_ response: WorktreeHistory.AgentResponse, worktree: String) throws {
        guard !worktree.isEmpty, !response.text.isEmpty else { throw AttentionFileHandoffError.invalidRecap }
        try ensureDirectory()
        let event = AttentionFileResponseEvent(worktree: worktree, response: response)
        // A final upgrade must survive acknowledgement of an earlier nonfinal file.
        let version = response.isFinal == true ? "\0final" : ""
        let name = "response-\(key(for: worktree + "\0" + response.id + version)).json"
        try JSONEncoder().encode(event).write(to: rootDirectory.appendingPathComponent(name), options: .atomic)
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
    public func consumeActivities(
        acceptingWorktree: (String) -> Bool = { _ in true },
        _ handle: (AttentionFileActivityEvent) throws -> Void
    ) throws -> Int {
        try consumeFiles(includeProgress: true, acceptingWorktree: acceptingWorktree, handle)
    }

    /// Like `consumeActivities`, but leaves each handled event's file in
    /// place and returns it, so a caller that persists asynchronously can
    /// `remove(_:)` the files only once the result is on disk (REMOTE-23.10).
    public func takeActivities(
        acceptingWorktree: (String) -> Bool = { _ in true },
        _ handle: (AttentionFileActivityEvent) throws -> Void
    ) throws -> [URL] {
        try processFiles(
            includeProgress: true, removeHandled: false,
            acceptingWorktree: acceptingWorktree, handle
        )
    }

    /// Deletes event files returned by `takeActivities` once their result
    /// is persisted. Attempts every file, then throws the first failure, so
    /// an undeletable event is reported rather than silently replayed on
    /// every scan.
    public func remove(_ files: [URL]) throws {
        var firstFailure: (any Error)?
        for file in files {
            do { try FileManager.default.removeItem(at: file) } catch { firstFailure = firstFailure ?? error }
        }
        if let firstFailure { throw firstFailure }
    }

    private func consumeFiles(
        includeProgress: Bool,
        acceptingWorktree: (String) -> Bool = { _ in true },
        _ handle: (AttentionFileActivityEvent) throws -> Void
    ) throws -> Int {
        try processFiles(
            includeProgress: includeProgress, removeHandled: true,
            acceptingWorktree: acceptingWorktree, handle
        ).count
    }

    /// Returns the files of the events `handle` accepted. Invalid, oversized
    /// and undecodable files are always deleted; handled ones only when
    /// `removeHandled`.
    private func processFiles(
        includeProgress: Bool,
        removeHandled: Bool,
        acceptingWorktree: (String) -> Bool,
        _ handle: (AttentionFileActivityEvent) throws -> Void
    ) throws -> [URL] {
        try ensureDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter {
            $0.pathExtension == "json" && ($0.lastPathComponent.hasPrefix("stop-")
                || (includeProgress && ($0.lastPathComponent.hasPrefix("progress-") || $0.lastPathComponent.hasPrefix("response-") || $0.lastPathComponent.hasPrefix("recap-"))))
        }
        var events: [(URL, AttentionFileActivityEvent)] = []
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let maximumSize = file.lastPathComponent.hasPrefix("response-") ? 65_536 : 16_384
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= maximumSize else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let data = try Data(contentsOf: file)
            let event: AttentionFileActivityEvent?
            if file.lastPathComponent.hasPrefix("stop-") {
                event = (try? JSONDecoder().decode(AttentionFileStopEvent.self, from: data))
                    .map { AttentionFileActivityEvent.stop($0) }
            } else if file.lastPathComponent.hasPrefix("recap-") {
                event = (try? JSONDecoder().decode(AttentionFileRecapEvent.self, from: data))
                    .map { AttentionFileActivityEvent.recap($0) }
            } else if file.lastPathComponent.hasPrefix("response-") {
                event = (try? JSONDecoder().decode(AttentionFileResponseEvent.self, from: data))
                    .map { AttentionFileActivityEvent.response($0) }
            } else {
                event = (try? JSONDecoder().decode(AttentionFileProgressEvent.self, from: data))
                    .map { AttentionFileActivityEvent.progress($0) }
            }
            guard let event else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let worktree: String
            switch event {
            case .recap(let value): worktree = value.worktree
            case .stop(let value): worktree = value.worktree
            case .progress(let value): worktree = value.worktree
            case .response(let value): worktree = value.worktree
            }
            guard acceptingWorktree(worktree) else { continue }
            events.append((file, event))
        }
        events.sort { $0.1.occurredAt < $1.1.occurredAt }
        var handled: [URL] = []
        for (file, event) in events.prefix(100) {
            let isValid: Bool
            switch event {
            case .recap(let report): isValid = !report.worktree.isEmpty && !report.agentID.isEmpty && report.recap.isValid
            case .stop(let stop): isValid = !stop.worktree.isEmpty && stop.recap?.isValid != false
            case .progress(let progress): isValid = !progress.worktree.isEmpty
            case .response(let response): isValid = !response.worktree.isEmpty && !response.response.text.isEmpty
            }
            guard isValid else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            try handle(event)
            if removeHandled { try FileManager.default.removeItem(at: file) }
            handled.append(file)
        }
        return handled
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
            "turn-\(key(for: "\(worktree)\0\(agentID ?? "unknown")\0\(sessionID ?? "unknown")")).txt"
        )
    }

    private func key(for input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func ensureDirectory() throws {
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
    #if !os(Linux)
    private var source: DispatchSourceFileSystemObject?
    #endif
    private var timer: DispatchSourceTimer?

    public init(handoff: AttentionFileHandoff = AttentionFileHandoff()) {
        self.handoff = handoff
    }

    public func start(_ onChange: @escaping @Sendable () -> Void) throws {
        try handoff.ensureDirectory()
        queue.sync {
            guard timer == nil else { return }
            #if !os(Linux)
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
            #endif
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
            #if !os(Linux)
            source?.cancel()
            source = nil
            #endif
            timer?.cancel()
            timer = nil
        }
    }
}

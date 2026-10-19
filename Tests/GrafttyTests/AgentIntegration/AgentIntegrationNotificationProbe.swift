import Foundation
import SwiftUI
import GrafttyProtocol
@testable import Graftty
@testable import GrafttyKit

/// Captures real provider handoffs and exercises Mac request construction with
/// an injected sink. This fixture never calls UNUserNotificationCenter.add.
@MainActor
final class AgentIntegrationNotificationProbe {
    struct Attempt: Codable {
        let identifier: String
        let title: String
        let body: String
        let userInfo: [String: String]
    }

    let runtime: HeadlessHostRuntime
    let handoff: AttentionFileHandoff
    let archive: URL
    let terminalManager: TerminalManager
    let delivery = AgentNotificationDelivery()
    var events: [AttentionFileStopEvent] = []
    var attempts: [Attempt] = []
    var pending: [AgentStopNotificationContent] = []

    init(runtime: HeadlessHostRuntime, root: URL) throws {
        self.runtime = runtime
        handoff = AttentionFileHandoff()
        archive = root.appendingPathComponent("provider-handoff")
        terminalManager = TerminalManager(socketPath: runtime.configuration.socketPath)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    }

    func record(_ event: AttentionFileStopEvent) {
        let binding = Binding<AppState>(get: { self.runtime.state }, set: { self.runtime.state = $0 })
        GrafttyApp.recordStoppedTurn(callerPath: event.worktree, runtime: event.runtime,
            callerAgentID: event.agentID, sessionID: event.sessionID,
            paneSessionName: event.paneSessionName, recap: event.recap,
            stoppedAt: event.stoppedAt, appState: binding, terminalManager: terminalManager,
            postNotification: { self.pending.append($0) })
    }

    func capture() throws {
        // Keep the exact files before consumeActivities removes acknowledged
        // events, so artifacts distinguish provider output from test replays.
        if FileManager.default.fileExists(atPath: handoff.rootDirectory.path) {
            for file in try FileManager.default.contentsOfDirectory(at: handoff.rootDirectory,
                includingPropertiesForKeys: nil) where file.pathExtension == "json"
                    && (file.lastPathComponent.hasPrefix("stop-") || file.lastPathComponent.hasPrefix("progress-")) {
                let destination = archive.appendingPathComponent(file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: file, to: destination)
                }
            }
        }
        try handoff.consumeActivities(acceptingWorktree: { self.runtime.state.worktree(forPath: $0) != nil }) { activity in
            switch activity {
            case .stop(let event):
                events.append(event)
                record(event)
            case .progress(let event):
                runtime.state.clearAgentStopAttention(worktreePath: event.worktree,
                    providerSessionKey: AgentHookAttentionIdentity.key(runtime: event.runtime,
                        sessionID: event.sessionID, callerAgentID: event.agentID), progressedAt: event.progressedAt)
            }
        }
    }

    func handle(_ command: AgentIntegrationCommand, path: String) async throws -> [String: String] {
        try capture()
        if command.operation == "notificationsReplay" {
            guard let encoded = command.parameters["events"], let data = encoded.data(using: .utf8),
                  let copies = command.parameters["copies"].flatMap(Int.init), (1...10).contains(copies) else {
                throw AgentIntegrationError("notification replay requires captured events and 1...10 copies")
            }
            let replay = try JSONDecoder().decode([AttentionFileStopEvent].self, from: data)
            for event in replay {
                guard event.worktree == path, events.contains(where: {
                    $0.worktree == event.worktree && $0.runtime == event.runtime
                        && $0.sessionID == event.sessionID && $0.stoppedAt == event.stoppedAt
                        && $0.recap == event.recap && $0.agentID == event.agentID
                        && $0.paneSessionName == event.paneSessionName
                }) else { throw AgentIntegrationError("replay event was not captured from this provider") }
                for _ in 0..<copies { record(event) }
            }
        }
        let notifications = pending
        pending.removeAll()
        for notification in notifications {
            await delivery.post(notification, reservation: delivery.reserve(notification),
                authorized: { true }, resolving: { $0 }, deliver: { prepared in
                    let content = prepared.request.content
                    self.attempts.append(Attempt(identifier: prepared.request.identifier,
                        title: content.title, body: content.body,
                        userInfo: content.userInfo.reduce(into: [:]) { values, entry in
                            if let key = entry.key as? String, let value = entry.value as? String { values[key] = value }
                        }))
                })
        }
        let matchingEvents = events.filter { $0.worktree == path }
        let matchingAttempts = attempts.filter { $0.userInfo["worktree_path"] == path }
        return ["events": String(decoding: try JSONEncoder().encode(matchingEvents), as: UTF8.self),
            "attempts": String(decoding: try JSONEncoder().encode(matchingAttempts), as: UTF8.self),
            "postedCount": String(matchingAttempts.count)]
    }
}

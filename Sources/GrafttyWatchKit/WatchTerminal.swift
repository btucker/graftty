import Foundation
import Observation

public struct WatchTerminalTarget: Codable, Sendable, Equatable, Identifiable {
    public var hostID: UUID
    public var worktreeID: String
    public var paneID: String
    public var project: String
    public var worktree: String
    public var host: String
    public var title: String
    public var resourceID: String?
    public var id: String { resourceID ?? hostID.uuidString + ":" + worktreeID + ":" + paneID }

    public init(hostID: UUID, worktreeID: String, paneID: String, project: String, worktree: String, host: String, title: String, resourceID: String? = nil) {
        self.hostID = hostID; self.worktreeID = worktreeID; self.paneID = paneID
        self.project = project; self.worktree = worktree; self.host = host; self.title = title
        self.resourceID = resourceID
    }
}

public struct WatchTerminalFrame: Codable, Sendable, Equatable {
    public var targetID: String
    public var text: String
    public var capturedAt: Date
    public init(targetID: String, text: String, capturedAt: Date = .now) {
        self.targetID = targetID; self.text = text; self.capturedAt = capturedAt
    }
}

@Observable @MainActor
public final class WatchTerminalModel {
    public let target: WatchTerminalTarget
    public private(set) var frame: WatchTerminalFrame?
    public private(set) var isLoading = false
    public private(set) var error: String?
    private var generation = 0

    public init(target: WatchTerminalTarget) { self.target = target }
    public func refresh(using send: WatchInboxModel.Send) async {
        guard !isLoading, !Task.isCancelled else { return }
        let generation = self.generation
        isLoading = true
        // WCSession cannot cancel an already sent exchange. Keep this guard
        // until its callback returns, even when stop invalidates the result.
        defer { isLoading = false }
        do {
            let response = try await send(.terminal(target))
            guard generation == self.generation, !Task.isCancelled else { return }
            switch response {
            case .terminal(let frame) where frame.targetID == target.id:
                self.frame = frame
                error = nil
            case .failure(let message): error = message
            case .snapshot(let snapshot) where !snapshot.isEnabled:
                frame = nil
                error = "Enable Apple Watch in Graftty's Hosts screen on iPhone."
            default: error = "The terminal response didn't match this pane. Refresh the terminal list."
            }
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            self.error = "Couldn't reach your iPhone. Last terminal output is still shown."
        }
    }
    public func stop() {
        generation += 1
    }
}

import Foundation
import GrafttyWatchKit
import Observation
@preconcurrency import WatchConnectivity

@Observable @MainActor
final class WatchPhoneConnection: NSObject, WCSessionDelegate {
    let inbox: WatchInboxModel
    private var session: WCSession?
    private var isActive = false
    private var activationFinished = false

    override init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--watch-preview") {
            inbox = WatchInboxModel(snapshot: .preview)
            super.init()
            return
        }
        #endif
        let snapshot = UserDefaults.standard.data(forKey: WatchCompanionSettings.snapshotKey)
            .flatMap { try? JSONDecoder().decode(WatchAttentionSnapshot.self, from: $0) }
        inbox = WatchInboxModel(snapshot: snapshot ?? .init())
        super.init()
    }

    func activate() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--watch-preview") { return }
        #endif
        guard session == nil, WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        self.session = session
        activationFinished = false
        session.activate()
    }

    func refresh() async { await inbox.refresh(using: send) }

    func setActive(_ active: Bool) {
        isActive = active
        if active, session?.activationState == .activated { Task { await refresh() } }
    }

    /// Keep the background task alive until WatchConnectivity has delivered its
    /// pending context. Background reception never asks the phone to dial a host.
    func receiveBackgroundUpdate() async {
        activate()
        guard let session else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !activationFinished || session.hasContentPending {
            if activationFinished, session.activationState != .activated { return }
            guard ContinuousClock.now < deadline else { return }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard session.activationState == .activated else { return }
        if let bytes = session.receivedApplicationContext["snapshot"] as? Data,
           let snapshot = try? JSONDecoder().decode(WatchAttentionSnapshot.self, from: bytes) { receive(snapshot) }
    }

    func answer(_ card: WatchAttentionCard, text: String) async {
        await inbox.answer(card, text: text, using: send)
    }

    private func receive(_ snapshot: WatchAttentionSnapshot) {
        inbox.receive(snapshot)
        if let bytes = try? inbox.snapshot.encodedForTransfer() {
            UserDefaults.standard.set(bytes, forKey: WatchCompanionSettings.snapshotKey)
        }
    }

    func send(_ request: WatchRequest) async throws -> WatchResponse {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--watch-preview") {
            if case .answer = request { return .answered }
            if case .terminal(let target) = request {
                return .terminal(.init(targetID: target.id, text: Self.previewTerminalOutput))
            }
            return .snapshot(.preview)
        }
        #endif
        guard let session, session.activationState == .activated else {
            throw WCError(.sessionNotActivated)
        }
        let bytes = try request.encodedForTransfer()
        let response: WatchResponse = try await withCheckedThrowingContinuation { continuation in
            session.sendMessageData(bytes, replyHandler: { bytes in
                do { continuation.resume(returning: try JSONDecoder().decode(WatchResponse.self, from: bytes)) }
                catch { continuation.resume(throwing: error) }
            }, errorHandler: { error in continuation.resume(throwing: error) })
        }
        if case .snapshot(let snapshot) = response { receive(snapshot) }
        return response
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let bytes = session.receivedApplicationContext["snapshot"] as? Data
        Task { @MainActor in
            self.activationFinished = true
            if let bytes, let snapshot = try? JSONDecoder().decode(WatchAttentionSnapshot.self, from: bytes) {
                self.receive(snapshot)
            }
            if activationState == .activated, self.isActive { await self.refresh() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let bytes = applicationContext["snapshot"] as? Data,
              let snapshot = try? JSONDecoder().decode(WatchAttentionSnapshot.self, from: bytes) else { return }
        Task { @MainActor in self.receive(snapshot) }
    }
}

#if DEBUG
extension WatchPhoneConnection {
    nonisolated static let previewTerminal = WatchTerminalTarget(hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        worktreeID: "/preview/watch", paneID: "preview", project: "Graftty", worktree: "watch", host: "MacBook Pro", title: "Codex")
    nonisolated static let previewTerminalOutput = """
    graftty/watch  main → watchOS
    $ scripts/swiftpm test
    Building for debugging...
    Build complete! (2.18s)

    ✓ Worktree routing
    ✓ Watch reply delivery
    ✓ Terminal read-only access
    ✓ Unicode output bounds

    Test run passed.

    ──────────────────────────────
    Codex · Apple Watch companion

    The terminal viewer is ready.
    It reads output through your
    paired iPhone without resizing
    the Mac's terminal.

    Waiting for your answer:
    Merge now or wait for CI?

    ›
    """
}

private extension WatchAttentionSnapshot {
    static var preview: Self {
        .init(cards: [
            .init(hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                  worktreeID: "/preview/watch", project: "Graftty", worktree: "watch",
                  host: "MacBook Pro", title: "Apple Watch companion", question: "Merge now or wait for CI?",
                  context: "The watch companion is ready. Unit tests passed; the device checks are still running.",
                  options: [.init(label: "Wait for CI", cost: "About 5 minutes", suggested: true),
                            .init(label: "Merge now", cost: "Device checks pending")],
                  target: .init(paneID: "preview", occurrence: Data("preview".utf8)), timestamp: .now),
            .init(hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                  worktreeID: "/preview/docs", project: "Graftty", worktree: "docs",
                  host: "MacBook Pro", title: "Release notes", question: "Include the terminal experiment?",
                  context: "The notes currently cover questions and replies.", options: [],
                  target: .init(paneID: "docs", occurrence: Data("docs".utf8)), timestamp: .now)
        ], updatedAt: .now, terminals: [WatchPhoneConnection.previewTerminal])
    }
}
#endif

#if os(iOS)
import Foundation
import GrafttyCommandUI
import GrafttyProtocol
import GrafttyRemoteClient
import GrafttyWatchKit
import UIKit
@preconcurrency import WatchConnectivity

/// WatchConnectivity wakes this relay independently of RootView's foreground
/// connection lifecycle. Only an explicitly enabled, paired watch can use it.
@MainActor
final class MobileWatchCompanion: NSObject, WCSessionDelegate {
    static let shared = MobileWatchCompanion()
    static var isSupported: Bool { WCSession.isSupported() }
    let coordinator = RemoteConnectionCoordinator(connectionsAllowedInitially: false)
    private lazy var access = WatchConnectionAccess(watchEnabled: isEnabled) { [coordinator] allowed in
        coordinator.setConnectionsAllowed(allowed)
    }
    private var session: WCSession?
    private var cached = WatchAttentionSnapshot(isEnabled: false)
    private var cacheRevision: UInt64 = 0
    private var active: [UUID: WatchBackgroundOperation] = [:]
    private var answers: [String: Task<WatchResponse, Never>] = [:]
    private var completed: [String: WatchResponse] = [:]
    private var completionOrder: [String] = []

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: WatchCompanionSettings.enabledKey) }

    func setForegroundConnectionsAllowed(_ allowed: Bool, consumer: UUID) {
        access.setForegroundAllowed(allowed, consumer: consumer)
    }

    func install() {
        guard session == nil, WCSession.isSupported() else { return }
        if let bytes = UserDefaults.standard.data(forKey: WatchCompanionSettings.snapshotKey),
           let snapshot = try? JSONDecoder().decode(WatchAttentionSnapshot.self, from: bytes) { cached = snapshot }
        let session = WCSession.default
        session.delegate = self
        self.session = session
        session.activate()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: WatchCompanionSettings.enabledKey)
        access.setWatchEnabled(enabled)
        if !enabled {
            for operation in active.values { operation.finish() }
            answers.values.forEach { $0.cancel() }
            publish(.init(updatedAt: .now, isEnabled: false))
        } else {
            publish(.init(updatedAt: .now))
        }
    }

    /// Foreground feed updates are cheap. No watch timer keeps a host awake.
    func update(from feed: MultiHostFeed) {
        guard isEnabled else { return }
        let snapshot = WatchAttentionProjection.snapshot(from: feed.state, hosts: feed.hosts, previous: cached)
        guard snapshot.cards != cached.cards || snapshot.terminals != cached.terminals || snapshot.unavailableHosts != cached.unavailableHosts || !cached.isEnabled else { return }
        publish(snapshot)
    }

    private func publish(_ snapshot: WatchAttentionSnapshot) {
        cacheRevision &+= 1
        cached = snapshot
        guard let bytes = try? snapshot.encodedForTransfer() else { return }
        UserDefaults.standard.set(bytes, forKey: WatchCompanionSettings.snapshotKey)
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do { try session.updateApplicationContext(["snapshot": bytes]) }
        catch { /* An interactive refresh can still retrieve the cached state. */ }
    }

    private func handle(_ request: WatchRequest) async -> WatchResponse {
        guard isEnabled else { return .snapshot(.init(updatedAt: .now, isEnabled: false)) }
        if case .answer(_, let card, _) = request {
            let key = card.questionID
            if let response = completed[key] { return response }
            if let task = answers[key] { return await task.value }
            let task = Task { await perform(request) }
            answers[key] = task
            let response = await task.value
            answers[key] = nil
            // Remember accepted answers even if the watch missed the acknowledgement.
            if response == .answered {
                completed[key] = response
                completionOrder.append(key)
                if completionOrder.count > 100 { completed[completionOrder.removeFirst()] = nil }
            }
            return response
        }
        return await perform(request)
    }

    private func perform(_ request: WatchRequest) async -> WatchResponse {
        guard let token = access.beginWatchRequest() else { return .failure("Apple Watch access was turned off.") }
        let operation = WatchBackgroundOperation { [access] in access.endWatchRequest(token) }
        active[token] = operation
        let task = Task { await execute(request, lease: token) }
        operation.cancel = { task.cancel() }
        operation.identifier = UIApplication.shared.beginBackgroundTask(withName: "Watch request") {
            // UIKit invokes expiration handlers on the main thread. End the
            // assertion here even if signaling cannot unwind immediately.
            MainActor.assumeIsolated { operation.finish() }
        }
        defer {
            operation.finish()
            active[token] = nil
        }
        return await task.value
    }

    private func execute(_ request: WatchRequest, lease: UUID) async -> WatchResponse {
        let revision = cacheRevision
        let store = HostStore()
        await store.loadIfNeeded()
        guard access.isActive(lease), !Task.isCancelled else { return .failure("This watch request expired or access was turned off.") }
        let hosts = store.hosts.filter { coordinator.isPaired($0) }
        do {
            switch request {
            case .terminal(let target):
                guard let host = hosts.first(where: { $0.id == target.hostID }) else { return .failure("This Mac is no longer paired.") }
                let rows = try await coordinator.worktreePanes(for: host, wake: .now)
                let request = try WatchAttentionProjection.terminalRequest(target, rows: rows, host: host)
                guard access.isActive(lease), !Task.isCancelled else { return .failure("This watch request expired or access was turned off.") }
                switch try await coordinator.sendWorktreeManagement(request, to: host) {
                case .terminalText(let text):
                    guard access.isActive(lease), !Task.isCancelled else { return .failure("This watch request expired.") }
                    return .terminal(.init(targetID: target.id, text: text))
                case .error(let code, let message, _, _):
                    return .failure(code == "malformed-request" ? "Update Graftty on this Mac to view its terminal on the watch." : message)
                default: return .failure("The host couldn't read this terminal.")
                }
            case .refresh:
                var state = MultiHostFeedState()
                state.setHosts(hosts.map { .init(id: $0.id, label: $0.label, deviceID: $0.remoteDeviceID, isWakeable: false) })
                // A read does not start a sleeping cloud host.
                await withTaskGroup(of: (UUID, [WorktreePanes]?).self) { group in
                    for host in hosts {
                        group.addTask { @MainActor in
                            guard !Task.isCancelled else { return (host.id, nil) }
                            return (host.id, try? await self.coordinator.worktreePanes(for: host, wake: .never))
                        }
                    }
                    for await (hostID, rows) in group {
                        if let rows { state.apply(rows: rows, projects: [], from: hostID) }
                    }
                }
                guard access.isActive(lease), !Task.isCancelled else { return .failure("This watch request expired or access was turned off.") }
                let snapshot: WatchAttentionSnapshot
                if revision != cacheRevision { snapshot = cached }
                else {
                    snapshot = WatchAttentionProjection.snapshot(from: state, hosts: hosts, previous: cached)
                    publish(snapshot)
                }
                // Bound interactive responses as well as application context.
                return .snapshot(try JSONDecoder().decode(WatchAttentionSnapshot.self, from: snapshot.encodedForTransfer()))
            case .answer(_, let card, let text):
                guard let host = hosts.first(where: { $0.id == card.hostID }) else { return .failure("This Mac is no longer paired. Open Graftty on iPhone.") }
                let rows = try await coordinator.worktreePanes(for: host, wake: .now)
                let answer = try WatchAttentionProjection.answer(card, text: text, rows: rows, host: host)
                guard access.isActive(lease), !Task.isCancelled else { return .failure("This watch request expired or access was turned off.") }
                let response = try await coordinator.sendWorktreeManagement(answer, to: host)
                if let failure = AttentionAnswer.failureMessage(for: response) { return .failure(failure) }
                return .answered
            }
        } catch { return .failure(error.localizedDescription) }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if !self.isEnabled { self.publish(.init(updatedAt: .now, isEnabled: false)) }
            else { self.publish(self.cached) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        Task { @MainActor in
            let response: WatchResponse
            if messageData.count <= WatchRequest.maximumBytes, let request = try? JSONDecoder().decode(WatchRequest.self, from: messageData) {
                response = await self.handle(request)
            } else { response = .failure("Couldn't read this watch request. Update both apps.") }
            if let bytes = try? JSONEncoder().encode(response) { replyHandler(bytes) }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}

@MainActor
private final class WatchBackgroundOperation {
    var identifier: UIBackgroundTaskIdentifier = .invalid
    var cancel: (() -> Void)?
    private var finished = false
    private let release: () -> Void

    init(release: @escaping () -> Void) { self.release = release }

    func finish() {
        guard !finished else { return }
        finished = true
        cancel?()
        cancel = nil
        release()
        if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
}
#endif

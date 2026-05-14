import Foundation
import GrafttyKit

/// App-scoped owner of the push pipeline. Holds the device store, dedupe
/// table, desktop-activity monitor, APNs client, and clear service, and
/// exposes the three entry points the rest of GrafttyApp calls into:
///
/// * `handleAgentStop(...)` — fan out alert pushes for a fresh
///   agent-stop signal (called from `recordAgentStop`).
/// * `handleAttentionCleared(...)` — silent-remove pushes for previously
///   notified worktrees whose attention timer just fired or was cleared.
/// * `handleRegister(...)` — `/push/register` HTTP handler.
///
/// `@MainActor` because `CGEventActivitySource` lives on the main actor
/// (NSWorkspace + DistributedNotificationCenter observers). The async
/// handlers are called from `Task { await ... }` at every call site so
/// the actor hop happens at the boundary, not inside the orchestrator.
@MainActor
final class PushOrchestrator {
    // `deviceStore` is also reachable from the nonisolated
    // `handleRegister` HTTP path, so it's tagged `nonisolated`. It's
    // immutable and `PushDeviceStore` is `@unchecked Sendable` with its
    // own internal lock — off-main-thread access is safe.
    nonisolated let deviceStore: PushDeviceStore
    let dedupe: PushDedupeStore
    let activity: DesktopActivityMonitor
    let apns: ApnsClient
    let clearService: PushClearService
    let topic: String

    init?() {
        guard let config = PushConfig.loadFromMainBundle() else {
            NSLog("Graftty: push disabled — APNs config or .p8 missing")
            return nil
        }
        let source = CGEventActivitySource()
        let store = PushDeviceStore()
        let dedupe = PushDedupeStore()
        let activity = DesktopActivityMonitor(source: source)
        do {
            let jwt = try ApnsJWT(
                privateKeyPEM: config.privateKeyPEM,
                keyID: config.keyID,
                teamID: config.teamID
            )
            let session = URLSession(configuration: .default)
            let apns = ApnsClient(jwt: jwt, session: session, topic: config.topic)
            self.deviceStore = store
            self.dedupe = dedupe
            self.activity = activity
            self.apns = apns
            self.clearService = PushClearService(
                topic: config.topic,
                deviceStore: store,
                dedupe: dedupe,
                sender: apns
            )
            self.topic = config.topic
        } catch {
            NSLog("Graftty: push disabled — JWT init failed: \(error)")
            return nil
        }
    }

    /// Handle a fresh agent-stop signal: decide if a push should fire,
    /// build the alert envelope, fan out to every live device, and prune
    /// device tokens APNs reported as bad/unregistered.
    func handleAgentStop(payload: AgentStopNotificationPayload, worktreeName: String) async {
        guard AttentionPushDecider.shouldPush(
            payload: payload,
            isUserActiveOnDesktop: activity.isUserActiveOnDesktop,
            dedupe: dedupe
        ) else { return }
        let content = AgentStopNotification.content(
            runtime: payload.runtime,
            worktreeName: worktreeName,
            worktreePath: payload.worktreePath,
            sessionID: payload.sessionID,
            timestamp: payload.attentionTimestamp
        )
        do {
            let env = try ApnsEnvelope.alert(
                topic: topic,
                worktreePath: payload.worktreePath,
                attentionTimestamp: payload.attentionTimestamp,
                content: content
            )
            let devices = deviceStore.liveDevices()
            guard !devices.isEmpty else { return }
            let results = await apns.sendFanout(env, to: devices)
            for r in results where r.outcome == .badDeviceToken {
                try? deviceStore.remove(token: r.device.token)
            }
            dedupe.markPushed(
                worktree: payload.worktreePath,
                attentionTimestamp: payload.attentionTimestamp
            )
        } catch {
            NSLog("Graftty: push send failed: \(error)")
        }
    }

    /// Called from the `clearAttentionIfTimestamp` sites in GrafttyApp.
    /// Delegates to `PushClearService` which short-circuits unless we
    /// previously pushed an alert for this exact (path, timestamp).
    func handleAttentionCleared(worktreePath: String, attentionTimestamp: Date) async {
        await clearService.attentionCleared(
            worktreePath: worktreePath,
            attentionTimestamp: attentionTimestamp
        )
    }

    /// Route `/push/register` requests into the device store. The HTTP
    /// endpoint runs off the main thread and shouldn't pay for an actor
    /// hop — `PushDeviceStore` is `@unchecked Sendable` with internal
    /// locking, so the registration is safe from any thread.
    nonisolated func handleRegister(_ req: WebServer.PushRegisterRequest) -> WebServer.PushRegisterResponse {
        let now = Date()
        try? deviceStore.register(PushDevice(
            token: req.deviceToken,
            deviceName: req.deviceName,
            platform: req.platform,
            lastRegisteredAt: now
        ))
        return WebServer.PushRegisterResponse(registeredAt: now)
    }
}

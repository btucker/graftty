#if canImport(UIKit)
import Foundation
import UIKit
import UserNotifications

/// Snapshot of a host that the registrar can fan a `/push/register` POST out to.
/// `lastUsedAt` is non-optional here — `HostStore`'s conformance collapses
/// `Host.lastUsedAt ?? Host.addedAt` so a never-used host still has a usable
/// freshness timestamp (mirrors `HostStore.sorted`).
public struct PushTargetHost: Sendable, Equatable {
    public let baseURL: URL
    public let lastUsedAt: Date
    public init(baseURL: URL, lastUsedAt: Date) {
        self.baseURL = baseURL
        self.lastUsedAt = lastUsedAt
    }
}

/// Read-only seam over `HostStore` so `PushRegistrar` can be unit-tested
/// without standing up the real store. The protocol is `Sendable` so the
/// registrar (an actor) can safely capture it across the actor boundary;
/// the live `HostStore` (a `@MainActor` `@Observable` class) reaches it via
/// an `@unchecked Sendable` conformance that hops to `MainActor.assumeIsolated`
/// when reading.
public protocol PushHostSource: AnyObject, Sendable {
    var hosts: [PushTargetHost] { get }
}

public protocol PushRegisterNetwork: Sendable {
    func register(baseURL: URL, body: PushRegisterRequest) async throws
}

public struct PushRegisterRequest: Codable, Sendable, Equatable {
    public let deviceToken: String
    public let deviceName: String
    public let platform: String  // "ios"
    public init(deviceToken: String, deviceName: String, platform: String) {
        self.deviceToken = deviceToken
        self.deviceName = deviceName
        self.platform = platform
    }
}

/// Owns the captured APNs device token and fans out
/// `POST <host>/push/register` calls for every saved host the user has
/// touched in the last 90 days (PUSH-1.1). The actor serializes token
/// captures with the re-register sweeps so a foreground that races the
/// `didRegisterForRemoteNotificationsWithDeviceToken` callback can't see
/// a half-updated state.
public actor PushRegistrar {
    private let hostSource: PushHostSource
    private let network: PushRegisterNetwork
    private let deviceName: String
    private var deviceToken: String?

    /// Hosts older than this are treated as abandoned and skipped.
    private static let freshnessWindow: TimeInterval = 90 * 86_400

    public init(hostSource: PushHostSource, network: PushRegisterNetwork, deviceName: String) {
        self.hostSource = hostSource
        self.network = network
        self.deviceName = deviceName
    }

    public func deviceTokenDidArrive(token: String) {
        deviceToken = token
    }

    /// Asks for alert/sound/badge authorization and — only on grant —
    /// asks UIKit to register for remote notifications. Denying authorization
    /// short-circuits before the APNs handshake (PUSH-1.2), so we never
    /// receive a token and the subsequent `registerWithAllHosts` is a no-op.
    public func requestAuthorizationAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { return }
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            NSLog("PushRegistrar: authorization failed: \(error)")
        }
    }

    /// PUSH-1.1: fan out to every host with `lastUsedAt` within 90 days.
    /// Called from `didRegisterForRemoteNotificationsWithDeviceToken` and
    /// from `scenePhase == .active` after the registrar has a token.
    /// When no token has been captured yet (denied auth, or APNs callback
    /// has not fired), the method is a no-op so a foreground sweep
    /// before the token arrives doesn't blast empty `/push/register` POSTs.
    public func registerWithAllHosts() async {
        guard let token = deviceToken else { return }
        let cutoff = Date().addingTimeInterval(-Self.freshnessWindow)
        let live = hostSource.hosts.filter { $0.lastUsedAt > cutoff }
        let body = PushRegisterRequest(
            deviceToken: token, deviceName: deviceName, platform: "ios"
        )
        for host in live {
            do {
                try await network.register(baseURL: host.baseURL, body: body)
            } catch {
                NSLog("PushRegistrar: register at \(host.baseURL) failed: \(error)")
            }
        }
    }
}

public final class URLSessionPushNetwork: PushRegisterNetwork {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func register(baseURL: URL, body: PushRegisterRequest) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("push/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
#endif

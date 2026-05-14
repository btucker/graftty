import Foundation

public enum ApnsSendOutcome: Sendable, Equatable {
    case delivered
    case badDeviceToken
    case skippedNoKey
    case error(String)
}

public struct ApnsFanoutResult: Sendable, Equatable {
    public let device: PushDevice
    public let outcome: ApnsSendOutcome

    public init(device: PushDevice, outcome: ApnsSendOutcome) {
        self.device = device
        self.outcome = outcome
    }
}

public protocol ApnsFanoutSender: Sendable {
    func sendFanout(_ env: ApnsEnvelope, to devices: [PushDevice]) async -> [ApnsFanoutResult]
}

/// HTTP/2 sender to Apple's APNs gateway.
public actor ApnsClient: ApnsFanoutSender {
    private let jwt: ApnsJWT
    private let session: URLSession
    private let topic: String

    private var cachedEndpointHost: String?

    private static let productionHost = "api.push.apple.com"
    private static let sandboxHost = "api.sandbox.push.apple.com"

    public init(jwt: ApnsJWT, session: URLSession = URLSession(configuration: .default),
                topic: String) {
        self.jwt = jwt
        self.session = session
        self.topic = topic
    }

    /// Single-device send (mostly for tests). Production uses sendFanout.
    public func send(_ env: ApnsEnvelope, to device: PushDevice) async throws -> ApnsSendOutcome {
        try await send(env, to: device, host: cachedEndpointHost ?? Self.productionHost)
    }

    public func sendFanout(_ env: ApnsEnvelope, to devices: [PushDevice]) async -> [ApnsFanoutResult] {
        guard !devices.isEmpty else { return [] }
        let primary = cachedEndpointHost ?? Self.productionHost
        let primaryResults = await fanout(env, to: devices, host: primary)
        let allBad = primaryResults.allSatisfy { $0.outcome == .badDeviceToken }
        if allBad && primary == Self.productionHost {
            let fallback = await fanout(env, to: devices, host: Self.sandboxHost)
            if fallback.contains(where: { $0.outcome == .delivered }) {
                cachedEndpointHost = Self.sandboxHost
            }
            return fallback
        }
        if primaryResults.contains(where: { $0.outcome == .delivered }) {
            cachedEndpointHost = primary
        }
        return primaryResults
    }

    private func fanout(_ env: ApnsEnvelope, to devices: [PushDevice], host: String) async -> [ApnsFanoutResult] {
        await withTaskGroup(of: ApnsFanoutResult.self) { group in
            for d in devices {
                group.addTask { [self] in
                    let outcome = (try? await self.send(env, to: d, host: host)) ?? .error("dispatch failed")
                    return ApnsFanoutResult(device: d, outcome: outcome)
                }
            }
            var out: [ApnsFanoutResult] = []
            for await r in group { out.append(r) }
            return out
        }
    }

    private func send(_ env: ApnsEnvelope, to device: PushDevice, host: String) async throws -> ApnsSendOutcome {
        var req = URLRequest(url: URL(string: "https://\(host)/3/device/\(device.token)")!)
        req.httpMethod = "POST"
        req.httpBody = env.payload
        req.setValue("bearer \(try jwt.token())", forHTTPHeaderField: "authorization")
        req.setValue(env.topic, forHTTPHeaderField: "apns-topic")
        req.setValue(env.pushType.rawValue, forHTTPHeaderField: "apns-push-type")
        req.setValue(env.collapseID, forHTTPHeaderField: "apns-collapse-id")
        req.setValue(String(env.priority), forHTTPHeaderField: "apns-priority")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return .error("non-HTTP response") }
        switch http.statusCode {
        case 200: return .delivered
        case 400, 410:
            let reason = (try? JSONDecoder().decode([String: String].self, from: data))?["reason"] ?? "unknown"
            if reason == "BadDeviceToken" || reason == "Unregistered" { return .badDeviceToken }
            return .error("\(http.statusCode) \(reason)")
        case 429, 500, 503:
            return .error("transient \(http.statusCode)")
        default:
            return .error("status \(http.statusCode)")
        }
    }
}

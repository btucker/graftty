import Foundation

/// JSON body accepted by `POST /v1/rtc/offer`. Carries the client's SDP
/// offer plus identification fields the M1.3 attach handshake will
/// authenticate. In M1.2 the auth fields are forwarded to the handler
/// but not yet verified.
public struct SignalingOffer: Codable, Sendable, Equatable {
    public let clientDeviceID: String
    public let sdp: String
    public init(clientDeviceID: String, sdp: String) {
        self.clientDeviceID = clientDeviceID
        self.sdp = sdp
    }
}

/// JSON body returned by `POST /v1/rtc/offer` on success.
public struct SignalingAnswer: Codable, Sendable, Equatable {
    public let sdp: String
    public init(sdp: String) {
        self.sdp = sdp
    }
}

/// JSON body returned on signaling failure. Mirrors the existing
/// `{ "error": "<message>" }` shape used by other endpoints like
/// `POST /worktrees`.
public struct SignalingError: Codable, Sendable, Equatable {
    public let error: String
    public init(error: String) {
        self.error = error
    }
}

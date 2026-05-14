import Foundation

public struct PushConfig: Sendable {
    public let keyID: String
    public let teamID: String
    public let topic: String
    public let privateKeyPEM: String

    public init(keyID: String, teamID: String, topic: String, privateKeyPEM: String) {
        self.keyID = keyID
        self.teamID = teamID
        self.topic = topic
        self.privateKeyPEM = privateKeyPEM
    }

    /// Load from Info.plist (`APNsKeyID`, `APNsTeamID`, `APNsTopic`) + a
    /// `.p8` at `Resources/apns/AuthKey_<KEYID>.p8`. Returns `nil` if any
    /// component is missing — caller logs and disables push (matches the
    /// "missing key → silent skip" philosophy of NOTIF-1.3).
    public static func loadFromMainBundle() -> PushConfig? {
        let bundle = Bundle.main
        guard let keyID = bundle.object(forInfoDictionaryKey: "APNsKeyID") as? String,
              let teamID = bundle.object(forInfoDictionaryKey: "APNsTeamID") as? String,
              let topic = bundle.object(forInfoDictionaryKey: "APNsTopic") as? String,
              !keyID.isEmpty, !teamID.isEmpty, !topic.isEmpty
        else { return nil }
        guard let p8URL = bundle.url(forResource: "AuthKey_\(keyID)", withExtension: "p8",
                                     subdirectory: "apns") else { return nil }
        guard let pem = try? String(contentsOf: p8URL, encoding: .utf8) else { return nil }
        return PushConfig(keyID: keyID, teamID: teamID, topic: topic, privateKeyPEM: pem)
    }
}

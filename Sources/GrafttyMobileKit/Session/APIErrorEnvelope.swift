#if canImport(UIKit)
import Foundation

/// Shared decoder for the `{"error": "<msg>"}` envelope every Graftty
/// HTTP endpoint returns on 4xx/5xx. Lives alone so `CreateWorktreeClient`
/// and `DeleteWorktreeClient` don't carry the same private `Envelope`
/// struct twice.
public enum APIErrorEnvelope {
    public static func decode(_ data: Data) -> String? {
        struct Envelope: Decodable { let error: String? }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error
    }
}
#endif

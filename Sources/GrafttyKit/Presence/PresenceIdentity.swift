import Foundation

/// Identity used for presence publication, derived from the repo's git config.
public struct PresenceIdentity: Sendable, Equatable {
    public let name: String
    public let email: String

    public var slug: String { Self.slug(forEmail: email) }

    public enum ConfigScope: Sendable {
        case any
        case local

        var extraArgs: [String] {
            switch self {
            case .any: return []
            case .local: return ["--local"]
            }
        }
    }

    public enum IdentityError: Error, Equatable {
        case missingEmail
    }

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    /// @spec SYNC-1.3
    /// Slug = lowercased email with each run of non-alphanumeric characters
    /// collapsed to a single hyphen, trimmed of leading/trailing hyphens.
    public static func slug(forEmail email: String) -> String {
        let lowered = email.lowercased()
        var out = ""
        var pendingHyphen = false
        for scalar in lowered.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.append(Character(scalar))
            } else {
                pendingHyphen = true
            }
        }
        return out
    }

    /// Probes git config user.name / user.email at the repo. Email is
    /// required (it keys the presence ref); name falls back to the email's
    /// local part.
    public static func load(repoPath: String, scope: ConfigScope = .any) async throws -> PresenceIdentity {
        @Sendable func probe(_ key: String) async -> String? {
            guard let out = try? await GitRunner.captureAll(
                args: ["config"] + scope.extraArgs + [key], at: repoPath
            ), out.exitCode == 0 else { return nil }
            let value = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard let email = await probe("user.email") else {
            throw IdentityError.missingEmail
        }
        let name = await probe("user.name") ?? String(email.prefix(while: { $0 != "@" }))
        return PresenceIdentity(name: name, email: email)
    }
}

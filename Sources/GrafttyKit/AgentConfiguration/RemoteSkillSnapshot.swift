import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Skill content only. Authentication stores, settings, plugin caches and session state
/// are not part of this format. Transport must authenticate the parent separately.
public struct RemoteSkillSnapshot: Codable, Sendable, Equatable {
    public enum Scope: String, Codable, Sendable { case user, project }

    public struct File: Codable, Sendable, Equatable {
        public let scope: Scope
        /// Native layout relative to the user home or worktree, not a source Mac path.
        public let path: String
        public let contents: Data
        public let executable: Bool
        public init(scope: Scope, path: String, contents: Data, executable: Bool = false) {
            self.scope = scope; self.path = path; self.contents = contents; self.executable = executable
        }
    }

    public struct Limits: Sendable {
        public let maxFiles: Int
        public let maxFileBytes: Int
        public let maxTotalBytes: Int
        public init(maxFiles: Int = 4096, maxFileBytes: Int = 4 * 1024 * 1024, maxTotalBytes: Int = 16 * 1024 * 1024) {
            self.maxFiles = maxFiles; self.maxFileBytes = maxFileBytes; self.maxTotalBytes = maxTotalBytes
        }
    }

    public static let maximumEncodedBytes = 24 * 1024 * 1024
    public let version: Int
    public let runtime: TeamHookRuntime
    public let files: [File]

    public init(runtime: TeamHookRuntime, files: [File]) {
        version = 1; self.runtime = runtime; self.files = files.sorted { Self.key($0) < Self.key($1) }
    }

    public var revision: String { get throws { Self.digest(try encoded()) } }

    public func encoded() throws -> Data {
        try validate()
        let normalized = Self(runtime: runtime, files: files.sorted { Self.key($0) < Self.key($1) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(normalized)
        guard data.count <= Self.maximumEncodedBytes else { throw RemoteSkillError("Skill snapshot exceeds the encoded size limit") }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw RemoteSkillError("Skill snapshot exceeds the encoded size limit") }
        let snapshot: Self
        do { snapshot = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw RemoteSkillError("Invalid skill snapshot") }
        try snapshot.validate()
        return snapshot
    }

    public func validate(limits: Limits = .init()) throws {
        guard version == 1 else { throw RemoteSkillError("Unsupported skill snapshot version") }
        guard limits.maxFiles >= 0, limits.maxFileBytes >= 0, limits.maxTotalBytes >= 0,
              files.count <= limits.maxFiles else { throw RemoteSkillError("Skill snapshot exceeds the file count limit") }
        var paths = Set<String>()
        var total = 0
        var skills = Set<String>()
        var manifests = Set<String>()
        for file in files {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let roots = runtime == .codex ? [".agents", ".codex"] : [".claude"]
            guard components.count >= 4, components.count <= 32, file.path.utf8.count <= 1024,
                  roots.contains(components[0]), components[1] == "skills",
                  !components[2].hasPrefix("."),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\")
                    && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
                throw RemoteSkillError("Invalid skill destination path")
            }
            let key = Self.key(file)
            guard paths.insert(key.lowercased()).inserted else { throw RemoteSkillError("Duplicate skill destination path") }
            guard file.contents.count <= limits.maxFileBytes, file.contents.count <= limits.maxTotalBytes - total else {
                throw RemoteSkillError("Skill snapshot exceeds the content size limit")
            }
            total += file.contents.count
            try Self.checkContent(path: file.path, bytes: file.contents)
            let skill = file.scope.rawValue + "/" + components.prefix(3).joined(separator: "/")
            skills.insert(skill)
            if components.count == 4 && components[3] == "SKILL.md" { manifests.insert(skill) }
        }
        guard skills == manifests else { throw RemoteSkillError("Every exported skill must include SKILL.md") }
        // Reject file/directory collisions before touching the destination.
        for file in files {
            let parts = Self.key(file).lowercased().split(separator: "/")
            for end in 1..<parts.count where paths.contains(parts.prefix(end).joined(separator: "/")) {
                throw RemoteSkillError("Conflicting skill destination paths")
            }
        }
    }

    static func key(_ file: File) -> String { file.scope.rawValue + "/" + file.path }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// These exclusions catch credential artifacts, not arbitrary secrets embedded in prose.
    /// The caller must only export skill directories it intends to share with this worker.
    static func checkContent(path: String, bytes: Data) throws {
        let forbidden: Set<String> = [".ssh", ".aws", ".git", "auth.json", "credentials", "credentials.json", ".credentials.json",
                                      "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"]
        for component in path.lowercased().split(separator: "/").map(String.init) {
            guard !forbidden.contains(component), component != ".env", !component.hasPrefix(".env."),
                  !["pem", "key", "p12", "pfx"].contains((component as NSString).pathExtension) else {
                throw RemoteSkillError("Credential or repository metadata file is not eligible for skill export: \(path)")
            }
        }
        for marker in ["-----BEGIN PRIVATE KEY-----", "-----BEGIN OPENSSH PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----",
                       "-----BEGIN EC PRIVATE KEY-----", "-----BEGIN ENCRYPTED PRIVATE KEY-----"] {
            guard bytes.range(of: Data(marker.utf8)) == nil else { throw RemoteSkillError("Private key material is not eligible for skill export: \(path)") }
        }
    }
}

public struct RemoteSkillError: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

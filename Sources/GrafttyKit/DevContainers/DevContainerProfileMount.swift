import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Only this placement directory is exposed to its container. It starts empty;
/// it never mounts the host home, another placement, or a parent's credentials.
struct DevContainerProfileMount {
    let directory: String
    let probe: URL
    private let nonce: String
    var argument: String { "type=bind,source=\(directory),target=\(directory)" }

    init(directory root: URL, operationID: UUID) throws {
        func validatePath(_ path: String) throws {
            guard path.hasPrefix("/"), path.utf8.count < 3072, !path.contains(","),
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw RemoteSkillError("Agent profile mount needs an absolute path without commas or control characters")
            }
        }
        func ensurePrivateDirectory(_ url: URL) throws {
            if try SkillFileIO.attributesIfPresent(url) == nil {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
                throw RemoteSkillError("Agent profile directories must be owned by the host user, private (0700), and not symlinks")
            }
        }
        try validatePath(root.path)
        try ensurePrivateDirectory(root)
        let physical = try SkillFileIO.physical(root).appendingPathComponent(operationID.uuidString.lowercased())
        try validatePath(physical.path)
        try ensurePrivateDirectory(physical)
        directory = physical.path
        nonce = UUID().uuidString.lowercased()
        probe = physical.appendingPathComponent(".mount-probe-" + nonce)
        try Data(nonce.utf8).write(to: probe, options: .withoutOverwriting)
    }

    var verificationScript: String {
        let quote = WorktreeAgentLaunchCommand.shellLiteral
        return """
        set -eu
        test "$(id -u)" = \(geteuid()) || { printf '%s\n' 'Agent profile requires the container remote user UID to match the host user' >&2; exit 1; }
        test "$(cat \(quote(probe.path)))" = \(quote(nonce)) || { printf '%s\n' 'Agent profile host mount is not visible in the container' >&2; exit 1; }
        test -d \(quote(directory)) && test -w \(quote(directory)) && test ! -L \(quote(directory))
        """
    }

    func removeProbe() { try? FileManager.default.removeItem(at: probe) }
}

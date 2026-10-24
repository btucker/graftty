import Foundation

public struct RemoteSkillInstallation: Codable, Sendable, Equatable {
    public let directory: URL
    public let revision: String
    public let runtime: TeamHookRuntime
    public var userDirectory: URL { directory.appendingPathComponent("user", isDirectory: true) }
    public var projectDirectory: URL { directory.appendingPathComponent("project", isDirectory: true) }
}

/// Stages native-layout skill trees for the provisioning layer to mount in the
/// agent's user home and worktree. Does not change the host user's global settings.
/// Parent and project IDs must come from the caller's authenticated assignment;
/// hashing a supplied ID is path isolation, not authorization.
public struct RemoteSkillStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func load(runtime: TeamHookRuntime, revision: String, parentID: String, projectID: String) throws -> RemoteSkillSnapshot {
        guard revision.count == 64, revision.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw RemoteSkillError("Invalid skill revision")
        }
        let root = try SkillFileIO.physical(directory)
        let relative = [RemoteSkillSnapshot.digest(Data(parentID.utf8)), RemoteSkillSnapshot.digest(Data(projectID.utf8)), runtime.rawValue, revision].joined(separator: "/")
        let descriptor = try SkillFileIO.openDirectory(root)
        defer { GrafttyPOSIX.close(descriptor) }
        let bytes = try SkillFileIO.read(directory: descriptor, path: relative + "/snapshot.json", maximum: RemoteSkillSnapshot.maximumEncodedBytes).bytes
        let snapshot = try RemoteSkillSnapshot.decode(bytes)
        guard snapshot.runtime == runtime, try snapshot.revision == revision else { throw RemoteSkillError("Staged skills do not match the requested revision") }
        let installed = RemoteSkillInstallation(directory: root.appendingPathComponent(relative, isDirectory: true), revision: revision, runtime: runtime)
        try verify(installed, snapshot: snapshot, encoded: snapshot.encoded())
        return snapshot
    }

    public func stage(_ snapshot: RemoteSkillSnapshot, parentID: String, projectID: String) throws -> RemoteSkillInstallation {
        try stage(snapshot, parentID: parentID, projectID: projectID, beforePublish: {})
    }

    func stage(_ snapshot: RemoteSkillSnapshot, parentID: String, projectID: String,
               beforePublish: () throws -> Void) throws -> RemoteSkillInstallation {
        let encoded = try snapshot.encoded()
        guard [parentID, projectID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\0") }) else {
            throw RemoteSkillError("Parent and project identities must be nonempty and bounded")
        }
        let revision = RemoteSkillSnapshot.digest(encoded)
        let fm = FileManager.default
        // The caller chooses the local store root. No snapshot path participates
        // in its identity or the lock filename.
        try ensureDirectory(directory)
        let root = try SkillFileIO.physical(directory)
        let parent = try childDirectory(root, RemoteSkillSnapshot.digest(Data(parentID.utf8)))
        let project = try childDirectory(parent, RemoteSkillSnapshot.digest(Data(projectID.utf8)))
        let runtime = try childDirectory(project, snapshot.runtime.rawValue)
        let lock = try ExclusiveFileLock(url: runtime.appendingPathComponent(".install.lock"))
        return try withExtendedLifetime(lock) {
            let installed = RemoteSkillInstallation(directory: runtime.appendingPathComponent(revision, isDirectory: true), revision: revision, runtime: snapshot.runtime)
            if try SkillFileIO.attributesIfPresent(installed.directory) != nil {
                try verify(installed, snapshot: snapshot, encoded: encoded)
                return installed
            }
            let staging = try childDirectory(runtime, ".staging-" + UUID().uuidString.lowercased())
            defer { try? fm.removeItem(at: staging) }
            for scope in [RemoteSkillSnapshot.Scope.user, .project] { _ = try childDirectory(staging, scope.rawValue) }
            for file in snapshot.files {
                let destination = staging.appendingPathComponent(RemoteSkillSnapshot.key(file))
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try file.contents.write(to: destination, options: .withoutOverwriting)
                try fm.setAttributes([.posixPermissions: file.executable ? 0o500 : 0o400], ofItemAtPath: destination.path)
            }
            let manifest = staging.appendingPathComponent("snapshot.json")
            try encoded.write(to: manifest, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: manifest.path)
            try beforePublish()
            // Rename only a fully populated tree. There is no mutable "current"
            // symlink: each launcher retains the returned exact revision path.
            try fm.moveItem(at: staging, to: installed.directory)
            return installed
        }
    }

    private func verify(_ installed: RemoteSkillInstallation, snapshot: RemoteSkillSnapshot, encoded: Data) throws {
        guard try SkillFileIO.attributesIfPresent(installed.directory)?[.type] as? FileAttributeType == .typeDirectory else {
            throw RemoteSkillError("Existing skill revision is not a directory")
        }
        let descriptor = try SkillFileIO.openDirectory(installed.directory)
        defer { GrafttyPOSIX.close(descriptor) }
        let manifest = try SkillFileIO.read(directory: descriptor, path: "snapshot.json", maximum: RemoteSkillSnapshot.maximumEncodedBytes)
        guard manifest.bytes == encoded else { throw RemoteSkillError("Existing skill revision has changed") }
        var expected = Set(["snapshot.json", "user", "project"])
        for file in snapshot.files {
            let path = RemoteSkillSnapshot.key(file)
            let actual = try SkillFileIO.read(directory: descriptor, path: path, maximum: file.contents.count)
            guard actual.bytes == file.contents, actual.executable == file.executable else { throw RemoteSkillError("Existing skill revision has changed") }
            let parts = path.split(separator: "/")
            for end in 1...parts.count { expected.insert(parts.prefix(end).joined(separator: "/")) }
        }
        guard let enumerator = FileManager.default.enumerator(at: installed.directory, includingPropertiesForKeys: nil,
                                                              errorHandler: { _, _ in false }) else {
            throw RemoteSkillError("Cannot inspect existing skill revision")
        }
        var actual = Set<String>()
        for case let url as URL in enumerator {
            let path = String(url.path.dropFirst(installed.directory.path.count + 1))
            guard expected.contains(path) else { throw RemoteSkillError("Existing skill revision contains unexpected files") }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory || attributes[.type] as? FileAttributeType == .typeRegular else {
                throw RemoteSkillError("Existing skill revision contains links or special files")
            }
            actual.insert(path)
        }
        guard expected == actual else { throw RemoteSkillError("Existing skill revision is incomplete") }
    }

    private func childDirectory(_ parent: URL, _ name: String) throws -> URL {
        let child = parent.appendingPathComponent(name, isDirectory: true)
        try ensureDirectory(child)
        return child
    }

    private func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if let attributes = try SkillFileIO.attributesIfPresent(url) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw RemoteSkillError("Skill store directory must not be a link or file") }
        } else {
            // The selected store's parent is trusted local configuration. Resolve
            // existing ancestors once; all identity-derived children reject links.
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

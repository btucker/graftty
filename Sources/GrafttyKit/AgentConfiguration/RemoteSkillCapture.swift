import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public extension RemoteSkillSnapshot {
    static func read(from url: URL) throws -> Self {
        let directory = try SkillFileIO.openDirectory(SkillFileIO.physical(url.deletingLastPathComponent()))
        defer { GrafttyPOSIX.close(directory) }
        return try decode(SkillFileIO.read(directory: directory, path: url.lastPathComponent, maximum: maximumEncodedBytes).bytes)
    }

    /// An export is private from creation and never overwrites an existing file.
    func write(to url: URL) throws {
        let data = try encoded()
        let directory = try SkillFileIO.openDirectory(SkillFileIO.physical(url.deletingLastPathComponent()))
        defer { GrafttyPOSIX.close(directory) }
        let fd = openat(directory, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw RemoteSkillError("Cannot create skill export; choose a new file in an existing directory") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        do { try handle.write(contentsOf: data); try handle.synchronize() }
        catch { _ = unlinkat(directory, url.lastPathComponent, 0); throw error }
    }

    /// Captures explicit native skill roots, never recursively copies an agent home.
    /// Custom runtime homes are source roots only; output uses portable native layouts.
    static func capture(runtime: TeamHookRuntime, home: URL, workspace: URL,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        limits: Limits = .init()) throws -> Self {
        guard limits.maxFiles >= 0, limits.maxFiles <= 4096, limits.maxFileBytes >= 0,
              limits.maxFileBytes <= 4 * 1024 * 1024, limits.maxTotalBytes >= 0,
              limits.maxTotalBytes <= 16 * 1024 * 1024 else { throw RemoteSkillError("Invalid skill capture limits") }
        // A missing workspace must not masquerade as a valid empty project.
        for source in [home, workspace] {
            let descriptor = try SkillFileIO.openDirectory(SkillFileIO.physical(source))
            GrafttyPOSIX.close(descriptor)
        }
        struct Source {
            let base: URL
            let relative: String
            let destination: String
            let scope: Scope
            var directory: URL { base.appendingPathComponent(relative) }
        }
        func configHome(_ key: String, fallback: String) throws -> URL {
            guard let value = environment[key], !value.isEmpty else { return home.appendingPathComponent(fallback) }
            guard value.hasPrefix("/") else { throw RemoteSkillError("\(key) must be an absolute path") }
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        let sources: [Source]
        switch runtime {
        case .codex:
            sources = [
                Source(base: home, relative: ".agents/skills", destination: ".agents/skills", scope: .user),
                Source(base: try configHome("CODEX_HOME", fallback: ".codex"), relative: "skills", destination: ".codex/skills", scope: .user),
                Source(base: workspace, relative: ".agents/skills", destination: ".agents/skills", scope: .project),
                Source(base: workspace, relative: ".codex/skills", destination: ".codex/skills", scope: .project)
            ]
        case .claude:
            sources = [
                Source(base: try configHome("CLAUDE_CONFIG_DIR", fallback: ".claude"), relative: "skills", destination: ".claude/skills", scope: .user),
                Source(base: workspace, relative: ".claude/skills", destination: ".claude/skills", scope: .project)
            ]
        }
        var files: [File] = []
        var total = 0
        var nodes = 0
        let fm = FileManager.default
        // Resolve each configured root once. Cross-root skill links may point to
        // another selected root, but never to arbitrary home or repository files.
        var roots: [(Source, URL)] = []
        for source in sources {
            guard let attributes = try SkillFileIO.attributesIfPresent(source.directory) else { continue }
            guard attributes[.type] as? FileAttributeType == .typeDirectory || attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                throw RemoteSkillError("Skill root is not a directory: \(source.directory.path)")
            }
            let root = try SkillFileIO.physical(source.directory)
            let base = try SkillFileIO.physical(source.base)
            guard root.path.hasPrefix(base.path + "/") else { throw RemoteSkillError("Skill root escapes its configured home or project") }
            roots.append((source, root))
        }
        for (source, root) in roots {
            let approvedRoots = roots.filter { $0.0.scope == source.scope }.map { $0.1.path }
            let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard children.count <= limits.maxFiles else { throw RemoteSkillError("Too many skill directory entries") }
            for child in children where !child.lastPathComponent.hasPrefix(".") {
                let skill = try SkillFileIO.physical(child)
                guard approvedRoots.contains(where: { skill.path.hasPrefix($0 + "/") }) else {
                    throw RemoteSkillError("Skill link escapes approved skill roots: \(child.lastPathComponent)")
                }
                let attributes = try fm.attributesOfItem(atPath: skill.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
                guard try SkillFileIO.attributesIfPresent(skill.appendingPathComponent("SKILL.md")) != nil else { continue }
                let descriptor = try SkillFileIO.openDirectory(skill)
                defer { GrafttyPOSIX.close(descriptor) }
                func visit(_ directory: URL, relative: String, ancestors: Set<String>, depth: Int) throws {
                    guard depth < 24 else { throw RemoteSkillError("Skill directory nesting exceeds the limit") }
                    let physical = try SkillFileIO.physical(directory)
                    guard physical.path == skill.path || physical.path.hasPrefix(skill.path + "/"), !ancestors.contains(physical.path) else {
                        throw RemoteSkillError("Skill contains an escaping link or directory cycle")
                    }
                    var ancestors = ancestors; ancestors.insert(physical.path)
                    let children = try fm.contentsOfDirectory(at: physical, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                    guard children.count <= limits.maxFiles else { throw RemoteSkillError("Too many skill directory entries") }
                    for item in children {
                        nodes += 1
                        guard nodes <= limits.maxFiles * 2 + 32 else { throw RemoteSkillError("Too many skill directory entries") }
                        let logical = relative.isEmpty ? item.lastPathComponent : relative + "/" + item.lastPathComponent
                        let target = try SkillFileIO.physical(item)
                        guard target.path.hasPrefix(skill.path + "/") else { throw RemoteSkillError("Skill contains an escaping link: \(logical)") }
                        try checkContent(path: logical, bytes: Data())
                        let attributes = try fm.attributesOfItem(atPath: target.path)
                        if attributes[.type] as? FileAttributeType == .typeDirectory {
                            try visit(target, relative: logical, ancestors: ancestors, depth: depth + 1)
                        } else {
                            guard files.count < limits.maxFiles else { throw RemoteSkillError("Skill snapshot exceeds the file count limit") }
                            let relativeTarget = String(target.path.dropFirst(skill.path.count + 1))
                            let captured = try SkillFileIO.read(directory: descriptor, path: relativeTarget,
                                                               maximum: min(limits.maxFileBytes, limits.maxTotalBytes - total))
                            try checkContent(path: logical, bytes: captured.bytes)
                            total += captured.bytes.count
                            files.append(File(scope: source.scope, path: source.destination + "/" + child.lastPathComponent + "/" + logical,
                                              contents: captured.bytes, executable: captured.executable))
                        }
                    }
                }
                try visit(skill, relative: "", ancestors: [], depth: 0)
            }
        }
        let snapshot = Self(runtime: runtime, files: files)
        try snapshot.validate(limits: limits)
        return snapshot
    }
}

/// Nonblocking descriptor reads avoid following a raced link or waiting on a FIFO.
enum SkillFileIO {
    static func physical(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else { throw RemoteSkillError("Cannot resolve skill path: \(url.path)") }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    static func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    static func openDirectory(_ url: URL) throws -> Int32 {
        let root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { throw RemoteSkillError("Cannot open filesystem root") }
        defer { GrafttyPOSIX.close(root) }
        let fd = GrafttyPOSIX.openBeneath(directoryFD: root, relativePath: String(url.path.dropFirst()))
        guard fd >= 0 else { throw RemoteSkillError("Cannot open skill directory without following links") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            GrafttyPOSIX.close(fd); throw RemoteSkillError("Skill source is not a directory")
        }
        return fd
    }

    static func read(directory: Int32, path: String, maximum: Int) throws -> (bytes: Data, executable: Bool) {
        guard maximum >= 0 else { throw RemoteSkillError("Invalid skill byte limit") }
        let fd = GrafttyPOSIX.openBeneath(directoryFD: directory, relativePath: path)
        guard fd >= 0 else { throw RemoteSkillError("Cannot read skill file without following links: \(path)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw RemoteSkillError("Skill content must be a regular file") }
        guard before.st_size >= 0, before.st_size <= maximum else { throw RemoteSkillError("Skill file exceeds the size limit") }
        let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
        var after = stat()
        guard bytes.count <= maximum, fstat(fd, &after) == 0, before.st_size == after.st_size, bytes.count == after.st_size,
              before.st_mode == after.st_mode else { throw RemoteSkillError("Skill file changed during capture or exceeded the size limit") }
        return (bytes, before.st_mode & 0o111 != 0)
    }
}

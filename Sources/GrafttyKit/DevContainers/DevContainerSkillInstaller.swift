import Foundation

/// Uses the project's Dev Container CLI execution context. Only skill content
/// crosses this boundary; the container's native tools and login remain its own.
public enum DevContainerSkillInstaller {
    public static func install(_ snapshots: [RemoteSkillSnapshot], workspace: String,
                               execArguments: [String], operationID: UUID,
                               executor: any CLIExecutor) async throws -> String {
        try RemoteSkillTransferReceiver.validate(try snapshots.map { .init(runtime: $0.runtime.rawValue, revision: try $0.revision) })
        func run(_ script: String) async throws -> String {
            try Task.checkCancellation()
            let result = try await executor.run(command: "devcontainer", args: execArguments + ["/bin/sh", "-c", "set -eu\numask 077\n" + script],
                                                at: workspace, timeout: .seconds(60))
            guard result.exitCode == 0 else { throw DevContainerPreparationError(stage: "agent-skills", message: "Skill installation failed: \(result.stderr.prefix(2048))") }
            try Task.checkCancellation()
            return result.stdout
        }
        let quote = WorktreeAgentLaunchCommand.shellLiteral
        // Native exec chooses the remote user and working directory. Neither
        // the Mac's home nor the host-side worktree path is valid here.
        let home = try await run("printf '%s' \"$HOME\"")
        guard home.hasPrefix("/"), home.utf8.count < 4096,
              !home.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RemoteSkillError("Container did not report a usable home directory")
        }
        let prefix = (home as NSString).appendingPathComponent(".graftty-skills-" + operationID.uuidString.lowercased() + "-")
        let output = try await run("command -v base64 >/dev/null\ncommand -v diff >/dev/null\nmktemp -d " + quote(prefix + "XXXXXXXX"))
        let root = output.trimmingCharacters(in: .newlines)
        guard root.hasPrefix(prefix), root.utf8.count < 4096,
              !root.dropFirst(prefix.count).isEmpty,
              root.dropFirst(prefix.count).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw RemoteSkillError("Container did not create an isolated skill directory")
        }
        let profile = root + "/home"
        var commands = ["mkdir -p " + [".agents/skills", ".codex/skills", ".claude/skills"].map { quote(profile + "/" + $0) }.joined(separator: " ")]
        var userSkills: [(source: String, destination: String)] = []
        var projectSkills: [(source: String, destination: String)] = []
        for snapshot in snapshots {
            var seen = Set<String>()
            for file in snapshot.files {
                let source = root + "/source/" + snapshot.runtime.rawValue + "/" + RemoteSkillSnapshot.key(file)
                commands.append("mkdir -p " + quote((source as NSString).deletingLastPathComponent))
                commands.append("(set -C; : > " + quote(source) + ")")
                let encoded = Array(file.contents.base64EncodedString().utf8)
                for offset in stride(from: 0, to: encoded.count, by: 24_000) {
                    let part = String(decoding: encoded[offset..<min(offset + 24_000, encoded.count)], as: UTF8.self)
                    commands.append("printf '%s' " + quote(part) + " | base64 -d >> " + quote(source))
                }
                commands.append("chmod " + (file.executable ? "500 " : "400 ") + quote(source))
                let path = file.path.split(separator: "/").prefix(3).joined(separator: "/")
                if seen.insert(file.scope.rawValue + "/" + path).inserted {
                    let source = root + "/source/" + snapshot.runtime.rawValue + "/" + file.scope.rawValue + "/" + path
                    if file.scope == .user { userSkills.append((source, profile + "/" + path)) }
                    else { projectSkills.append((source, "./" + path)) }
                }
            }
        }
        // Linux limits each argv string to 128 KiB. Bound complete scripts well
        // below that limit, including shell quoting and long destination paths.
        func batches(_ commands: [String]) -> [String] {
            var result: [String] = []; var current = ""
            for command in commands {
                if current.utf8.count + command.utf8.count > 48_000 { result.append(current); current = "" }
                current += command + "\n"
            }
            if !current.isEmpty { result.append(current) }
            return result
        }
        for batch in batches(commands) { _ = try await run(batch) }
        // Check every project destination before publishing any of them. An
        // existing identical checked-in skill is reused; a conflict is explicit.
        var checks: [String] = []
        for skill in projectSkills {
            let components = skill.destination.split(separator: "/").map(String.init)
            for end in 1...components.count {
                let path = components.prefix(end).joined(separator: "/")
                checks.append("test ! -L " + quote(path) + " || { printf '%s\\n' " + quote("Project skill path is a symlink: " + path) + " >&2; exit 1; }")
            }
            checks.append("if test -e " + quote(skill.destination) + "; then\n" +
                "test -d " + quote(skill.destination) + "\n" +
                "test -z \"$(find " + quote(skill.destination) + " ! -type f ! -type d -print)\"\n" +
                "diff -r " + quote(skill.source) + " " + quote(skill.destination) + " >/dev/null || { printf '%s\\n' " + quote("Project skill conflicts with the selected revision: " + skill.destination) + " >&2; exit 1; }\nfi")
        }
        for snapshot in snapshots {
            for file in snapshot.files where file.scope == .project {
                let destination = "./" + file.path
                checks.append("if test -e " + quote(destination) + "; then test " + (file.executable ? "-x " : "! -x ") + quote(destination) + "; fi")
            }
        }
        for batch in batches(checks) { _ = try await run(batch) }
        var publish = userSkills.map { "ln -s " + quote($0.source) + " " + quote($0.destination) }
        for skill in projectSkills {
            // Project files use ordinary checkout permissions so the host Git
            // process can read them even when the container uses a different UID.
            publish.append("if test ! -e " + quote(skill.destination) + "; then\n(umask 022; mkdir -p " + quote((skill.destination as NSString).deletingLastPathComponent) +
                ")\ncp -R " + quote(skill.source) + " " + quote(skill.destination) + "\nchmod -R u+w,go+rX " + quote(skill.destination) + "\nfi")
        }
        for batch in batches(publish) { _ = try await run(batch) }
        return profile
    }
}

import Foundation

/// Uses the project's Dev Container CLI execution context. Only skill content
/// crosses this boundary; the container's native tools and login remain its own.
public enum DevContainerSkillInstaller {
    public static func install(_ snapshots: [RemoteSkillSnapshot], workspace: String,
                               execArguments: [String], operationID: UUID,
                               executor: any CLIExecutor, profileDirectory: String? = nil) async throws -> String {
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
        let home: String
        if let profileDirectory { home = profileDirectory }
        else { home = try await run("printf '%s' \"$HOME\"") }
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
        func reject(_ message: String) -> String { "{ printf '%s\\n' " + quote(message) + " >&2; exit 1; }" }
        func pathChecks(_ destination: String) -> String {
            let components = destination.split(separator: "/").map(String.init)
            return (1...components.count).map { end in
                let path = quote(components.prefix(end).joined(separator: "/"))
                return "test ! -L " + path + " || " + reject("Project skill path is a symlink: " + destination) + "\n" +
                    "if test -e " + path + "; then test -d " + path + " || " + reject("Project skill path is not a directory: " + destination) + "; fi\n"
            }.joined()
        }
        func contentChecks(_ skill: (source: String, destination: String), required: Bool) -> String {
            let destination = quote(skill.destination)
            let conflict = reject("Project skill conflicts with the selected revision: " + skill.destination)
            return pathChecks(skill.destination) + (required ? "test -d " + destination + " || " + conflict + "\n" : "") +
                "if test -e " + destination + "; then\n" +
                "test -z \"$(find " + destination + " ! -type f ! -type d -print)\" || " + conflict + "\n" +
                "diff -r " + quote(skill.source) + " " + destination + " >/dev/null || " + conflict + "\nfi\n"
        }
        func validation(required: Bool) -> [String] {
            var checks = projectSkills.map { contentChecks($0, required: required) }
            for snapshot in snapshots {
                for file in snapshot.files where file.scope == .project {
                    let destination = quote("./" + file.path)
                    let mode = "test " + (file.executable ? "-x " : "! -x ") + destination + " || " + reject("Project skill executable mode conflicts: " + file.path)
                    checks.append(required ? mode : "if test -e " + destination + "; then " + mode + "; fi")
                }
            }
            return checks
        }
        // Check the whole set before publication, then recheck when reusing a
        // destination and after all writes. Other filesystem writers do not
        // share this actor's serialization.
        for batch in batches(validation(required: false)) { _ = try await run(batch) }
        var publish = userSkills.map { "ln -s " + quote($0.source) + " " + quote($0.destination) }
        for skill in projectSkills {
            let parent = (skill.destination as NSString).deletingLastPathComponent
            // Stage on the destination filesystem and never merge into or
            // replace a concurrent creator's directory. Probe real behavior,
            // including no-clobber skips whose exit status varies by Coreutils
            // version, instead of trusting a flag name or exit status alone.
            // This prerequisite applies only to missing project skills.
            publish.append(contentChecks(skill, required: false) + """
            if test ! -e \(quote(skill.destination)); then
              (
                (umask 022; mkdir -p \(quote(parent)))
                \(pathChecks(parent))
                stage=$(mktemp -d \(quote(parent + "/.graftty-skill.XXXXXXXX")))
                trap 'rm -rf "$stage"' EXIT
                trap 'exit 130' HUP INT TERM
                mover=
                for candidate in mv gmv; do
                  mkdir "$stage/probe-source" "$stage/probe-destination"
                  printf source > "$stage/probe-source/source"
                  printf keep > "$stage/probe-destination/keep"
                  probe_status=0
                  "$candidate" -T --no-clobber "$stage/probe-source" "$stage/probe-destination" 2>/dev/null || probe_status=$?
                  if { test "$probe_status" -eq 0 || test "$probe_status" -eq 1; } &&
                     test -d "$stage/probe-source" && test ! -L "$stage/probe-source" &&
                     test "$(cat "$stage/probe-source/source" 2>/dev/null)" = source &&
                     test "$(cat "$stage/probe-destination/keep" 2>/dev/null)" = keep &&
                     test ! -e "$stage/probe-destination/source" &&
                     test ! -e "$stage/probe-destination/probe-source" &&
                     "$candidate" -T --no-clobber "$stage/probe-source" "$stage/probe-moved" 2>/dev/null &&
                     test ! -e "$stage/probe-source" && test -d "$stage/probe-moved" &&
                     test "$(cat "$stage/probe-moved/source" 2>/dev/null)" = source; then
                    mover=$candidate
                    break
                  fi
                  rm -rf "$stage/probe-source" "$stage/probe-destination" "$stage/probe-moved"
                done
                test -n "$mover" || \(reject("Missing project skills require GNU mv or gmv supporting -T --no-clobber; install GNU coreutils in the Dev Container"))
                cp -R \(quote(skill.source)) "$stage/content"
                chmod -R u+w,go+rX "$stage/content"
                \(pathChecks(parent))
                move_status=0
                "$mover" -T --no-clobber "$stage/content" \(quote(skill.destination)) || move_status=$?
                case "$move_status" in
                  0) ;;
                  1)
                    test -d "$stage/content" && test ! -L "$stage/content" &&
                    test -z "$(find "$stage/content" ! -type f ! -type d -print)" &&
                    diff -r \(quote(skill.source)) "$stage/content" >/dev/null || \(reject("Project skill publication failed without preserving its source: " + skill.destination))
                    ;;
                  *) \(reject("Project skill publication failed: " + skill.destination));;
                esac
                \(contentChecks(skill, required: true))
              )
            fi
            """)
        }
        for batch in batches(publish) { _ = try await run(batch) }
        for batch in batches(validation(required: true)) { _ = try await run(batch) }
        return profile
    }
}

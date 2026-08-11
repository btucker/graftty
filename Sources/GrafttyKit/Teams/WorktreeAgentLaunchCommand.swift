import Foundation

public struct PreparedWorktreeAgentLaunch {
    public let command: String?
    public let promptFile: URL?

    public init(command: String?, promptFile: URL?) {
        self.command = command
        self.promptFile = promptFile
    }

    public func discardPromptFile(fileManager: FileManager = .default) {
        guard let promptFile else { return }
        try? fileManager.removeItem(at: promptFile)
    }
}

public enum WorktreeAgentLaunchCommand {
    /// Leave ample room below macOS's process-wide argv + environment limit.
    /// Both supported interactive runtimes require their initial prompt as one
    /// argv element, so larger tasks must be sent after the session starts.
    // 128 KiB also keeps worst-case JSON escaping below the control socket's
    // 1 MiB request cap (a one-byte control scalar expands to six JSON bytes).
    public static let maximumPromptBytes = 128 * 1_024

    public static var oversizedPromptError: String {
        "agent prompts cannot exceed \(maximumPromptBytes) UTF-8 bytes; start with a shorter task and send follow-up context after launch"
    }

    /// An agent launched with no user task still needs one completed turn:
    /// Claude installs its async inbox watcher from the Stop hook. Without
    /// this bootstrap, a message sent after SessionStart can remain queued
    /// forever in an untouched session.
    public static let bootstrapPrompt = """
    This Graftty agent session was launched without a user task. During this initial turn, review any Graftty team messages included in the session context and respond when relevant to the scoped repository work. If there are none, briefly report that the session is ready, then wait for a task.
    """

    public static func validationError(prompt: String?) -> String? {
        guard let prompt else { return nil }
        if prompt.utf8.contains(0) {
            return "agent prompts cannot contain NUL bytes"
        }
        if prompt.utf8.count > maximumPromptBytes {
            return oversizedPromptError
        }
        return nil
    }

    public static func prepare(
        agent: TeamHookRuntime?,
        prompt: String?,
        exactCommand: String?,
        promptDirectory: URL = AppState.defaultDirectory
            .appendingPathComponent("agent-launch-prompts", isDirectory: true),
        fileManager: FileManager = .default
    ) throws -> PreparedWorktreeAgentLaunch {
        if let exactCommand {
            return PreparedWorktreeAgentLaunch(command: exactCommand, promptFile: nil)
        }
        guard let agent else {
            return PreparedWorktreeAgentLaunch(command: nil, promptFile: nil)
        }
        if let error = validationError(prompt: prompt) {
            throw NSError(
                domain: "WorktreeAgentLaunchCommand",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: error]
            )
        }

        try securePromptDirectory(promptDirectory, fileManager: fileManager)

        let promptFile = promptDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("prompt")
        let initialTask = prompt.flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        } ?? bootstrapPrompt
        guard fileManager.createFile(
            atPath: promptFile.path,
            contents: Data(initialTask.utf8),
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: promptFile.path]
            )
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: promptFile.path
            )
        } catch {
            try? fileManager.removeItem(at: promptFile)
            throw error
        }

        // The user's configured interactive shell only parses a simple command
        // plus one quoted argument. A known POSIX shell owns the loader syntax,
        // so csh/tcsh/fish users get the same behavior as zsh users. The
        // sentinel preserves trailing newlines stripped by command substitution.
        let fileLiteral = shellLiteral(promptFile.path)
        let loader = "_graftty_agent_prompt_file=\(fileLiteral); _graftty_agent_prompt=\"$(/bin/cat \"$_graftty_agent_prompt_file\"; _graftty_status=$?; /usr/bin/printf x; exit \"$_graftty_status\")\" && /bin/rm -f \"$_graftty_agent_prompt_file\" && _graftty_agent_prompt=\"${_graftty_agent_prompt%x}\" && exec \(agent.rawValue) -- \"$_graftty_agent_prompt\""
        let command = "/bin/sh -c \(shellLiteral(loader))"
        return PreparedWorktreeAgentLaunch(command: command, promptFile: promptFile)
    }

    public static func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Recovery for files orphaned by an app crash. Call this during app
    /// startup, when no in-memory worktree creation operation can still own an
    /// old prompt; pruning from a second CLI process could race a long Git hook.
    public static func pruneStalePromptFiles(
        in directory: URL = AppState.defaultDirectory
            .appendingPathComponent("agent-launch-prompts", isDirectory: true),
        fileManager: FileManager = .default,
        now: Date = Date()
    ) {
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        for file in recoveryPromptFiles(in: directory, fileManager: fileManager) {
            guard let values = try? file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ),
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    /// Snapshot files that predate the current app process. Startup recovery
    /// retains this exact list so its delayed pass cannot touch prompts created
    /// by live operations in the new process.
    public static func recoveryPromptFiles(
        in directory: URL = AppState.defaultDirectory
            .appendingPathComponent("agent-launch-prompts", isDirectory: true),
        fileManager: FileManager = .default
    ) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.filter { file in
            guard file.pathExtension == "prompt",
                  let values = try? file.resourceValues(forKeys: keys) else { return false }
            return values.isRegularFile == true
        }
    }

    public static func discardRecoveryPromptFiles(
        _ files: [URL],
        fileManager: FileManager = .default
    ) {
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }

    private static func securePromptDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: directory.path]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
    }
}

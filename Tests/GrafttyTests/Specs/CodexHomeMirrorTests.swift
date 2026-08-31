import Testing
import Foundation
@testable import GrafttyKit

@Suite("CodexHomeMirror — symlink farm and hooks merge")
struct CodexHomeMirrorTests {
    @Test("Symlinks durable source entries while generating managed hooks and config snapshots.")
    func symlinkFarmExcludesGeneratedFiles() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }

        try writeFile(src.appendingPathComponent("auth.json"), "{}")
        try writeFile(src.appendingPathComponent("history.jsonl"), "")
        try writeFile(src.appendingPathComponent("hooks.json"), "{\"existing\": true}")
        try writeFile(src.appendingPathComponent("config.toml"), "")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sessions"), withIntermediateDirectories: true)

        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()

        let fm = FileManager.default

        // Symlinks for non-overridden entries.
        let authLink = dst.appendingPathComponent("auth.json")
        let resolved = try fm.destinationOfSymbolicLink(atPath: authLink.path)
        #expect(resolved.contains("auth.json"))

        let sessionsLink = dst.appendingPathComponent("sessions")
        let sessionsTarget = try? fm.destinationOfSymbolicLink(atPath: sessionsLink.path)
        #expect(sessionsTarget?.hasSuffix("sessions") == true)

        // Real files (not symlinks) for generated files.
        let hooks = dst.appendingPathComponent("hooks.json")
        let hooksTarget = try? fm.destinationOfSymbolicLink(atPath: hooks.path)
        #expect(hooksTarget == nil)  // Not a symlink.

        let config = dst.appendingPathComponent("config.toml")
        let configTarget = try? fm.destinationOfSymbolicLink(atPath: config.path)
        #expect(configTarget == nil)
    }

    @Test("@spec TEAM-IDLE-1.1: When Graftty synthesizes a managed CODEX_HOME, the application shall preserve user Codex hooks and replace stale Graftty delivery hooks; while legacy wrapper hooks are enabled it shall add SessionStart plus attention-only UserPromptSubmit, PostToolUse, and blocking question or plan-review hooks without adding pre-review permission hooks, and while provider plugins are enabled it shall leave those hooks to the plugin.")
    func hooksUnionMerge() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }

        try writeFile(src.appendingPathComponent("hooks.json"), """
        {
          "hooks": {
            "SessionStart": [
              { "hooks": [{ "type": "command", "command": "/path/to/user-script.sh" }] }
            ]
          }
        }
        """)

        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()

        let mergedData = try Data(contentsOf: dst.appendingPathComponent("hooks.json"))
        let merged = try JSONSerialization.jsonObject(with: mergedData) as! [String: Any]
        let hooks = merged["hooks"] as! [String: Any]
        let sessionStart = hooks["SessionStart"] as! [[String: Any]]
        // User's matcher-group + graftty's = 2.
        #expect(sessionStart.count == 2)
        let commands = sessionStart.flatMap { group -> [String] in
            let handlers = (group["hooks"] as? [[String: Any]]) ?? []
            return handlers.compactMap { $0["command"] as? String }
        }
        #expect(commands.contains("/path/to/user-script.sh"))
        #expect(commands.contains(where: { $0.hasPrefix("/usr/local/bin/graftty team hook codex") }))

        // Re-running rebuild is idempotent (graftty entries strip-and-replace, not duplicate).
        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()
        let merged2Data = try Data(contentsOf: dst.appendingPathComponent("hooks.json"))
        let merged2 = try JSONSerialization.jsonObject(with: merged2Data) as! [String: Any]
        let hooks2 = merged2["hooks"] as! [String: Any]
        let sessionStart2 = hooks2["SessionStart"] as! [[String: Any]]
        #expect(sessionStart2.count == 2)
    }

    @Test("Provider-plugin mode strips legacy Graftty hooks without replacing user hooks.")
    func pluginModeLeavesHooksToPlugin() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        try writeFile(src.appendingPathComponent("hooks.json"), """
        {
          "hooks": {
            "SessionStart": [
              { "hooks": [{ "type": "command", "command": "/path/to/user-script.sh" }] },
              { "hooks": [{ "type": "command", "command": "/usr/local/bin/graftty team hook codex session-start" }] }
            ]
          }
        }
        """)

        try CodexHomeMirror(
            sourceDirectory: src,
            mirrorDirectory: dst,
            grafttyCLIPath: "/usr/local/bin/graftty",
            grafttyHooksEnabled: false
        ).rebuild()

        let data = try Data(contentsOf: dst.appendingPathComponent("hooks.json"))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let commands = commands(in: hooks["SessionStart"] as! [[String: Any]])
        #expect(commands == ["/path/to/user-script.sh"])
    }

    @Test("Codex mirror installs authoritative attention transitions while removing stale delivery hooks.")
    func grafttyHooksReplaceDeliveryWithAttentionTransitions() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }

        try writeFile(src.appendingPathComponent("hooks.json"), """
        {
          "hooks": {
            "PostToolUse": [
              { "hooks": [{ "type": "command", "command": "/usr/local/bin/graftty team hook codex post-tool-use" }] },
              { "hooks": [{ "type": "command", "command": "/path/to/user-post-tool-use.sh" }] }
            ],
            "Stop": [
              { "hooks": [{ "type": "command", "command": "/usr/local/bin/graftty team hook codex stop" }] }
            ]
          }
        }
        """)

        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()

        let mergedData = try Data(contentsOf: dst.appendingPathComponent("hooks.json"))
        let merged = try JSONSerialization.jsonObject(with: mergedData) as! [String: Any]
        let hooks = merged["hooks"] as! [String: Any]
        let sessionStartCommands = commands(in: hooks["SessionStart"] as! [[String: Any]])
        let preToolUseCommands = commands(in: hooks["PreToolUse"] as! [[String: Any]])
        let userPromptSubmitCommands = commands(in: hooks["UserPromptSubmit"] as! [[String: Any]])
        let postToolUseCommands = commands(in: hooks["PostToolUse"] as! [[String: Any]])
        let permissionRequestCommands = commands(in: hooks["PermissionRequest"] as! [[String: Any]])
        let postToolUseFailureCommands = commands(in: hooks["PostToolUseFailure"] as! [[String: Any]])
        let stopCommands = commands(in: hooks["Stop"] as! [[String: Any]])

        #expect(sessionStartCommands == ["/usr/local/bin/graftty team hook codex session-start"])
        #expect(preToolUseCommands == ["/usr/local/bin/graftty team hook codex pre-tool-use"])
        #expect(userPromptSubmitCommands == ["/usr/local/bin/graftty team hook codex user-prompt-submit"])
        #expect(postToolUseCommands == [
            "/path/to/user-post-tool-use.sh",
            "/usr/local/bin/graftty team hook codex post-tool-use",
        ])
        #expect(permissionRequestCommands.isEmpty)
        #expect(postToolUseFailureCommands.isEmpty)
        #expect(stopCommands.isEmpty)
    }

    @Test("Durable Codex configuration changes appear in the next managed snapshot.")
    func durableConfigMutationsAppearInRebuiltMirror() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }

        try writeFile(src.appendingPathComponent("config.toml"), """
        model = "o3"
        """)

        let mirror = CodexHomeMirror(
            sourceDirectory: src,
            mirrorDirectory: dst,
            grafttyCLIPath: "/usr/local/bin/graftty"
        )
        try mirror.rebuild()

        let durableConfig = src.appendingPathComponent("config.toml")
        let handle = try FileHandle(forWritingTo: durableConfig)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n[mcp_servers.runpod]\nurl = \"https://mcp.getrunpod.io/\"\n".utf8))
        try handle.close()

        try mirror.rebuild()

        let mirrorConfig = dst.appendingPathComponent("config.toml")
        let durable = try String(contentsOf: durableConfig)
        let rebuilt = try String(contentsOf: mirrorConfig)
        #expect(durable.contains("[mcp_servers.runpod]"))
        #expect(rebuilt == durable)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: mirrorConfig.path)) == nil)
    }

    @Test("Dangling symlinks (entries the user deleted) are pruned on rebuild.")
    func prunesDanglingSymlinks() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }

        try writeFile(src.appendingPathComponent("foo.json"), "{}")
        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("foo.json").path))

        // User deletes foo.json; rebuild should remove the dangling symlink.
        try FileManager.default.removeItem(at: src.appendingPathComponent("foo.json"))
        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()
        // Note: fileExists follows symlinks, so even a dangling link returns false; check via isSymbolicLink resource value or path-existence.
        let dstFoo = dst.appendingPathComponent("foo.json")
        let resourceValues = try? dstFoo.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(resourceValues?.isSymbolicLink != true)
    }

    @Test("A missing durable config produces an empty managed snapshot.")
    func missingConfigProducesEmptySnapshot() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        // No config.toml in src.

        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()

        let dstConfig = dst.appendingPathComponent("config.toml")
        #expect(try Data(contentsOf: dstConfig).isEmpty)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: dstConfig.path)) == nil)
    }

    @Test(
        "A durable managed-input read failure aborts the rebuild without advancing its marker.",
        arguments: ["config.toml", "hooks.json"]
    )
    func durableManagedInputReadFailureAbortsRebuild(filename: String) throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent(filename),
            withIntermediateDirectories: true
        )

        #expect(throws: (any Error).self) {
            try CodexHomeMirror(
                sourceDirectory: src,
                mirrorDirectory: dst,
                grafttyCLIPath: "/usr/local/bin/graftty"
            ).rebuild()
        }
        #expect(!FileManager.default.fileExists(
            atPath: dst.appendingPathComponent(".graftty-mirror-version").path
        ))
    }

    @Test("Plugin cache created in the durable home after an initial rebuild is mirrored on the next rebuild.")
    func durablePluginCacheCreatedLaterSurvivesRebuild() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let mirror = CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty")
        try mirror.rebuild()

        let durableCache = src.appendingPathComponent("plugins/cache/runpod", isDirectory: true)
        try FileManager.default.createDirectory(at: durableCache, withIntermediateDirectories: true)
        try writeFile(durableCache.appendingPathComponent("plugin.json"), "{}")
        try mirror.rebuild()

        let pluginsLink = dst.appendingPathComponent("plugins")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: pluginsLink.path) == src.appendingPathComponent("plugins").path)
        #expect(FileManager.default.fileExists(atPath: pluginsLink.appendingPathComponent("cache/runpod/plugin.json").path))
    }

    @Test(
        """
        @spec TEAM-10.13: When Graftty rebuilds a managed Codex home, the application shall keep app-server-control as a real mirror-local directory rather than symlink the durable Codex control directory.
        """,
        arguments: [false, true]
    )
    func appServerControlRemainsMirrorLocalDirectory(startsWithLegacySymlink: Bool) throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let durableControl = src.appendingPathComponent("app-server-control", isDirectory: true)
        let managedControl = dst.appendingPathComponent("app-server-control", isDirectory: true)
        try FileManager.default.createDirectory(at: durableControl, withIntermediateDirectories: true)
        try writeFile(durableControl.appendingPathComponent("app-server-startup.lock"), "")
        if startsWithLegacySymlink {
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: managedControl,
                withDestinationURL: durableControl
            )
        }

        let mirror = CodexHomeMirror(
            sourceDirectory: src,
            mirrorDirectory: dst,
            grafttyCLIPath: "/usr/local/bin/graftty"
        )
        try mirror.rebuild()

        let values = try managedControl.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        #expect(values.isDirectory == true)
        #expect(values.isSymbolicLink != true)
        #expect(!FileManager.default.fileExists(
            atPath: managedControl.appendingPathComponent("app-server-startup.lock").path
        ))

        let managedRuntimeState = managedControl.appendingPathComponent("managed-runtime-state")
        try writeFile(managedRuntimeState, "active")
        try mirror.rebuild()

        let rebuiltValues = try managedControl.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        #expect(rebuiltValues.isDirectory == true)
        #expect(rebuiltValues.isSymbolicLink != true)
        #expect(try String(contentsOf: managedRuntimeState) == "active")
        #expect(!FileManager.default.fileExists(
            atPath: durableControl.appendingPathComponent("managed-runtime-state").path
        ))
    }

    @Test("""
    @spec TEAM-10.9: When Graftty rebuilds a managed Codex home, the application shall migrate real managed entries other than Graftty-generated files and mirror-local runtime directories into the durable Codex home before replacing them with symlinks or pruning stale entries.
    """)
    func runtimePluginCacheIsMigratedBeforePruning() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        try writeFile(src.appendingPathComponent("config.toml"), "model = \"o3\"\n")
        let mirror = CodexHomeMirror(
            sourceDirectory: src,
            mirrorDirectory: dst,
            grafttyCLIPath: "/usr/local/bin/graftty"
        )
        try mirror.rebuild()

        let legacyPlugin = dst.appendingPathComponent("plugins/cache/runpod/plugin.json")
        try writeFile(legacyPlugin, "{\"version\":1}")

        try mirror.rebuild()

        let durablePlugin = src.appendingPathComponent("plugins/cache/runpod/plugin.json")
        #expect(try String(contentsOf: durablePlugin) == "{\"version\":1}")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: dst.appendingPathComponent("plugins").path
            ) == src.appendingPathComponent("plugins").path
        )
    }

    @Test("Legacy state merges missing entries and preserves conflicts as recovery files.")
    func legacyStateConflictsArePreservedDuringMigration() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try writeFile(src.appendingPathComponent("config.toml"), "model = \"o3\"\n")
        try writeFile(dst.appendingPathComponent("config.toml"), "model = \"o3\"\n")
        try writeFile(src.appendingPathComponent("plugins/cache/shared/version"), "durable")
        try writeFile(dst.appendingPathComponent("plugins/cache/shared/version"), "legacy")
        try writeFile(dst.appendingPathComponent("plugins/cache/runpod/plugin.json"), "runpod")

        try CodexHomeMirror(
            sourceDirectory: src,
            mirrorDirectory: dst,
            grafttyCLIPath: "/usr/local/bin/graftty"
        ).rebuild()

        #expect(try String(contentsOf: src.appendingPathComponent("plugins/cache/shared/version")) == "durable")
        #expect(try String(contentsOf: src.appendingPathComponent("plugins/cache/runpod/plugin.json")) == "runpod")
        #expect(
            try String(contentsOf: src.appendingPathComponent("plugins.graftty-legacy/cache/shared/version"))
                == "legacy"
        )
    }

    @Test("""
    @spec TEAM-10.6: When Graftty upgrades a legacy managed Codex config that is newer than the durable config, the application shall reconcile its feature and Codex administration tables into the durable config while restoring the user's durable hooks setting and retaining unrelated durable settings.
    """)
    func newerLegacyConfigIsMigratedBeforeRefresh() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let durable = src.appendingPathComponent("config.toml")
        try writeFile(durable, """
        model = "o3"
        mcp_servers.stale.url = "https://stale.example.com/"
        [features] # durable preferences
        "hooks" = false
        durable_only = true
        durable_notes = '''
        preserve the whole durable value
        '''
        [desktop]
        notifications = true
        """)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let legacy = dst.appendingPathComponent("config.toml")
        try writeFile(legacy, """
        model = "o3"
        mcp_servers.runpod.url = "https://mcp.getrunpod.io/"
        [features] # legacy managed snapshot
        hooks = true
        experimental_mode = true
        release_notes = '''
        durable_only = false
        '''
        [plugins."runpod@runpod"]
        enabled = true
        """)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: legacy.path
        )

        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()

        let durableText = try String(contentsOf: durable)
        #expect(durableText.contains("[plugins.\"runpod@runpod\"]"))
        #expect(durableText.contains("mcp_servers.runpod.url = \"https://mcp.getrunpod.io/\""))
        #expect(!durableText.contains("mcp_servers.stale.url"))
        #expect(durableText.contains("\"hooks\" = false"))
        #expect(!durableText.contains("hooks = true"))
        #expect(durableText.contains("durable_only = true"))
        #expect(durableText.contains("""
        durable_notes = '''
        preserve the whole durable value
        '''
        """))
        #expect(durableText.contains("experimental_mode = true"))
        #expect(durableText.contains("[desktop]"))
        #expect(durableText.contains("notifications = true"))
        #expect(try String(contentsOf: dst.appendingPathComponent("config.toml")) == durableText)
    }

    @Test("Legacy administration removal recognizes table headers with trailing comments.")
    func commentedAdministrationTableIsRemovedDuringLegacyMigration() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let durable = src.appendingPathComponent("config.toml")
        try writeFile(durable, """
        model = "o3"
        mcp_servers.dotted.url = "https://dotted.getrunpod.io/"
        plugins = { legacy = { enabled = true } }
        [features]
        hooks = false
        [mcp_servers . runpod] # production
        url = "https://mcp.getrunpod.io/"
        ["plugins"."runpod@runpod"]
        enabled = true
        """)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let legacy = dst.appendingPathComponent("config.toml")
        try writeFile(legacy, """
        model = "o3"
        [features]
        hooks = true
        """)
        try writeFile(dst.appendingPathComponent(".graftty-mirror-version"), "2\n")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: legacy.path
        )

        try CodexHomeMirror(
            sourceDirectory: src,
            mirrorDirectory: dst,
            grafttyCLIPath: "/usr/local/bin/graftty"
        ).rebuild()

        let migrated = try String(contentsOf: durable)
        #expect(!migrated.contains("[mcp_servers . runpod]"))
        #expect(!migrated.contains("mcp.getrunpod.io"))
        #expect(!migrated.contains("dotted.getrunpod.io"))
        #expect(!migrated.contains("plugins ="))
        #expect(!migrated.contains("runpod@runpod"))
        #expect(migrated.contains("hooks = false"))
        #expect(!migrated.contains("hooks = true"))
    }

    @Test("""
    @spec TEAM-10.11: While a managed Codex home rebuild and durable administration can access the same coordination lock, the application shall serialize them so one finishes before the other begins.
    """)
    func rebuildWaitsForSharedAdministrationLock() async throws {
        let (src, dst) = try makeMirrorSandbox()
        let root = src.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let ready = root.appendingPathComponent("lock-ready")
        let release = root.appendingPathComponent("lock-release")
        let holderScript = root.appendingPathComponent("hold-lock.sh")
        try writeFile(holderScript, """
        #!/bin/sh
        /usr/bin/touch "$GRAFTTY_TEST_LOCK_READY"
        while [ ! -f "$GRAFTTY_TEST_LOCK_RELEASE" ]; do
          /bin/sleep 0.02
        done
        """)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: holderScript.path
        )

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        holder.arguments = [
            "-k",
            dst.appendingPathComponent(".graftty-mirror.lock").path,
            holderScript.path,
        ]
        holder.environment = [
            "GRAFTTY_TEST_LOCK_READY": ready.path,
            "GRAFTTY_TEST_LOCK_RELEASE": release.path,
        ]
        try holder.run()
        defer {
            try? Data().write(to: release, options: .atomic)
            if holder.isRunning {
                holder.terminate()
                holder.waitUntilExit()
            }
        }
        #expect(await waitForFile(ready, timeout: 2.0))

        let releaseTask = Task.detached {
            try await Task.sleep(for: .milliseconds(400))
            try Data().write(to: release, options: .atomic)
        }
        let mirror = CodexHomeMirror(
            sourceDirectory: src,
            mirrorDirectory: dst,
            grafttyCLIPath: "/usr/local/bin/graftty"
        )
        let startedAt = Date()
        try mirror.rebuild()
        let elapsed = Date().timeIntervalSince(startedAt)
        try await releaseTask.value
        holder.waitUntilExit()
        #expect(elapsed >= 0.25)
        #expect(FileManager.default.fileExists(
            atPath: dst.appendingPathComponent(".graftty-mirror-version").path
        ))
    }

    @Test("Migration ignores table-like text inside multiline TOML strings.")
    func multilineStringsRemainIntactDuringLegacyMigration() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let durable = src.appendingPathComponent("config.toml")
        try writeFile(durable, #"""
        instructions = """
        keep basic string content
        [plugins.not-a-table]
        hooks = "not a setting"
        """
        literal_instructions = '''
        [mcp_servers.also-not-a-table]
        keep literal string content
        '''
        [features]
        hooks = false
        [desktop]
        notifications = true
        """#)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let legacy = dst.appendingPathComponent("config.toml")
        try writeFile(legacy, """
        [features]
        hooks = true
        [plugins.\"runpod@runpod\"]
        enabled = true
        """)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: legacy.path
        )

        try CodexHomeMirror(
            sourceDirectory: src,
            mirrorDirectory: dst,
            grafttyCLIPath: "/usr/local/bin/graftty"
        ).rebuild()

        let migrated = try String(contentsOf: durable)
        #expect(migrated.contains(#"""
        instructions = """
        keep basic string content
        [plugins.not-a-table]
        hooks = "not a setting"
        """
        """#))
        #expect(migrated.contains(#"""
        literal_instructions = '''
        [mcp_servers.also-not-a-table]
        keep literal string content
        '''
        """#))
        #expect(migrated.contains("[desktop]"))
        #expect(migrated.contains("[plugins.\"runpod@runpod\"]"))
    }

    @Test("""
    @spec TEAM-10.7: If the durable Codex config is newer than a divergent legacy managed config during upgrade, then the application shall keep the durable config authoritative and preserve a recovery copy of the legacy config with Graftty's generated hook override removed.
    """)
    func newerDurableConfigPreservesLegacyRecoveryBackup() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let durable = src.appendingPathComponent("config.toml")
        try writeFile(durable, """
        model = "gpt-5"

        [features]
        hooks = false
        """)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let legacy = dst.appendingPathComponent("config.toml")
        try writeFile(legacy, """
        model = "o3"

        [features]
        hooks = true
        """)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2)],
            ofItemAtPath: legacy.path
        )

        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()

        let durableText = try String(contentsOf: durable)
        #expect(durableText.contains("model = \"gpt-5\""))
        #expect(durableText.contains("hooks = false"))
        let backup = src.appendingPathComponent("config.toml.graftty-legacy")
        let backupText = try String(contentsOf: backup)
        #expect(backupText.contains("model = \"o3\""))
        #expect(!backupText.contains("hooks = true"))
        #expect(try String(contentsOf: dst.appendingPathComponent("config.toml")) == durableText)
    }

    private func makeMirrorSandbox() throws -> (URL, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-codex-mirror-\(UUID().uuidString)", isDirectory: true)
        let src = root.appendingPathComponent("src", isDirectory: true)
        let dst = root.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        return (src, dst)
    }

    private func writeFile(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func commands(in groups: [[String: Any]]) -> [String] {
        groups.flatMap { group -> [String] in
            let handlers = (group["hooks"] as? [[String: Any]]) ?? []
            return handlers.compactMap { $0["command"] as? String }
        }
    }
}

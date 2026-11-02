import Foundation
import Testing
@testable import GrafttyKit

@MainActor
struct AgentArchiveTests {
    @Test("@spec AGENT-6.113: When migrating multiple legacy transcripts, the application shall persist their archive references together without repeatedly serializing the remaining inline history.")
    func migrationUsesOneStateSave() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.state.repos[0].worktrees[0].agents = (0..<3).map { index in
            var agent = ManagedAgent(name: "Archive \(index)", provider: .codex, parent: nil)
            agent.transcript = "Full history \(index)"
            return agent
        }
        try await AgentControl.migrateTranscripts(platform: platform)
        #expect(platform.saveStateNowCalls == 1)
        for (index, agent) in platform.state.repos[0].worktrees[0].agents.enumerated() {
            #expect(agent.transcript == nil)
            #expect(try platform.agentArchives.read(#require(agent.transcriptArchive)) == "Full history \(index)")
        }
    }
    @Test("@spec AGENT-6.109: When a managed transcript is archived, the application shall durably retain its complete UTF-8 contents outside AppState and retrieve it through bounded exact-ID detail chunks.")
    func externalTranscriptRoundTrip() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var agent = ManagedAgent(name: "Archive", provider: .codex, parent: nil)
        let transcript = String(repeating: "🦊 retained history\n", count: 2_600_000)
        #expect(transcript.utf8.count > 50_000_000)
        agent.transcript = transcript
        platform.state.repos[0].worktrees[0].agents = [agent]
        try await AgentControl.migrateTranscripts(platform: platform)
        let saved = platform.state.repos[0].worktrees[0].agents[0]
        #expect(saved.transcript == nil)
        let reference = try #require(saved.transcriptArchive)
        #expect(reference.byteCount == transcript.utf8.count)
        #expect(try JSONEncoder().encode(saved).count < 4096)
        #expect(try platform.agentArchives.read(reference) == transcript)
        #expect(try platform.agentArchives.write(transcript) == reference)
        var bytes = Data()
        var offset = 0
        var token: UUID?
        repeat {
            var request = AgentControlRequest(action: .show, callerWorktree: platform.state.repos[0].worktrees[0].path,
                                              agentID: agent.id)
            request.offset = offset
            request.detailToken = token
            guard case .agents(let rows) = await AgentControl.handle(request, platform: platform), let row = rows.first else {
                Issue.record("Expected detail chunk"); return
            }
            let chunk = try #require(row.detail)
            #expect(chunk.count <= 64 * 1024)
            bytes.append(chunk)
            token = row.detailToken
            guard let next = row.nextOffset else { break }
            offset = next
        } while true
        let restored = try JSONDecoder().decode(ManagedAgent.self, from: bytes)
        #expect(restored.transcript == transcript)
        #expect(platform.state.repos[0].worktrees[0].agents[0].transcript == nil)
    }

    @Test("@spec AGENT-6.111: When the user opens a large archived transcript, the application shall load a bounded UTF-8 preview and identify how to retrieve the complete retained text.")
    func previewPreservesFullArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentArchiveStore(directory: directory)
        let transcript = "abc🦊def🦊" + String(repeating: "retained", count: 100)
        let reference = try store.write(transcript)
        let preview = try store.preview(reference, agentID: "exact-id", maximumBytes: 5)
        #expect(preview.hasPrefix("abc\n\n[Preview only."))
        #expect(preview.contains("graftty agent show exact-id --json"))
        #expect(!preview.contains("�"))
        #expect(try store.read(reference) == transcript)
    }

    @Test("@spec AGENT-6.110: If transcript archival fails, the application shall preserve the inline transcript for retry without publishing a missing archive reference.")
    func failedMigrationRetainsInlineHistory() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var agent = ManagedAgent(name: "Archive", provider: .codex, parent: nil)
        agent.transcript = "retain me"
        platform.state.repos[0].worktrees[0].agents = [agent]
        try FileManager.default.createDirectory(at: platform.agentPromptDirectory, withIntermediateDirectories: true)
        try Data("obstruction".utf8).write(to: platform.agentArchives.directory)
        await #expect(throws: (any Error).self) { try await AgentControl.migrateTranscripts(platform: platform) }
        #expect(platform.state.repos[0].worktrees[0].agents[0].transcript == "retain me")
        #expect(platform.state.repos[0].worktrees[0].agents[0].transcriptArchive == nil)
        try FileManager.default.removeItem(at: platform.agentArchives.directory)
        platform.saveStateNowError = CocoaError(.fileWriteUnknown)
        await #expect(throws: (any Error).self) { try await AgentControl.migrateTranscripts(platform: platform) }
        #expect(platform.state.repos[0].worktrees[0].agents[0].transcript == "retain me")
        #expect(platform.state.repos[0].worktrees[0].agents[0].transcriptArchive == nil)
    }
}

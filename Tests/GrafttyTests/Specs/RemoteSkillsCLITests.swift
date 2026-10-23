import Foundation
import Testing
@testable import GrafttyCLI
import GrafttyKit
import GrafttyProtocol

struct RemoteSkillsCLITests {
    @Test func placementRequiresMatchingSkillsBeforeAgentLaunch() throws {
        let args = ["remote", "placement", "create", "--host", "worker", "--repository", "/repo", "--name", "task", "--architecture", "arm64", "--operation-id", UUID().uuidString]
        let revision = String(repeating: "a", count: 64)
        #expect(throws: (any Error).self) { _ = try GrafttyCLI.parseAsRoot(args + ["--skill-revision", "codex:" + revision]) }
        #expect(throws: (any Error).self) { _ = try GrafttyCLI.parseAsRoot(args + ["--dev-container", "--agent", "codex"]) }
        #expect(throws: (any Error).self) { _ = try GrafttyCLI.parseAsRoot(args + ["--dev-container", "--agent", "claude", "--skill-revision", "codex:" + revision]) }
        #expect(throws: (any Error).self) { _ = try GrafttyCLI.parseAsRoot(args + ["--dev-container", "--skill-revision", "codex:" + revision, "--skill-revision", "codex:" + revision]) }
        let parsed = try #require(try GrafttyCLI.parseAsRoot(args + ["--dev-container", "--agent", "codex", "--skill-revision", "codex:" + revision]) as? RemotePlacementCreate)
        #expect(try parsed.skills() == [.init(runtime: "codex", revision: revision)])
        #expect(parsed.agent == "codex")
    }

    @Test("@spec REMOTE-28.10: When exporting or staging remote skills through the CLI, the application shall require explicit source and destination selections, verify the requested revision before staging, and report staged paths without activating an agent or copying authentication stores.")
    func exportStageAndRejectWrongRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-skill-cli-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent("home/.claude/skills/demo/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
        try Data("demo".utf8).write(to: skill)
        let archive = root.appendingPathComponent("skills.json")
        var export = try GrafttyCLI.parseAsRoot(["remote", "skills", "export", "--runtime", "claude", "--workspace", root.appendingPathComponent("project").path,
            "--source-home", root.appendingPathComponent("home").path, "--output", archive.path])
        try export.run()
        let data = try Data(contentsOf: archive)
        let snapshot = try RemoteSkillSnapshot.decode(data)
        #expect(snapshot.files.count == 1)
        let arguments = ["remote", "skills", "stage", "--input", archive.path, "--parent-id", "parent", "--project-id", "project", "--directory", root.appendingPathComponent("store").path]
        var wrong = try GrafttyCLI.parseAsRoot(arguments + ["--revision", String(repeating: "0", count: 64)])
        #expect(throws: (any Error).self) { try wrong.run() }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("store").path))
        var stage = try GrafttyCLI.parseAsRoot(arguments + ["--revision", try snapshot.revision])
        try stage.run()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("store").path))
        #expect(throws: (any Error).self) { try export.run() }
        #expect(try Data(contentsOf: archive) == data)
    }

    @Test func syncPinsTheDeviceAndFingerprintOnEveryFrame() async throws {
        let snapshot = RemoteSkillSnapshot(runtime: .codex, files: [])
        let id = UUID()
        let host = RemoteMacConnectionSummary.ID(deviceID: .init(value: "worker"), fingerprint: try .init(rawBytes: Data(repeating: 7, count: 32)))
        let descriptor = RemoteSkillTransferDescriptor(operationID: id, repositoryID: "/repo", runtime: "codex", revision: try snapshot.revision, byteCount: try snapshot.encoded().count)
        let result = try await RemoteSkillsSync.transfer(snapshot, to: host, repository: "/repo", operationID: id) { message in
            #expect(try JSONDecoder().decode(NotificationMessage.self, from: JSONEncoder().encode(message)) == message)
            guard case .remoteSkills(let destination, let request) = message else { throw RemoteSkillError("Wrong routing envelope") }
            #expect(destination == host)
            let status: RemoteSkillTransferStatus
            switch request {
            case .begin(let declaration):
                #expect(declaration == descriptor)
                status = .init(descriptor: descriptor, receivedBytes: 0, phase: .receiving)
            case .append(_, let offset, let bytes): status = .init(descriptor: descriptor, receivedBytes: offset + bytes.count, phase: .receiving)
            case .finish: status = .init(descriptor: descriptor, receivedBytes: descriptor.byteCount, phase: .staged)
            case .abort: throw RemoteSkillError("Unexpected abort")
            }
            let response = ResponseMessage.agentSkills(status)
            #expect(try JSONDecoder().decode(ResponseMessage.self, from: JSONEncoder().encode(response)) == response)
            return response
        }
        #expect(result.phase == .staged)
    }

    @Test func syncRequiresPinnedHostAndStableOperation() throws {
        _ = try GrafttyCLI.parseAsRoot(["remote", "skills", "sync", "--host", "linux", "--repository", "/repo", "--input", "/skills.json", "--revision", String(repeating: "0", count: 64), "--operation-id", UUID().uuidString])
        #expect(throws: (any Error).self) { _ = try GrafttyCLI.parseAsRoot(["remote", "skills", "sync", "--host", "linux", "--input", "/skills.json"]) }
    }

    @Test func rejectsMissingSelectionsAndInvalidRuntime() throws {
        #expect(throws: (any Error).self) { _ = try GrafttyCLI.parseAsRoot(["remote", "skills", "export"]) }
        #expect(throws: (any Error).self) {
            _ = try GrafttyCLI.parseAsRoot(["remote", "skills", "export", "--runtime", "other", "--workspace", "/project", "--output", "/snapshot.json"])
        }
        #expect(throws: (any Error).self) { _ = try GrafttyCLI.parseAsRoot(["remote", "skills", "stage", "--input", "/snapshot.json"]) }
    }
}

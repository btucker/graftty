import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("@spec REMOTE-13.32: When a host publishes a project or worktree, the application shall carry its origin key, activity time, and ranks as optional fields, so payloads from older hosts decode with those fields absent.")
struct MultiHostWireTests {
    @Test func olderPayloadDecodesNewFieldsAsNil() throws {
        let project = try JSONDecoder().decode(SidebarProject.self, from: Data(#"{"id":"p","repositoryID":"r","name":"n","isAvailable":true}"#.utf8))
        #expect(project.originKey == nil)
        #expect(project.rank == nil)
        #expect(project.rankChangedAt == nil)
        let metadata = try JSONDecoder().decode(SidebarWorktreeMetadata.self, from: Data(#"{"id":"w","projectID":"p","folders":[]}"#.utf8))
        #expect(metadata.activityTime == nil)
        #expect(metadata.pinnedRank == nil)
        let repository = try JSONDecoder().decode(RemoteRepositoryInfo.self, from: Data(#"{"id":"r","displayName":"n","defaultBranch":"main","branches":[]}"#.utf8))
        #expect(repository.originKey == nil)
    }

    @Test func newFieldsRoundTrip() throws {
        var project = SidebarProject(id: "p", repositoryID: "r", name: "n")
        project.originKey = "github.com/acme/app"
        project.rank = "a0"
        project.rankChangedAt = 12.5
        #expect(try JSONDecoder().decode(SidebarProject.self, from: JSONEncoder().encode(project)) == project)
        var metadata = SidebarWorktreeMetadata(id: "w", projectID: "p")
        metadata.activityTime = 99
        metadata.pinnedRank = "b"
        #expect(try JSONDecoder().decode(SidebarWorktreeMetadata.self, from: JSONEncoder().encode(metadata)) == metadata)
    }

    @Test func setPinnedRankRoundTrips() throws {
        let request = WorktreeManagementRequest.setPinnedRank(repositoryID: "r", worktreeID: "w", rank: "a5")
        let data = try JSONEncoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self).contains("set_pinned_rank"))
        #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: data) == request)
    }

    @Test func setProjectRankRoundTrips() throws {
        let request = WorktreeManagementRequest.setProjectRank(repositoryID: "r", rank: "a5", changedAt: 7.5)
        let data = try JSONEncoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self).contains("set_project_rank"))
        #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: data) == request)
    }
}

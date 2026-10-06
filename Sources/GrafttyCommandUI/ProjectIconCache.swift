import Foundation
import Observation
import CryptoKit
import GrafttyProtocol

/// Revision checks and request tokens protect icon updates on Mac and mobile.
@Observable @MainActor
public final class ProjectIconCache {
    public private(set) var icons: [String: Data] = [:]
    private var expectedRevisions: [String: String] = [:]
    private var resolvedRevisions: [String: String] = [:]
    private var requests: [String: UUID] = [:]

    public init() {}

    private static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func reconcile(_ projects: [SidebarProject]) {
        for project in projects where project.isAvailable {
            if expectedRevisions[project.id] != project.iconRevision {
                expectedRevisions[project.id] = project.iconRevision
                requests[project.id] = nil
                icons[project.id] = nil
                resolvedRevisions[project.id] = nil
            }
        }
    }

    public func load(for project: SidebarProject, fetch: () async -> Data?) async {
        guard let revision = project.iconRevision, expectedRevisions[project.id] == revision,
              resolvedRevisions[project.id] != revision, requests[project.id] == nil else { return }
        let token = UUID()
        requests[project.id] = token
        defer { if requests[project.id] == token { requests[project.id] = nil } }
        let data = await fetch()
        guard !Task.isCancelled, requests[project.id] == token,
              expectedRevisions[project.id] == revision, let data, data.count <= 65536,
              Self.revision(data) == revision else { return }
        icons[project.id] = data
        resolvedRevisions[project.id] = revision
    }

}

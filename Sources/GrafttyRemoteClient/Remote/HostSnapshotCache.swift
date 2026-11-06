import Foundation
import GrafttyProtocol

/// A host's last report, kept so its rows stay on screen while it sleeps.
/// Local only: rows read from here are never relayed to other clients.
public struct HostSnapshotCache: Sendable {
    public struct Snapshot: Codable, Sendable, Equatable {
        public var projects: [SidebarProject]
        public var rows: [WorktreePanes]
        public init(projects: [SidebarProject], rows: [WorktreePanes]) {
            self.projects = projects
            self.rows = rows
        }
    }

    public let directory: URL

    public init(directory: URL = PinnedHostStore.defaultDirectory.appendingPathComponent("HostSnapshots")) {
        self.directory = directory
    }

    public func url(for hostID: RemoteDeviceID) -> URL {
        let name = hostID.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "host"
        return directory.appendingPathComponent(name + ".json")
    }

    public func save(hostID: RemoteDeviceID, projects: [SidebarProject], rows: [WorktreePanes]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Snapshot(projects: projects, rows: rows)).write(to: url(for: hostID), options: .atomic)
    }

    public func load(hostID: RemoteDeviceID) -> Snapshot? {
        guard let data = try? Data(contentsOf: url(for: hostID)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    public func remove(hostID: RemoteDeviceID) {
        try? FileManager.default.removeItem(at: url(for: hostID))
    }
}

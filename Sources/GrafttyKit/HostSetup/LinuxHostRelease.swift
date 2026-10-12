import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LinuxHostRelease: Sendable, Equatable {
    public let version: String
    public let architecture: String
    public var archiveURL: URL {
        URL(string: "https://github.com/btucker/graftty/releases/download/v\(version)/graftty-linux-\(version)-\(architecture).tar.gz")!
    }

    public func requiresReplacementConfirmation(current: String) -> Bool {
        func parts(_ value: String) -> ([Int], [String])? {
            guard LinuxHostSetup.validVersion(value),
                  !["dev", "nightly", "ci"].contains(where: { value.lowercased().contains($0) }) else { return nil }
            let pieces = value.split(separator: "-", maxSplits: 1)
            let numbers = pieces[0].split(separator: ".").compactMap { Int($0) }
            guard numbers.count == 3 else { return nil }
            return (numbers, pieces.count == 2 ? pieces[1].split(separator: ".").map(String.init) : [])
        }
        guard let installed = parts(current), let target = parts(version) else { return true }
        if installed.0 != target.0 { return target.0.lexicographicallyPrecedes(installed.0) }
        if installed.1.isEmpty { return !target.1.isEmpty }
        if target.1.isEmpty { return false }
        for (targetPart, installedPart) in zip(target.1, installed.1) where targetPart != installedPart {
            switch (Int(targetPart), Int(installedPart)) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return targetPart < installedPart
            }
        }
        return target.1.count < installed.1.count
    }

    public struct Record: Sendable, Equatable {
        public let tag: String
        public let publishedAt: String
        public let draft: Bool
        public let assets: [String]
        public init(tag: String, publishedAt: String, draft: Bool, assets: [String]) {
            self.tag = tag; self.publishedAt = publishedAt; self.draft = draft; self.assets = assets
        }
    }

    public static func select(from records: [Record], architecture: String, includePrereleases: Bool = false) throws -> Self? {
        guard ["aarch64", "x86_64"].contains(architecture) else {
            throw LinuxHostSetupError.invalidPlan("No Linux release supports this host architecture.")
        }
        for record in records.filter({ !$0.draft }).sorted(by: { $0.publishedAt > $1.publishedAt }) {
            guard record.tag.hasPrefix("v") else { continue }
            let version = String(record.tag.dropFirst())
            guard LinuxHostSetup.validVersion(version), includePrereleases || !version.contains("-") else { continue }
            let name = "graftty-linux-\(version)-\(architecture).tar.gz"
            if record.assets.contains(name), record.assets.contains(name + ".sha256") {
                return .init(version: version, architecture: architecture)
            }
        }
        return nil
    }

    public static func published() async throws -> [Record] {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String }
            let tag_name: String
            let published_at: String?
            let draft: Bool
            let assets: [Asset]
        }
        var records: [Record] = []
        for page in 1...10 {
            try Task.checkCancellation()
            let url = URL(string: "https://api.github.com/repos/btucker/graftty/releases?per_page=100&page=\(page)")!
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw LinuxHostSetupError.invalidPlan("Could not load published Linux releases. Agent tools can still be updated separately.")
            }
            let releases = try JSONDecoder().decode([Release].self, from: data)
            records += releases.map { .init(tag: $0.tag_name, publishedAt: $0.published_at ?? "", draft: $0.draft, assets: $0.assets.map(\.name)) }
            if releases.count < 100 { break }
        }
        return records
    }
}

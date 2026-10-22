#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import Testing

@testable import GrafttyMobileKit

/// On-disk compatibility net for `HostStore` after its move onto
/// `ObservableListStore` (#488). `hosts.json` has always used Foundation's
/// default (reference-date number) `Date` coding, unlike the iso8601 Mac
/// stores; the frozen coders below pin that.
@Suite("HostStore on-disk compatibility")
@MainActor
struct HostStoreCompatibilityTests {

    @Test("hosts.json keeps the earlier writer's bytes and the earlier reader decodes it")
    func hostStoreCompatibility() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-host-compat-\(UUID().uuidString)/hosts.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let host = Host(
            id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
            label: "Studio",
            baseURL: URL(string: "http://studio.local:8799")!,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsedAt: Date(timeIntervalSince1970: 1_700_000_060)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let legacyBytes = try encoder.encode([host])

        try HostStore(storeURL: url).add(host)
        let written = try Data(contentsOf: url)
        #expect(written == legacyBytes)
        #expect(try JSONDecoder().decode([Host].self, from: written) == [host])

        try legacyBytes.write(to: url)
        let reloaded = HostStore(storeURL: url)
        await reloaded.loadIfNeeded()
        #expect(reloaded.hosts == [host])

        // A corrupt hosts.json reads as empty and, unlike remote-macs.json,
        // is not moved aside.
        try Data("{".utf8).write(to: url)
        let corrupt = HostStore(storeURL: url)
        await corrupt.loadIfNeeded()
        #expect(corrupt.hosts.isEmpty)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(siblings == ["hosts.json"])
    }
}
#endif

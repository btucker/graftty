#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import GrafttyProtocol
import Testing

@testable import GrafttyKit
import GrafttyTestSupport

/// On-disk compatibility net for the stores migrated onto `JSONFileStore`
/// (#488). Each `legacy*` helper is a frozen copy of the coder setup the
/// store shipped with before the migration: files the earlier releases
/// wrote must load, and files written now must be byte-identical to what
/// the earlier writer produced (so the earlier reader accepts them).
@Suite("JSON store on-disk compatibility")
struct JSONStoreCompatibilityTests {

    private static let at = Date(timeIntervalSince1970: 1_700_000_000)

    private static func legacyPrettySortedEncoder(iso8601: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if iso8601 { encoder.dateEncodingStrategy = .iso8601 }
        return encoder
    }

    /// Unsorted encoders do not fix key order, so stores written without
    /// `.sortedKeys` are compared as key-sorted re-serializations rather than
    /// as bytes (portable, unlike bridging the parsed tree to `NSObject`).
    private static func sameJSON(_ lhs: Data, _ rhs: Data) throws -> Bool {
        func canonical(_ data: Data) throws -> Data {
            try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys])
        }
        return try canonical(lhs) == canonical(rhs)
    }

    private static func legacyISODecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: AppState (state.json)

    private func sampleState() -> AppState {
        var state = AppState()
        state.addRepo(RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main"),
        ]))
        state.selectedWorktreePath = "/tmp/repo"
        return state
    }

    @Test("state.json keeps the earlier writer's bytes and the earlier reader decodes it")
    func appStateCompatibility() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = sampleState()
        let legacyBytes = try Self.legacyPrettySortedEncoder(iso8601: false).encode(state)

        try state.save(to: dir)
        let written = try Data(contentsOf: dir.appendingPathComponent("state.json"))
        #expect(written == legacyBytes)
        #expect(try JSONDecoder().decode(AppState.self, from: written) == state)

        try legacyBytes.write(to: dir.appendingPathComponent("state.json"))
        #expect(try AppState.load(from: dir) == state)
    }

    // MARK: HostConfiguration (host-config.json)

    @Test("host-config.json keeps the earlier writer's bytes and does not create its directory")
    func hostConfigurationCompatibility() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configuration = HostConfiguration(
            stateDirectory: dir,
            runtimeDirectory: dir.appendingPathComponent("run"),
            zmxExecutable: URL(fileURLWithPath: "/usr/local/bin/zmx"),
            shell: "/bin/zsh"
        )
        let legacyBytes = try JSONEncoder().encode(configuration)

        try configuration.save()
        let written = try Data(contentsOf: dir.appendingPathComponent("host-config.json"))
        #expect(try Self.sameJSON(written, legacyBytes))
        #expect(!written.contains(UInt8(ascii: "\n")))
        #expect(try JSONDecoder().decode(HostConfiguration.self, from: written) == configuration)
        #expect(try HostConfiguration.load(stateDirectory: dir) == configuration)

        let missing = HostConfiguration(stateDirectory: dir.appendingPathComponent("absent"))
        #expect(throws: (any Error).self) { try missing.save() }
        #expect(try HostConfiguration.load(stateDirectory: missing.stateDirectory) == nil)
    }

    // MARK: WorktreeSleepJournal

    @Test("a sleep journal keeps the earlier writer's bytes and 0600 permissions")
    func sleepJournalCompatibility() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/journal.json")
        let journal = WorktreeSleepJournal(
            owner: SleepProcessIdentity(pid: 42, startTime: 7),
            processes: [SuspendedSleepProcess(path: "/tmp/repo", identity: SleepProcessIdentity(pid: 43, startTime: 8))]
        )
        let legacyBytes = try JSONEncoder().encode(journal)

        try journal.save(to: url)
        let written = try Data(contentsOf: url)
        #expect(try Self.sameJSON(written, legacyBytes))
        #expect(!written.contains(UInt8(ascii: "\n")))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let reloaded = try #require(WorktreeSleepJournal.load(from: url))
        #expect(reloaded.owner == journal.owner)
        #expect(reloaded.processes.map(\.identity) == journal.processes.map(\.identity))

        try Data("{".utf8).write(to: url)
        #expect(WorktreeSleepJournal.load(from: url) == nil)
    }

    // MARK: ChromeOfferLaunchLedger

    /// Mirrors the ledger's private receipt record.
    private struct LegacyReceipt: Codable, Equatable {
        let url: String
        var tabID: String?
    }

    @Test("the Chrome launch ledger keeps the earlier writer's bytes and reads its files")
    func chromeLedgerCompatibility() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = dir.appendingPathComponent("ledger.json")
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let raw = "https://example.com/a/b"

        var ledger = ChromeOfferLaunchLedger(storageURL: storage)
        try ledger.dispatched(id, url: raw)
        try ledger.created(id, tabID: "tab-1")

        let legacyEncoder = JSONEncoder()
        legacyEncoder.outputFormatting = [.withoutEscapingSlashes]
        let expected = [id: LegacyReceipt(url: raw, tabID: "tab-1")]
        let written = try Data(contentsOf: storage)
        #expect(try Self.sameJSON(written, legacyEncoder.encode(expected)))
        #expect(String(decoding: written, as: UTF8.self).contains(raw))
        #expect(try JSONDecoder().decode([UUID: LegacyReceipt].self, from: written) == expected)
        let mode = try FileManager.default.attributesOfItem(atPath: storage.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        try legacyEncoder.encode(expected).write(to: storage)
        #expect(try ChromeOfferLaunchLedger(storageURL: storage).tab(for: id, url: raw) == "tab-1")
    }

    // MARK: TrustedPeerStore (trusted-peers.json)

    private struct LegacyPeerEnvelope: Codable {
        var version: Int
        var peers: [TrustedPeer]
    }

    @Test("trusted-peers.json keeps the earlier writer's bytes and the earlier reader decodes it")
    func trustedPeerStoreCompatibility() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(1...32))
        let peer = TrustedPeer(
            id: RemoteDeviceID(value: "peer-1"),
            kind: .iphone,
            publicKey: try RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation),
            displayName: "Phone",
            capabilities: .defaultsAfterPairing,
            pairedAt: Self.at,
            lastSeenAt: Self.at.addingTimeInterval(60)
        )
        let envelope = LegacyPeerEnvelope(version: RemoteAccessProtocol.version, peers: [peer])
        let legacyBytes = try Self.legacyPrettySortedEncoder(iso8601: true).encode(envelope)

        try TrustedPeerStore(directory: dir).add(peer)
        let fileURL = dir.appendingPathComponent("trusted-peers.json")
        let written = try Data(contentsOf: fileURL)
        #expect(written == legacyBytes)
        #expect(try Self.legacyISODecoder().decode(LegacyPeerEnvelope.self, from: written).peers == [peer])

        try legacyBytes.write(to: fileURL)
        #expect(try TrustedPeerStore(directory: dir).list() == [peer])
    }

    // MARK: RemoteMacStore (remote-macs.json)

    @MainActor
    @Test("remote-macs.json keeps the earlier writer's bytes and the earlier reader decodes it")
    func remoteMacStoreCompatibility() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/remote-macs.json")
        let mac = RemoteMac(
            id: RemoteDeviceID(value: "mac-1"),
            label: "Studio Mac",
            fingerprint: try RemoteIdentityFingerprint(rawBytes: Data(repeating: 0x11, count: 32)),
            lastKnownBaseURL: URL(string: "https://studio.local:9443"),
            addedAt: Self.at
        )
        let legacyBytes = try Self.legacyPrettySortedEncoder(iso8601: true).encode([mac])

        try RemoteMacStore(storeURL: url).add(mac)
        let written = try Data(contentsOf: url)
        #expect(written == legacyBytes)
        #expect(try Self.legacyISODecoder().decode([RemoteMac].self, from: written) == [mac])

        try legacyBytes.write(to: url)
        let reloaded = RemoteMacStore(storeURL: url)
        await reloaded.loadIfNeeded()
        #expect(reloaded.remoteMacs == [mac])
    }

    @MainActor
    @Test("a saved Mac that fails field validation is backed up before the next save replaces remote-macs.json")
    func remoteMacStoreBacksUpValidationFailures() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("remote-macs.json")
        let saved = RemoteMac(
            id: RemoteDeviceID(value: "mac-1"),
            label: "Studio Mac",
            fingerprint: try RemoteIdentityFingerprint(rawBytes: Data(repeating: 0x11, count: 32)),
            maintenanceDestination: try LinuxHostDestination("me@studio"),
            addedAt: Self.at
        )
        // `LinuxHostDestination` rejects this value with its own error type,
        // not a `DecodingError`.
        let legacy = String(decoding: try Self.legacyPrettySortedEncoder(iso8601: true).encode([saved]), as: UTF8.self)
        try Data(legacy.replacingOccurrences(of: "me@studio", with: "-oProxyCommand").utf8).write(to: url)

        let store = RemoteMacStore(storeURL: url)
        try store.add(RemoteMac(
            id: RemoteDeviceID(value: "mac-2"),
            label: "Laptop",
            fingerprint: try RemoteIdentityFingerprint(rawBytes: Data(repeating: 0x22, count: 32)),
            addedAt: Self.at
        ))

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("remote-macs.json.corrupt.") }
        #expect(backups.count == 1)
        let backup = try Data(contentsOf: dir.appendingPathComponent(try #require(backups.first)))
        #expect(String(decoding: backup, as: UTF8.self).contains("-oProxyCommand"))
    }
}

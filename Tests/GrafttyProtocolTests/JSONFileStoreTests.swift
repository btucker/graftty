import Foundation
import Testing
@testable import GrafttyProtocol
import GrafttyTestSupport

@Suite("JSONFileStore")
struct JSONFileStoreTests {
    private struct Record: Codable, Equatable {
        var name: String
        var at: Date
    }

    private let record = Record(name: "a/b", at: Date(timeIntervalSince1970: 1_700_000_000))

    @Test("@spec PERSIST-5.1: When a JSONFileStore loads a file that does not exist, the application shall return nil without creating the file, its directory, or a corrupt-file backup.")
    func missingFileLoadsNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("missing", isDirectory: true)
        let store = JSONFileStore<Record>(fileURL: nested.appendingPathComponent("state.json"))

        #expect(try store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: nested.path))
    }

    @Test("@spec PERSIST-5.2: When a JSONFileStore saves a value, the application shall create missing parent directories unless the store opts out, replace the file atomically, and apply the store's configured POSIX permissions.")
    func saveHonoursDirectoryAndPermissionOptions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("a/b/state.json")

        let creating = JSONFileStore<Record>(fileURL: fileURL, posixPermissions: 0o600)
        try creating.save(record)
        #expect(try creating.load() == record)
        let mode = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let other = dir.appendingPathComponent("c/state.json")
        let nonCreating = JSONFileStore<Record>(fileURL: other, createsDirectory: false)
        #expect(throws: (any Error).self) { try nonCreating.save(record) }
        #expect(!FileManager.default.fileExists(atPath: other.deletingLastPathComponent().path))
    }

    @Test("@spec PERSIST-5.3: When a JSONFileStore moves a corrupt file aside, the application shall rename it beside the original as either `<name>.corrupt.<milliseconds>` or `<name>.corrupt-<seconds>`, per the store's configured backup naming, leaving no file at the original path.")
    func corruptBackupNaming() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_700_000_000.25)
        let cases: [(JSONFileStore<Record>.CorruptBackupNaming, String)] = [
            (.dotMilliseconds, "x.json.corrupt.1700000000250"),
            (.dashSeconds, "x.json.corrupt-1700000000"),
        ]
        for (naming, expected) in cases {
            let fileURL = dir.appendingPathComponent("x.json")
            try Data("not json {{{".utf8).write(to: fileURL)
            let store = JSONFileStore<Record>(fileURL: fileURL, backupNaming: naming)

            #expect(throws: DecodingError.self) { try store.load() }
            let backup = store.moveAsideCorruptFile(now: now)
            #expect(backup?.lastPathComponent == expected)
            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(expected).path))
        }
    }

    @Test("@spec PERSIST-5.9: When a JSONFileStore writes with configured POSIX permissions, the application shall apply those permissions to the temporary file before atomically publishing it at the destination.")
    func permissionsPrecedePublication() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("key.json")
        let file = JSONFileStore<Record>(fileURL: url, posixPermissions: 0o600)

        for text in ["first private key", "replacement private key"] {
            let previous = try? Data(contentsOf: url)
            let bytes = Data(text.utf8)
            try file.write(bytes, beforeReplacing: { staged in
                #expect(staged != url)
                #expect(try Data(contentsOf: staged) == bytes)
                #expect((try? Data(contentsOf: url)) == previous)
                let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
                #expect(attributes[.posixPermissions] as? Int == 0o600)
            })
            #expect(try Data(contentsOf: url) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["key.json"])
        }
    }

    @Test("a failed restricted-file publication preserves the destination and removes the temporary file")
    func failedPublicationCleansUp() throws {
        struct CancelPublication: Error {}
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("key.json")
        let file = JSONFileStore<Record>(fileURL: url, posixPermissions: 0o600)
        let original = Data("original".utf8)
        try file.write(original)

        #expect(throws: CancelPublication.self) {
            try file.write(Data("replacement".utf8), beforeReplacing: { _ in throw CancelPublication() })
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["key.json"])
    }

    @Test("@spec PERSIST-5.4: The application shall encode a JSONFileStore's dates and output formatting exactly as the store is configured, so a migrated store keeps the byte format its earlier releases wrote.")
    func byteFormatFollowsConfiguration() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("x.json")

        // Default: Foundation's deferred-to-Date reference-date seconds, unformatted.
        let plain = JSONFileStore<Record>(fileURL: fileURL)
        let plainBytes = try plain.encode(record)
        #expect(!plainBytes.contains(UInt8(ascii: "\n")))
        let plainJSON = try #require(JSONSerialization.jsonObject(with: plainBytes) as? [String: Any])
        #expect(plainJSON["at"] as? Double == 721_692_800)

        let iso = JSONFileStore<Record>(
            fileURL: fileURL,
            dates: .iso8601,
            outputFormatting: [.prettyPrinted, .sortedKeys]
        )
        try iso.save(record)
        #expect(String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
            == "{\n  \"at\" : \"2023-11-14T22:13:20Z\",\n  \"name\" : \"a\\/b\"\n}")
        #expect(try iso.load() == record)
        // A differently configured reader cannot read the other's dates.
        #expect(throws: DecodingError.self) { try plain.load() }
    }

    /// Stands in for a persisted type whose decoder validates a field and
    /// throws its own error type (e.g. `DirectSSHEndpoint`).
    private struct Validated: Codable {
        struct Invalid: Error {}
        init(from decoder: Decoder) throws { throw Invalid() }
        func encode(to encoder: Encoder) throws {}
    }

    @Test("@spec PERSIST-5.7: If a JSONFileStore's value rejects the file's contents with its own error while decoding, then the application shall report the contents as malformed with a DecodingError, so the store's corrupt-file recovery applies.")
    func validationErrorsReportAsMalformed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("x.json")
        try Data("[{}]".utf8).write(to: fileURL)
        let store = JSONFileStore<[Validated]>(fileURL: fileURL)

        #expect(throws: DecodingError.self) { try store.load() }
        #expect(store.loadMovingAsideCorruptFile() == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
    }

    @Test("loadMovingAsideCorruptFile() treats a missing or unreadable file as absent without a backup")
    func loadMovingAsideLeavesUnreadableFilesAlone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<Record>(fileURL: dir.appendingPathComponent("x.json"))
        #expect(store.loadMovingAsideCorruptFile() == nil)
        try store.save(record)
        #expect(store.loadMovingAsideCorruptFile() == record)

        // A directory where the file should be: unreadable, not malformed.
        let blocked = JSONFileStore<Record>(fileURL: dir.appendingPathComponent("sub"))
        try FileManager.default.createDirectory(at: blocked.fileURL, withIntermediateDirectories: true)
        #expect(blocked.loadMovingAsideCorruptFile() == nil)
        #expect(FileManager.default.fileExists(atPath: blocked.fileURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["sub", "x.json"])
    }

    @Test("remove() deletes the file and is a no-op when it is already gone")
    func removeIsIdempotent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<Record>(fileURL: dir.appendingPathComponent("x.json"))
        try store.save(record)

        try store.remove()
        try store.remove()
        #expect(try store.load() == nil)
    }
}

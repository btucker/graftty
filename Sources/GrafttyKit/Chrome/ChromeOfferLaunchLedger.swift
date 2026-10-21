import Foundation
import GrafttyProtocol

/// Private profile receipts survive viewer disconnects and host app restarts.
struct ChromeOfferLaunchLedger {
    private struct Receipt: Codable {
        let url: String
        var tabID: String?
    }
    private static let maximumFileBytes = 8 * 1024 * 1024
    /// Reads stay bounded by `maximumFileBytes`, so only decoding and the
    /// size-checked write go through the store; it never creates directories.
    private let file: JSONFileStore<[UUID: Receipt]>?
    private var receipts: [UUID: Receipt] = [:]
    private var unreadable = false
    enum Failure: Error, CustomStringConvertible {
        case ambiguousLaunch, changedURL, full, unreadableHistory
        var description: String {
            switch self {
            case .ambiguousLaunch: return "Chrome may already have opened this sign-in. Select its existing tab; this offer will not navigate again."
            case .changedURL: return "This sign-in offer changed its original URL. Start a new sign-in request."
            case .full: return "This Chrome profile has reached its sign-in history limit. Select an existing tab."
            case .unreadableHistory: return "Chrome cannot read its sign-in history safely. This offer will not navigate again."
            }
        }
    }

    init(storageURL: URL? = nil) {
        file = storageURL.map {
            JSONFileStore(
                fileURL: $0,
                outputFormatting: [.withoutEscapingSlashes],
                createsDirectory: false,
                posixPermissions: 0o600
            )
        }
        guard let file, let storageURL, FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let handle = try FileHandle(forReadingFrom: storageURL)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
            guard bytes.count <= Self.maximumFileBytes else { throw Failure.unreadableHistory }
            receipts = try file.decode(bytes)
            guard receipts.count <= 128, receipts.values.allSatisfy({
                $0.url.utf8.count <= 8192 && ($0.tabID?.utf8.count ?? 0) <= 128
            }) else { throw Failure.unreadableHistory }
        } catch { unreadable = true }
    }

    func tab(for id: UUID, url: String) throws -> String? {
        guard !unreadable else { throw Failure.unreadableHistory }
        guard let receipt = receipts[id] else { return nil }
        guard receipt.url == url else { throw Failure.changedURL }
        guard let tabID = receipt.tabID else { throw Failure.ambiguousLaunch }
        return tabID
    }

    mutating func dispatched(_ id: UUID, url: String) throws {
        guard !unreadable else { throw Failure.unreadableHistory }
        guard receipts[id] == nil else { throw Failure.ambiguousLaunch }
        guard receipts.count < 128 else { throw Failure.full }
        receipts[id] = Receipt(url: url, tabID: nil)
        do { try save() }
        catch { receipts[id] = nil; throw error }
    }

    mutating func abandonUnsent(_ id: UUID) throws {
        guard let receipt = receipts[id], receipt.tabID == nil else { return }
        receipts[id] = nil
        do { try save() }
        catch { receipts[id] = receipt; throw error }
    }

    mutating func created(_ id: UUID, tabID: String) throws {
        guard receipts[id] != nil else { return }
        receipts[id]?.tabID = tabID
        try save()
    }

    private func save() throws {
        guard let file else { return }
        let bytes = try file.encode(receipts)
        guard bytes.count <= Self.maximumFileBytes else { throw Failure.full }
        try file.write(bytes)
    }
}

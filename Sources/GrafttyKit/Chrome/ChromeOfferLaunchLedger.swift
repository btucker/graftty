import Foundation

/// In-memory receipts survive viewer disconnects. Ambiguous dispatches never navigate again.
struct ChromeOfferLaunchLedger {
    private struct Receipt {
        let url: String
        let expires: Date
        var tabID: String?
    }
    private var receipts: [UUID: Receipt] = [:]
    enum Failure: Error, CustomStringConvertible {
        case ambiguousLaunch, changedURL, full
        var description: String {
            switch self {
            case .ambiguousLaunch: return "Chrome may already have opened this sign-in. Select its existing tab; this offer will not navigate again."
            case .changedURL: return "This sign-in offer changed its original URL. Start a new sign-in request."
            case .full: return "Chrome sign-in history is full. Try again after older offers expire."
            }
        }
    }

    mutating func tab(for id: UUID, url: String, now: Date = Date()) throws -> String? {
        receipts = receipts.filter { $0.value.expires > now }
        guard let receipt = receipts[id] else { return nil }
        guard receipt.url == url else { throw Failure.changedURL }
        guard let tabID = receipt.tabID else { throw Failure.ambiguousLaunch }
        return tabID
    }

    mutating func dispatched(_ id: UUID, url: String, now: Date = Date()) throws {
        receipts = receipts.filter { $0.value.expires > now }
        guard receipts[id] == nil else { throw Failure.ambiguousLaunch }
        guard receipts.count < 128 else { throw Failure.full }
        receipts[id] = Receipt(url: url, expires: now.addingTimeInterval(900), tabID: nil)
    }

    mutating func created(_ id: UUID, tabID: String) { receipts[id]?.tabID = tabID }
}

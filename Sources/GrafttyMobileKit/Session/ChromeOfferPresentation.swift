import Foundation

/// A nil sheet binding can precede onDismiss. Reserve its identity until that callback.
struct ChromeOfferPresentation {
    enum Dismissal: Equatable { case dismissed(UUID), deferred(UUID) }
    private var offerID: UUID?
    private var deferred = false
    private var presenting = false
    var canPresent: Bool { !presenting }

    mutating func begin(_ id: UUID?) -> Bool {
        guard canPresent else { return false }
        offerID = id; deferred = false; presenting = true
        return true
    }

    mutating func deferCurrent() -> UUID? {
        deferred = true
        return offerID
    }

    mutating func finishDismissal() -> Dismissal? {
        let result = offerID.map { deferred ? Dismissal.deferred($0) : Dismissal.dismissed($0) }
        offerID = nil; deferred = false; presenting = false
        return result
    }
}

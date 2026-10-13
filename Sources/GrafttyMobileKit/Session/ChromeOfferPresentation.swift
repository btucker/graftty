import Foundation

/// Reservations carry a sheet identity distinct from the immutable host offer ID.
struct ChromeOfferPresentation {
    enum Dismissal: Equatable { case dismissed(UUID), deferred(UUID) }
    private(set) var presentationID: UUID?
    private(set) var isMounted = false
    private var offerID: UUID?
    private var deferred = false
    var canPresent: Bool { presentationID == nil }

    mutating func begin(_ id: UUID?, presentationID: UUID = UUID()) -> Bool {
        guard canPresent else { return false }
        self.presentationID = presentationID
        offerID = id; deferred = false; isMounted = false
        return true
    }

    mutating func markMounted(_ id: UUID) -> Bool {
        guard presentationID == id, !deferred else { return false }
        isMounted = true
        return true
    }

    mutating func deferCurrent() -> UUID? {
        deferred = true
        return offerID
    }

    mutating func cancelPending() -> Dismissal? {
        guard !isMounted, let id = presentationID else { return nil }
        deferred = true
        return finishDismissal(id)
    }

    mutating func finishDismissal(_ id: UUID) -> Dismissal? {
        guard presentationID == id else { return nil }
        let result = offerID.map { deferred ? Dismissal.deferred($0) : Dismissal.dismissed($0) }
        presentationID = nil; offerID = nil; deferred = false; isMounted = false
        return result
    }
}

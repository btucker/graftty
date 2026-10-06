import Foundation
import Testing
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@MainActor
struct AgentNotificationDeliveryTests {
    @Test("@spec NOTIF-1.10: When identity lookup or notification authorization overlaps a newer Attention notification for the same worktree, the application shall deliver only the latest pending notification while preserving independent worktree deliveries and cleaning its original attachment source file.")
    func laterRequestWinsDuringIdentityLookup() async {
        let delivery = AgentNotificationDelivery()
        let started = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        var delivered: [String] = []
        let older = AgentStopNotificationContent(title: "Older", body: "", userInfo: [:], identifier: "home")
        let newer = AgentStopNotificationContent(title: "Newer", body: "", userInfo: [:], identifier: "home")
        let independent = AgentStopNotificationContent(title: "Linked", body: "", userInfo: [:], identifier: "linked")
        let oldReservation = delivery.reserve(older)
        let first = Task {
            await delivery.post(older, reservation: oldReservation, authorized: { true }, resolving: { notification in
                started.continuation.yield()
                _ = await resume.stream.first { _ in true }
                return notification
            }, deliver: { delivered.append($0.request.content.title) })
        }
        _ = await started.stream.first { _ in true }
        await delivery.post(newer, reservation: delivery.reserve(newer), authorized: { true }, resolving: { $0 }, deliver: { delivered.append($0.request.content.title) })
        await delivery.post(independent, reservation: delivery.reserve(independent), authorized: { true }, resolving: { $0 }, deliver: { delivered.append($0.request.content.title) })
        resume.continuation.yield()
        await first.value
        #expect(delivered == ["Newer", "Linked"])

        // Scheduling the older Task last must not make it the latest event.
        let lateOldReservation = delivery.reserve(older)
        let newReservation = delivery.reserve(newer)
        await delivery.post(newer, reservation: newReservation, authorized: { true }, resolving: { $0 },
            deliver: { delivered.append($0.request.content.title) })
        var olderLookupRan = false
        await delivery.post(older, reservation: lateOldReservation, authorized: { true }, resolving: {
            olderLookupRan = true
            return $0
        }, deliver: { delivered.append($0.request.content.title) })
        #expect(!olderLookupRan)
        #expect(delivered == ["Newer", "Linked", "Newer"])

        var illustrated = newer
        illustrated.identityImage = ProjectNotificationIdentity.image(
            project: SidebarProject(id: "project", repositoryID: "/repo", name: "Project"), data: nil)
        var sourceURL: URL?
        await delivery.post(illustrated, reservation: delivery.reserve(illustrated), authorized: { true },
            resolving: { $0 }, deliver: { prepared in
                sourceURL = prepared.sourceURL
                #expect(prepared.request.content.attachments.count == 1)
            })
        #expect(sourceURL != nil)
        #expect(sourceURL.map { FileManager.default.fileExists(atPath: $0.path) } == false)
    }
}

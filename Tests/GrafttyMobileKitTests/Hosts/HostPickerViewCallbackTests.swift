#if canImport(UIKit)
import Testing
import Foundation
import GrafttyProtocol
import SwiftUI
import UIKit
@testable import GrafttyMobileKit

@MainActor
@Suite("HostPickerView", .serialized)
struct HostPickerViewCallbackTests {

    @Test("@spec REMOTE-13.65: While the mobile host list is open, the application shall render each relay host as an indented row beneath its paired intermediary Mac and preserve a separate reconnect action for each route.")
    func relayHostsAppearBeneathTheirIntermediaries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostStore(storeURL: directory.appendingPathComponent("hosts.json"))
        let studio = Host(label: "Studio Mac", baseURL: URL(string: "https://studio.local")!,
                          remoteDeviceID: .init(value: "studio"))
        let laptop = Host(label: "Laptop", baseURL: URL(string: "https://laptop.local")!,
                          remoteDeviceID: .init(value: "laptop"))
        try store.add(studio)
        try store.add(laptop)
        let feed = MultiHostFeed(coordinator: nil)
        feed.setHosts(store.hosts)
        let worker = RemoteMacConnectionSummary(deviceID: .init(value: "worker"),
            fingerprint: try .init(rawBytes: Data(repeating: 1, count: 32)),
            label: "Worker", lastKnownHost: "worker.local", state: .offline)
        await feed.downstreamConnections.refresh(hosts: store.hosts.map {
            .init(id: $0.id, label: $0.label)
        }) { _, _ in .remoteMacConnections([worker]) }

        let view = NavigationStack {
            HostPickerView(store: store).environment(\.multiHostFeed, feed)
        }.environment(\.accessibilityEnabled, true)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousWindow = scene?.windows.first { $0.isKeyWindow }
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        var objects: [NSObject] = []
        for _ in 0..<100 {
            controller.view.layoutIfNeeded()
            objects = accessibilityObjects(in: controller.view)
            if objects.filter({ $0.accessibilityLabel == "Worker" }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let children = objects.filter { $0.accessibilityLabel == "Worker" }
            .sorted { $0.accessibilityFrame.minY < $1.accessibilityFrame.minY }
        #expect(children.count == 2)
        let list = try #require(objects.compactMap { $0 as? UICollectionView }.first)
        func cell(at frame: CGRect) -> IndexPath? {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            return list.indexPathForItem(at: list.convert(center, from: window.screen.coordinateSpace))
        }
        for (index, parent) in store.hosts.enumerated() {
            let parentFrame = try #require(objects.first { $0.accessibilityLabel == parent.label }).accessibilityFrame
            let childFrame = try #require(children.indices.contains(index) ? children[index] : nil).accessibilityFrame
            // A child swipe must not expose its intermediary's forget action.
            #expect(try #require(cell(at: childFrame)) != #require(cell(at: parentFrame)))
            #expect(childFrame.minY > parentFrame.maxY)
            // Include the existing 20-point icon and 10-point gap so icon
            // spacing alone cannot satisfy the 24-point nesting requirement.
            #expect(childFrame.minX >= parentFrame.minX + 24 + 30 - 1)
            if index + 1 < store.hosts.count {
                let nextParent = try #require(objects.first { $0.accessibilityLabel == store.hosts[index + 1].label })
                #expect(childFrame.maxY < nextParent.accessibilityFrame.minY)
            }
            #expect(objects.contains { $0.accessibilityLabel == "Connect to Worker via \(parent.label)" })
        }
        #expect(!objects.contains { $0.accessibilityLabel == "Through another Mac" })
        if scene != nil {
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            Attachment.record(try #require(image.pngData()), named: "graftty-relay-hosts.png")
        }
    }

    private func accessibilityObjects(in root: NSObject) -> [NSObject] {
        var result: [NSObject] = [], pending = [root], seen: Set<ObjectIdentifier> = []
        while let object = pending.popLast(), result.count < 4096 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            if let view = object as? UIView { pending.append(contentsOf: view.subviews) }
            pending.append(contentsOf: (object.accessibilityElements ?? []).compactMap { $0 as? NSObject })
            if object.accessibilityElementCount() > 0 {
                for index in 0..<min(object.accessibilityElementCount(), 512) {
                    if let child = object.accessibilityElement(at: index) as? NSObject { pending.append(child) }
                }
            }
        }
        return result
    }

    @Test("onSelect: nil is the default (push-nav mode)")
    func onSelectDefaultsToNil() {
        let store = HostStore(storeURL: URL(fileURLWithPath: "/tmp/hostpickerview-default-\(UUID()).json"))
        let view = HostPickerView(store: store)
        #expect(view.onSelect == nil)
    }

    @Test("onSelect: non-nil is stored")
    func onSelectCallbackStored() {
        let store = HostStore(storeURL: URL(fileURLWithPath: "/tmp/hostpickerview-cb-\(UUID()).json"))
        var captured: Host?
        let view = HostPickerView(store: store) { host in
            captured = host
        }
        #expect(view.onSelect != nil)

        let probe = Host(
            id: UUID(),
            label: "probe",
            baseURL: URL(string: "https://probe.local")!,
            addedAt: Date(),
            lastUsedAt: nil
        )
        view.onSelect?(probe)
        #expect(captured?.id == probe.id)
    }
}
#endif

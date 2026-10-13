import SwiftUI
#if GRAFTTY_BROWSER_CONTROL_FIXTURE
import GrafttyProtocol
import UIKit
@testable import GrafttyMobileKit
#endif

// UIKit and WebKit integration tests need UIApplicationMain and foreground
// events, without starting production pairing, session, or biometric state.
@main
struct GrafttyMobileTestHost: App {
    var body: some Scene {
        WindowGroup {
            #if GRAFTTY_BROWSER_CONTROL_FIXTURE
            if ProcessInfo.processInfo.arguments.contains("--image-controls-fixture") {
                ImageControlsFixture()
            } else {
                BrowserControlFixture()
            }
            #else
            Color.clear
            #endif
        }
    }
}

#if GRAFTTY_BROWSER_CONTROL_FIXTURE
private struct BrowserControlFixture: View {
    @State private var activated = false
    var body: some View {
        VStack(spacing: 24) {
            RemoteOpenButton.floatingControl(availableCount: 1, isBusy: false) { activated = true }
                .padding(14)
            Text(activated ? "Activated" : "Idle")
        }
        .preferredColorScheme(.light)
    }
}

/// Launch-only interaction fixture for the production clipped-pane controls.
private struct ImageControlsFixture: View {
    @State private var coordinator = RemoteConnectionCoordinator(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
        connectionsAllowedInitially: false)
    @State private var host = Host(label: "Fixture Mac", baseURL: URL(string: "https://host.invalid")!)
    @State private var offer: RemoteOpenOffer?
    private let device = RemoteDeviceID(value: "fixture-phone")
    private var bytes: Data {
        UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }
    }

    var body: some View {
        Color.black.frame(width: 78, height: 78)
            .overlay(alignment: .topTrailing) {
                RemoteOpenButton(host: host, worktree: "/fixture", coordinator: coordinator, sessionName: "pane",
                    ownerDeviceID: device, isActive: true, managementTransport: { request, _ in
                        if case .openResource(_, .read) = request { return .openResource(.chunk(bytes)) }
                        return .openResource(.offers(offer.map { [$0] } ?? []))
                    }, browserConnectionReady: true, isPaneFocused: true, hasOwnershipSnapshot: true,
                    isPaneOwner: { true }, canPresentAuthentication: { true }, terminalRequest: .constant(nil))
                    .modifier(TerminalFloatingControlPlacement()).padding(.trailing, 12)
            }
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Image pane")
            .accessibilityIdentifier("Image pane")
            .preferredColorScheme(.light)
            .onAppear {
                guard offer == nil else { return }
                offer = RemoteOpenOffer(id: UUID(), filename: "image.png", byteCount: bytes.count,
                    paneSessionName: "pane", previewKind: "image", previewOwnerDeviceID: device)
            }
    }
}

#endif

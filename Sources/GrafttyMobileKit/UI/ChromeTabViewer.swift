#if canImport(UIKit)
import GrafttyProtocol
import GrafttyRemoteClient
import SwiftUI
import UIKit

/// Rendering and OAuth callbacks both execute on the host Mac.
struct ChromeTabViewer: View {
    let target: String
    let connectionProvider: RemoteConnectionProvider
    var initialLaunch: ChromeTabInitialLaunch? = nil
    var paneReady = true
    var onLaunch: () -> Void = {}
    @State private var model = ChromeTabViewerModel()
    @State private var connectionAttempt = 0
    private struct RunScope: Hashable { let ready: Bool; let attempt: Int }
    @State private var launchURL = ""
    @State private var text = ""
    @FocusState private var textFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.biometricGate) private var gate
    private var ready: Bool { paneReady && LiveSessionReadiness.isActive(scene: scenePhase, gateUnlocked: gate.isUnlocked) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(ready ? "Dedicated Chrome on your Mac. Tabs stay open when you disconnect." : "Sign-in is paused until this pane reconnects with ownership.")
                    .font(.footnote).foregroundStyle(.secondary)
                if initialLaunch != nil, model.error != nil || model.initialLaunchError != nil {
                    Button("Retry sign-in") {
                        connectionAttempt += 1
                    }.disabled(model.busy)
                }
                HStack {
                    TextField("Launch https://…", text: $launchURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { launch() }
                    Button("Open") { launch() }.disabled(model.busy || !ChromeTabAction.launch(url: launchURL).isValid)
                }
                Menu {
                    ForEach(model.state.tabs) { tab in
                        Button(tab.title.isEmpty ? tab.url : tab.title) { send(.select(tabID: tab.id)) }
                    }
                } label: {
                    Label(model.state.tabs.first(where: { $0.id == model.state.selectedTabID })?.title ?? "Select a tab", systemImage: "rectangle.on.rectangle")
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(model.busy || model.state.tabs.isEmpty)
                if let error = model.error ?? model.initialLaunchError { Text(error).font(.footnote).foregroundStyle(.red) }
                GeometryReader { geometry in
                    ZStack {
                        Color.black
                        if let image = model.image {
                            Image(uiImage: image).resizable().aspectRatio(4.0 / 3.0, contentMode: .fit)
                        } else {
                            Text(model.state.tabs.isEmpty ? "Open a URL to start the dedicated browser." : "Waiting for selected tab…").foregroundStyle(.white)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        guard let id = model.state.selectedTabID, model.image != nil,
                              let point = ChromeTabCoordinates.normalized(value.startLocation, in: geometry.size) else { return }
                        if hypot(value.translation.width, value.translation.height) < 8 {
                            Task { if await model.send(.tap(tabID: id, x: point.x, y: point.y), target: target) { textFocused = true } }
                        } else {
                            let scale = CGFloat(ChromeTabFrame.viewportWidth) / min(geometry.size.width, geometry.size.height * 4 / 3)
                            send(.scroll(tabID: id, x: point.x, y: point.y,
                                deltaX: max(-2000, min(2000, -value.translation.width * scale)),
                                deltaY: max(-2000, min(2000, -value.translation.height * scale))))
                        }
                    })
                }
                HStack {
                    TextField("Text for focused field", text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($textFocused).onSubmit { insertText() }
                    Button("Send") { insertText() }.disabled(model.busy || model.state.selectedTabID == nil || text.utf8.count > 4096)
                }
                HStack {
                    Button("Tab") { key(.tab) }
                    Button("Delete") { key(.backspace) }
                    Button("Escape") { key(.escape) }
                    Spacer()
                    Button("Return") { key(.enter) }
                }.disabled(model.busy || model.state.selectedTabID == nil)
            }
            .padding().navigationTitle("Chrome on Mac").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task(id: RunScope(ready: ready, attempt: connectionAttempt)) {
                if ready { await model.run(target: target, initialLaunch: initialLaunch, onLaunch: onLaunch, makeDriver: {
                    guard let connection = await connectionProvider() else { throw ChromeViewerUnavailable() }
                    return try await connection.makeChromeTabClient()
                }) }
                else { model.close() }
            }
            .onDisappear { model.close() }
        }
    }

    private struct ChromeViewerUnavailable: Error, CustomStringConvertible {
        var description: String { "Chrome needs a paired Mac connection." }
    }

    private func send(_ action: ChromeTabAction) { Task { await model.send(action, target: target) } }
    private func launch() { send(.launch(url: launchURL)) }
    private func insertText() {
        guard let id = model.state.selectedTabID else { return }
        let value = text
        Task { if await model.send(.text(tabID: id, text: value), target: target), text == value { text = "" } }
    }
    private func key(_ key: ChromeTabKey) {
        if let id = model.state.selectedTabID { send(.key(tabID: id, key: key)) }
    }
}
#endif

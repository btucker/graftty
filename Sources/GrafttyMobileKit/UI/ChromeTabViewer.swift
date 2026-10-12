#if canImport(UIKit)
import GrafttyProtocol
import GrafttyRemoteClient
import SwiftUI
import UIKit

@MainActor @Observable
private final class ChromeTabViewerModel {
    var state = ChromeTabState()
    var image: UIImage?
    var error: String?
    private var pendingCount = 0
    private var inputCount = 0
    var busy: Bool { inputCount > 0 }
    private var client: ChromeTabClient?
    private var generation = UUID()
    private var requestOrdinal = 0
    private var lastAppliedOrdinal = 0
    private var frameSequence: UInt64?
    private var frameTabID: String?

    func run(target: String, provider: @escaping RemoteConnectionProvider) async {
        close()
        let epoch = generation
        do {
            guard let connection = await provider() else { if generation == epoch, !Task.isCancelled { error = "Chrome needs a paired Mac connection." }; return }
            let driver = try await connection.makeChromeTabClient()
            guard !Task.isCancelled, generation == epoch else { driver.close(); return }
            let connectionClient = ChromeTabClient(driver: driver)
            client = connectionClient
            do { try await connectionClient.open() }
            catch {
                driver.close()
                if generation == epoch, !Task.isCancelled {
                    self.error = "This host does not support dedicated Chrome tabs. Update the Mac app to use the prototype."
                    client = nil
                }
                return
            }
            guard !Task.isCancelled, generation == epoch else { driver.close(); return }
            defer { driver.close(); if generation == epoch { client = nil; image = nil } }
            let listed = await send(.list, target: target)
            guard listed, !Task.isCancelled, generation == epoch else { return }
            if let first = state.tabs.first?.id { await send(.select(tabID: first), target: target) }
            while !Task.isCancelled, generation == epoch {
                try await Task.sleep(for: .milliseconds(250))
                if pendingCount == 0 {
                    await send(state.selectedTabID.map { .frame(tabID: $0) } ?? .list, target: target, polling: true)
                }
            }
        } catch {
            if !Task.isCancelled, generation == epoch { self.error = String(describing: error) }
        }
    }

    @discardableResult
    func send(_ action: ChromeTabAction, target: String, polling: Bool = false) async -> Bool {
        guard let client, !Task.isCancelled else { return false }
        if polling, pendingCount > 0 { return false }
        let epoch = generation
        requestOrdinal += 1
        let ordinal = requestOrdinal
        pendingCount += 1
        if !polling { inputCount += 1 }
        defer { if generation == epoch { pendingCount -= 1; if !polling { inputCount -= 1 } } }
        do {
            let reply = try await client.send(.init(target: target, action: action))
            guard !Task.isCancelled, generation == epoch else { return false }
            guard ordinal >= lastAppliedOrdinal else { return reply.error == nil }
            lastAppliedOrdinal = ordinal
            error = reply.error
            guard let next = reply.state else { image = nil; return false }
            state = next
            if let frame = next.frame, frame.tabID == next.selectedTabID,
               frame.jpeg.count <= ChromeTabFrame.maximumJPEGBytes {
                if frame.sequence != frameSequence || frame.tabID != frameTabID {
                    let decoded = UIImage(data: frame.jpeg)
                    if let decoded, decoded.size.width <= 2048, decoded.size.height <= 2048 {
                        image = decoded; frameSequence = frame.sequence; frameTabID = frame.tabID
                    }
                }
            } else { image = nil; frameSequence = nil; frameTabID = nil }
            return reply.error == nil
        } catch ChromeTabClient.Failure.queueFull {
            if generation == epoch { error = "Chrome input queue is full. Try sending again." }
            return false
        } catch {
            if generation == epoch { self.error = "Chrome connection ended. Close and reopen to reconnect."; image = nil; client.cancel(); self.client = nil }
            return false
        }
    }

    func close() {
        generation = UUID(); client?.cancel(); client = nil
        image = nil; state = .init(); pendingCount = 0; inputCount = 0; error = nil
        frameSequence = nil; frameTabID = nil; requestOrdinal = 0; lastAppliedOrdinal = 0
    }
}

/// Explicit opt-in. Rendering and OAuth callbacks both execute on the host Mac.
struct ChromeTabViewer: View {
    let target: String
    let connectionProvider: RemoteConnectionProvider
    @State private var model = ChromeTabViewerModel()
    @State private var launchURL = ""
    @State private var text = ""
    @FocusState private var textFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.biometricGate) private var gate
    private var ready: Bool { LiveSessionReadiness.isActive(scene: scenePhase, gateUnlocked: gate.isUnlocked) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Dedicated Chrome on your Mac. Tabs stay open when you disconnect.")
                    .font(.footnote).foregroundStyle(.secondary)
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
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
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
            .task(id: ready) {
                if ready { await model.run(target: target, provider: connectionProvider) }
                else { model.close() }
            }
            .onDisappear { model.close() }
        }
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

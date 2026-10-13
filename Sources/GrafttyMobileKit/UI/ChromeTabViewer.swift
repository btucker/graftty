#if canImport(UIKit)
import GrafttyProtocol
import GrafttyRemoteClient
import SwiftUI
import UIKit

/// Rendering and OAuth callbacks both execute on the host Mac.
@MainActor
struct ChromeTabViewer: View {
    let target: String
    let connectionProvider: RemoteConnectionProvider
    var initialLaunch: ChromeTabInitialLaunch?
    var paneReady: Bool
    var onLaunch: () -> Void
    var onChooseLocal: ((URL?) -> Void)?
    var localPreparing: Bool
    var localError: String?
    private var driverProvider: (() async throws -> any ChromeTabChannelDriver)?
    @State private var model: ChromeTabViewerModel
    @State private var connectionAttempt = 0
    @State private var mode = BrowserMode.remote
    @State private var showingAddress = false
    @State private var launchURL = ""
    @State private var text = ""
    @FocusState private var textFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.biometricGate) private var gate

    private enum BrowserMode: Hashable { case local, remote }
    private struct RunScope: Hashable { let ready: Bool; let attempt: Int }
    private var ready: Bool { paneReady && LiveSessionReadiness.isActive(scene: scenePhase, gateUnlocked: gate.isUnlocked) }
    private var selectedTab: ChromeTab? { model.state.tabs.first { $0.id == model.state.selectedTabID } }
    private var localPageURL: URL? {
        guard model.image != nil, model.error == nil,
              let tab = selectedTab, tab.urlTruncated != true,
              tab.urlTruncated != nil || tab.url.utf8.count < 2048,
              ChromeTabAction.launch(url: tab.url).isValid else { return nil }
        return URL(string: tab.url)
    }
    private var canNavigate: Bool { ready && model.isConnected && !model.busy && model.state.selectedTabID != nil }

    init(target: String, connectionProvider: @escaping RemoteConnectionProvider,
         initialLaunch: ChromeTabInitialLaunch? = nil, paneReady: Bool = true,
         onLaunch: @escaping () -> Void = {}, onChooseLocal: ((URL?) -> Void)? = nil,
         localPreparing: Bool = false, localError: String? = nil,
         model: ChromeTabViewerModel? = nil,
         driverProvider: (() async throws -> any ChromeTabChannelDriver)? = nil) {
        self.target = target
        self.connectionProvider = connectionProvider
        self.initialLaunch = initialLaunch
        self.paneReady = paneReady
        self.onLaunch = onLaunch
        self.onChooseLocal = onChooseLocal
        self.localPreparing = localPreparing
        self.localError = localError
        self.driverProvider = driverProvider
        self._model = State(initialValue: model ?? ChromeTabViewerModel())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if gate.isUnlocked {
                    header
                    status
                    page
                } else {
                    ContentUnavailableView {
                        Label("Graftty is locked", systemImage: "lock.fill")
                    } actions: {
                        Button("Unlock Graftty") { Task { await gate?.authenticate() } }
                    }
                }
            }
            .background(Color(uiColor: .systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if gate.isUnlocked {
                    VStack(spacing: 0) {
                        if model.keyboardPresented { keyboardInput }
                        browserControls
                    }
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
                }
            }
            .alert("Open a new tab", isPresented: $showingAddress) {
                TextField("https://", text: $launchURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Open") { launch() }
                    .disabled(!ready || !model.isConnected || model.busy || !ChromeTabAction.launch(url: launchURL).isValid)
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: mode) { _, chosen in
                guard chosen == .local else { return }
                mode = .remote
                model.keyboardPresented = false
                textFocused = false
                chooseLocal()
            }
            .onChange(of: ready) { _, active in
                if !active { model.keyboardPresented = false; textFocused = false }
            }
            .onChange(of: gate.isUnlocked) { _, unlocked in
                if !unlocked { showingAddress = false; launchURL = ""; text = "" }
            }
            .onChange(of: model.keyboardPresented) { _, visible in
                if !visible { textFocused = false }
            }
            .task(id: RunScope(ready: ready, attempt: connectionAttempt)) {
                if ready {
                    await model.run(target: target, initialLaunch: initialLaunch, onLaunch: onLaunch, makeDriver: {
                        if let driverProvider { return try await driverProvider() }
                        guard let connection = await connectionProvider() else { throw ChromeViewerUnavailable() }
                        return try await connection.makeChromeTabClient()
                    })
                } else { model.suspend() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if onChooseLocal != nil, localPageURL != nil {
                Picker("Browser mode", selection: $mode) {
                    Text("Local").tag(BrowserMode.local)
                    Text("Remote").tag(BrowserMode.remote)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .disabled(!ready || !model.isConnected || localPreparing || model.busy)
                .accessibilityIdentifier("chrome-browser-mode")
            }

            Button { showingAddress = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: selectedTab?.url.hasPrefix("https://") == true ? "lock.fill" : "globe")
                        .font(.system(size: 10))
                    Text(selectedTab.flatMap { URL(string: $0.url)?.host } ?? "New tab")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if model.busy || localPreparing { ProgressView().controlSize(.mini) }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open address")
            .accessibilityValue(selectedTab?.url ?? "New tab")

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done")
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var status: some View {
        if let error = localError ?? model.error ?? model.initialLaunchError {
            HStack(spacing: 8) {
                Text(error).font(.caption).foregroundStyle(.red)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if localError == nil, initialLaunch != nil, model.error != nil || model.initialLaunchError != nil {
                    Button("Retry") { connectionAttempt += 1 }
                        .disabled(model.busy || !ready)
                        .accessibilityLabel("Retry sign-in")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        } else if !ready {
            Label("Waiting for pane connection", systemImage: "wifi.slash")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var page: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .secondarySystemBackground)
                if let image = model.image {
                    Image(uiImage: image).resizable()
                        .aspectRatio(model.frameSize.width / model.frameSize.height, contentMode: .fit)
                } else {
                    VStack(spacing: 8) {
                        if ready { ProgressView() }
                        Text(ready ? "Waiting for page…" : "Browser paused")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
            .accessibilityIdentifier("chrome-page")
            .onChange(of: geometry.size, initial: true) { _, size in model.requestViewport(size, target: target) }
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                guard ready, model.frameInputEnabled, let id = model.state.selectedTabID, model.image != nil,
                      let point = ChromeTabCoordinates.normalized(value.startLocation, in: geometry.size, imageSize: model.frameSize) else { return }
                if hypot(value.translation.width, value.translation.height) < 8 {
                    send(.tap(tabID: id, x: point.x, y: point.y))
                } else {
                    let scale = 1 / min(geometry.size.width / model.frameSize.width, geometry.size.height / model.frameSize.height)
                    send(.scroll(tabID: id, x: point.x, y: point.y,
                        deltaX: max(-2000, min(2000, -value.translation.width * scale)),
                        deltaY: max(-2000, min(2000, -value.translation.height * scale))))
                }
            })
        }
    }

    private var browserControls: some View {
        HStack(spacing: 0) {
            control("Back", symbol: "chevron.backward") {
                if let id = model.state.selectedTabID { send(.back(tabID: id)) }
            }.disabled(!canNavigate || model.state.canGoBack != true)
            control("Forward", symbol: "chevron.forward") {
                if let id = model.state.selectedTabID { send(.forward(tabID: id)) }
            }.disabled(!canNavigate || model.state.canGoForward != true)
            control("Reload", symbol: "arrow.clockwise") {
                if let id = model.state.selectedTabID { send(.reload(tabID: id)) }
            }.disabled(!canNavigate || model.state.canGoBack == nil && model.state.canGoForward == nil)
            Spacer(minLength: 12)
            Menu {
                Button("New tab", systemImage: "plus") { showingAddress = true }
                    .disabled(!ready || !model.isConnected || model.busy)
                if !model.state.tabs.isEmpty { Divider() }
                ForEach(model.state.tabs) { tab in
                    Button {
                        send(.select(tabID: tab.id))
                    } label: {
                        if tab.id == model.state.selectedTabID {
                            Label(tab.title.isEmpty ? tab.url : tab.title, systemImage: "checkmark")
                        } else { Text(tab.title.isEmpty ? tab.url : tab.title) }
                    }
                }
            } label: {
                Image(systemName: "square.on.square").font(.system(size: 18))
                    .frame(width: 48, height: 44)
            }
            .accessibilityLabel("Tabs")
            .accessibilityValue("\(model.state.tabs.count)")
            .disabled(model.busy || !ready)
            control(model.keyboardPresented ? "Hide keyboard" : "Show keyboard", symbol: model.keyboardPresented ? "keyboard.chevron.compact.down" : "keyboard") {
                model.toggleKeyboard()
            }.disabled(!canNavigate)
                .accessibilityIdentifier("chrome-keyboard-toggle")
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    private var keyboardInput: some View {
        HStack(spacing: 8) {
            TextField("Enter text", text: $text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($textFocused).onSubmit { insertText() }
                .submitLabel(.send)
                .textFieldStyle(.roundedBorder)
            Menu {
                Button("Return") { key(.enter) }
                Button("Tab") { key(.tab) }
                Button("Delete") { key(.backspace) }
                Button("Escape") { key(.escape) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 44)
            }
            .accessibilityLabel("Keyboard actions")
            .disabled(!canNavigate)
            Button { insertText() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                    .frame(width: 36, height: 44)
            }
            .accessibilityLabel("Send text")
            .disabled(!canNavigate || text.isEmpty || text.utf8.count > 4096)
        }
        .padding(.horizontal, 12)
        .task { textFocused = true }
    }

    private func control(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(title)
    }

    private struct ChromeViewerUnavailable: Error, CustomStringConvertible {
        var description: String { "Chrome needs a paired Mac connection." }
    }

    private func send(_ action: ChromeTabAction) { Task { await model.send(action, target: target) } }

    private func chooseLocal() {
        guard ready, model.isConnected, !model.busy, !localPreparing, let page = localPageURL else { return }
        onChooseLocal?(page)
    }

    private func launch() {
        guard ready, !model.busy, ChromeTabAction.launch(url: launchURL).isValid else { return }
        guard model.isConnected else { model.error = "Chrome is connecting. Try again."; return }
        let requestedURL = launchURL
        Task {
            if await model.send(.launch(url: requestedURL), target: target), launchURL == requestedURL { launchURL = "" }
        }
    }

    private func insertText() {
        guard canNavigate, let id = model.state.selectedTabID, !text.isEmpty, text.utf8.count <= 4096 else { return }
        let value = text
        Task { if await model.send(.text(tabID: id, text: value), target: target), text == value { text = "" } }
    }

    private func key(_ key: ChromeTabKey) {
        if canNavigate, let id = model.state.selectedTabID { send(.key(tabID: id, key: key)) }
    }
}
#endif

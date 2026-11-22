import GrafttyWatchKit
import SwiftUI

struct WatchTerminalListView: View {
    let connection: WatchPhoneConnection

    var body: some View {
        List {
            ForEach(connection.inbox.snapshot.terminals ?? []) { target in
                NavigationLink {
                    WatchTerminalView(connection: connection, target: target)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(target.project + " · " + target.worktree).font(.caption2).foregroundStyle(.secondary)
                        Text(target.title).font(.headline)
                        Text(target.host).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if connection.inbox.snapshot.terminals?.isEmpty != false {
                Text((connection.inbox.snapshot.omittedTerminalCount ?? 0) > 0
                    ? "Open Graftty on iPhone to view the remaining terminals."
                    : "No running terminals. Refresh to check your Macs.").font(.footnote)
            }
            if let omitted = connection.inbox.snapshot.omittedTerminalCount, omitted > 0 {
                Text("\(omitted) more panes on iPhone.").font(.footnote)
            }
            if !connection.inbox.snapshot.unavailableHosts.isEmpty {
                Text("Unavailable: " + connection.inbox.snapshot.unavailableHosts.joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let error = connection.inbox.error { Text(error).font(.footnote).foregroundStyle(.orange) }
            Button("Refresh") { Task { await connection.refresh() } }
                .disabled(connection.inbox.isRefreshing)
        }
        .navigationTitle("Terminals")
    }
}

struct WatchTerminalView: View {
    let connection: WatchPhoneConnection
    @State private var model: WatchTerminalModel
    @State private var paused = false
    @State private var followOutput = true
    @State private var wrapLines = true
    @State private var showsOptions = false
    @AppStorage("watchTerminalFontSize") private var fontSize = 9.0
    @Environment(\.scenePhase) private var scenePhase

    init(connection: WatchPhoneConnection, target: WatchTerminalTarget) {
        self.connection = connection
        _model = State(initialValue: WatchTerminalModel(target: target))
    }

    private var updatesActive: Bool {
        connection.inbox.snapshot.isEnabled && scenePhase == .active && !paused && !showsOptions
    }
    private var displayFontSize: Double { fontSize.isFinite ? min(14, max(6, fontSize)) : 9 }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(wrapLines ? [.vertical] : [.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 8) {
                    if !connection.inbox.snapshot.isEnabled {
                        Text("Enable Apple Watch in Graftty's Hosts screen on iPhone.").font(.footnote)
                    } else if let frame = model.frame {
                        Text(frame.text.isEmpty ? "Terminal is empty." : frame.text)
                            .font(.system(size: displayFontSize, design: .monospaced))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: !wrapLines, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("watch.terminal.output")
                    } else if model.isLoading {
                        ProgressView("Opening terminal…")
                    }
                    if let error = model.error {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                    HStack {
                        Image(systemName: paused ? "pause.circle" : "arrow.triangle.2.circlepath")
                        Text(paused ? "Paused" : "Auto-refresh")
                        Spacer(minLength: 2)
                        Text("Read-only")
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .id("terminal-bottom")
                }
                .padding(.horizontal, 3)
            }
            .onChange(of: model.frame?.text) { _, _ in
                if followOutput { reader.scrollTo("terminal-bottom", anchor: .bottom) }
            }
        }
        .background(.black)
        .navigationTitle(model.target.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsOptions = true } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Terminal options")
            }
        }
        .sheet(isPresented: $showsOptions) {
            List {
                Toggle("Pause updates", isOn: $paused)
                Toggle("Follow output", isOn: $followOutput)
                Toggle("Wrap lines", isOn: $wrapLines)
                HStack {
                    Button { fontSize = max(6, displayFontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                        .accessibilityLabel("Smaller font")
                    Text("\(Int(displayFontSize)) pt").font(.footnote)
                    Button { fontSize = min(14, displayFontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                        .accessibilityLabel("Larger font")
                }
                Button("Refresh now") {
                    showsOptions = false
                    Task { await model.refresh(using: connection.send) }
                }
                Button("Done") { showsOptions = false }
            }
        }
        .task(id: updatesActive) {
            guard updatesActive else { model.stop(); return }
            while !Task.isCancelled {
                await model.refresh(using: connection.send)
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .onDisappear { model.stop() }
    }
}

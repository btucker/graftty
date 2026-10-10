import AppKit
import SwiftUI
import GrafttyKit

struct LinuxHostSetupForm: Equatable {
    enum Phase: Equatable {
        case idle, running, cancelling, cancelled, connected
        case failed(String)
    }

    var destination = ""
    var destinationRoot = "~/projects"
    var version = ""
    var phase: Phase = .idle
    var progress: LinuxHostSetupProgress?
    var isRunning: Bool { phase == .running || phase == .cancelling }
    var canStart: Bool { !isRunning && phase != .connected && (try? LinuxHostDestination(destination)) != nil }

    mutating func start() { phase = .running; progress = nil }
    mutating func update(_ value: LinuxHostSetupProgress) { progress = value }
    mutating func fail(_ message: String) { phase = .failed(message) }
    mutating func cancel() { phase = .cancelling }
    mutating func finishCancellation() { phase = .cancelled }
}

/// Parent supplies its existing client public identity and persists/pins the
/// authenticated result before connecting through the direct-SSH registry.
struct LinuxHostSetupSheet: View {
    let client: LinuxHostTrustRequest
    var initialProjects: [LinuxHostProject] = []
    var setup = LinuxHostSetup()
    let onConnect: @MainActor (LinuxHostSetupResult) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var form = LinuxHostSetupForm()
    @State private var projects: [LinuxHostProject] = []
    @State private var selectedPaths = Set<String>()
    @State private var localArchive: URL?
    @State private var task: Task<Void, Never>?
    @State private var loadingProject = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Linux Host").font(.title2.weight(.semibold))
            Text("Use an x86_64 or ARM64 Linux host with systemd and OpenSSH access. Archives are tested on Ubuntu 24.04; other systems are untested and checked for compatibility before installation. Graftty connects directly to port 8801.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("SSH destination", text: $form.destination, prompt: Text("user@host or ~/.ssh/config alias"))
                    .accessibilityIdentifier("linuxSetupDestination")
                TextField("Linux project root", text: $form.destinationRoot)
                    .accessibilityIdentifier("linuxSetupRoot")
                if let archive = localArchive {
                    HStack {
                        LabeledContent("Development archive", value: archive.lastPathComponent)
                        Button("Use Release") { localArchive = nil }
                    }
                } else {
                    TextField("Release version", text: $form.version, prompt: Text("1.2.3"))
                }
            }.disabled(form.isRunning)
            HStack {
                Text("Projects").font(.headline)
                Spacer()
                Button("Add Local Repository…", action: chooseRepository)
                    .disabled(form.isRunning || loadingProject)
            }
            if projects.isEmpty {
                Text("Choose local repositories to import, or set up the host without projects.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(projects.indices, id: \.self) { index in
                            projectRow(index)
                        }
                    }.padding(2)
                }.frame(height: 220).disabled(form.isRunning)
            }
            Text("Only committed branch and tag history is imported, including unpushed commits. Working edits, untracked and ignored files, SSH keys, and local Git configuration stay on this Mac. Existing unrelated or changed Linux repositories are refused.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            status
            HStack {
                if !form.isRunning {
                    Button("Choose Development Archive…", action: chooseArchive).font(.caption)
                }
                Spacer()
                Button(form.isRunning ? "Cancel Setup" : "Close") {
                    if form.isRunning {
                        form.cancel()
                        task?.cancel()
                    } else { dismiss() }
                }.disabled(form.phase == .cancelling)
                .keyboardShortcut(.cancelAction)
                Button(startTitle, action: start)
                    .disabled(!form.canStart || loadingProject)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("linuxSetupStart")
            }
        }
        .padding(24).frame(width: 610)
        .interactiveDismissDisabled(form.isRunning)
        .onAppear {
            projects = initialProjects
            selectedPaths = []
            form.version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        }
        .onDisappear { task?.cancel() }
    }

    private var startTitle: String {
        if case .failed = form.phase { return "Retry Setup" }
        if form.phase == .cancelled { return "Retry Setup" }
        return "Set Up and Connect"
    }

    @ViewBuilder private var status: some View {
        if let progress = form.progress, form.isRunning {
            ProgressView(value: Double(progress.completed), total: Double(progress.total)) {
                Text(form.phase == .cancelling ? "Cancelling setup…" : progress.message)
            }.accessibilityIdentifier("linuxSetupProgress")
        }
        if case .failed(let message) = form.phase {
            ScrollView {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("linuxSetupError")
            }.frame(height: 100)
        }
        if form.phase == .cancelled {
            Text("Setup cancelled. Completed installs and imports are kept. Retry checks each destination before continuing.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func projectRow(_ index: Int) -> some View {
        let path = projects[index].localPath
        return VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: Binding(get: { selectedPaths.contains(path) }, set: { selected in
                if selected { selectedPaths.insert(path) } else { selectedPaths.remove(path) }
            })) { Text(path).lineLimit(1).truncationMode(.middle) }
            if selectedPaths.contains(path) {
                HStack {
                    TextField("Branch", text: $projects[index].branch)
                    TextField("Linux folder", text: $projects[index].directoryName)
                }.padding(.leading, 20)
            }
        }
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a trusted developer-built Graftty Linux tar.gz archive."
        if panel.runModal() == .OK { localArchive = panel.url }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose local Git repositories. Only committed history will be imported."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        loadingProject = true
        task = Task { @MainActor in
            defer { loadingProject = false }
            do {
                for url in urls {
                    let branch = try await CLIRunner().run(command: "git", args: ["symbolic-ref", "--short", "HEAD"], at: url.path, timeout: .seconds(15))
                    try Task.checkCancellation()
                    guard !projects.contains(where: { $0.localPath == url.path }) else { continue }
                    projects.append(.init(localPath: url.path, branch: branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines), directoryName: url.lastPathComponent))
                    selectedPaths.insert(url.path)
                }
            } catch is CancellationError { }
            catch { form.fail("Could not read this repository's branch. Choose a Git checkout with a local branch.\n\(error)") }
        }
    }

    private func start() {
        guard form.canStart else { return }
        do {
            let plan = LinuxHostSetupPlan(
                destination: try LinuxHostDestination(form.destination), destinationRoot: form.destinationRoot,
                projects: projects.filter { selectedPaths.contains($0.localPath) },
                archive: localArchive.map(LinuxHostArchive.local) ?? .release(version: form.version), client: client
            )
            try LinuxHostSetup.validateProjects(plan.projects, destinationRoot: plan.destinationRoot)
            form.start()
            task = Task { @MainActor in
                do {
                    let result = try await setup.run(plan: plan) { progress in
                        await MainActor.run { form.update(progress) }
                    }
                    try Task.checkCancellation()
                    try await onConnect(result)
                    try Task.checkCancellation()
                    form.phase = .connected
                    dismiss()
                } catch is CancellationError { form.finishCancellation() }
                catch { form.fail(LinuxHostSetupError.message(for: error)) }
            }
        } catch { form.fail(LinuxHostSetupError.message(for: error)) }
    }
}

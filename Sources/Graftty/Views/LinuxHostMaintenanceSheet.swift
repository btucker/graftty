import SwiftUI
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

struct LinuxHostMaintenanceRequest: Identifiable {
    let remote: RemoteMac
    let pinnedHost: PinnedHost
    var id: RemoteDeviceID { remote.id }
}

struct LinuxHostMaintenanceSheet: View {
    let remote: RemoteMac
    let pinnedHost: PinnedHost
    let onValidated: (LinuxHostDestination) throws -> Void
    let onReconnect: () async -> Bool
    var maintenance = LinuxHostMaintenance()

    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var inspection: LinuxHostMaintenance.Inspection?
    @State private var components = Set(LinuxHostComponent.allCases)
    @State private var replaceCustomTools = false
    @State private var confirmPublishedBuild = false
    @State private var outcomes: [LinuxHostComponentOutcome] = []
    @State private var message = ""
    @State private var isRunning = false
    @State private var cancelling = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Update \(remote.label)").font(.title2.weight(.semibold))
            Text("Review the SSH destination and tools to update. Missing tools will be installed for this Linux user. Agent sign-in remains a separate step on the host.")
                .foregroundStyle(.secondary)
            TextField("System SSH destination", text: $destination, prompt: Text("user@hostname or SSH config alias"))
                .disabled(isRunning)
                .accessibilityIdentifier("hostMaintenanceDestination")
                .onChange(of: destination) { _, _ in inspection = nil; confirmPublishedBuild = false }
            Text("Use the host's OpenSSH destination, not Graftty's port \(remote.directEndpoint?.port ?? 8801). Its public identity must match the saved pairing.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Check Host", action: inspect)
                .disabled(isRunning || (try? LinuxHostDestination(destination)) == nil)
            if let inspection {
                Text(inspection.releaseMessage).font(.callout)
                ForEach(LinuxHostComponent.allCases) { component in
                    Toggle(component.title, isOn: Binding(
                        get: { components.contains(component) },
                        set: { if $0 { components.insert(component) } else { components.remove(component) } }
                    ))
                    .disabled(isRunning || (component == .graftty && inspection.release == nil))
                }
                if components.contains(.graftty), let release = inspection.release, release.requiresReplacementConfirmation(current: inspection.probe.version) {
                    Toggle("Replace the current Graftty build (\(inspection.probe.version)) with published \(release.version)", isOn: $confirmPublishedBuild)
                        .disabled(isRunning)
                    Text("The host service restarts. Pairing, projects and terminal sessions are preserved. This build is newer or has no comparable release version.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Replace custom Codex or Claude installations", isOn: $replaceCustomTools)
                    .disabled(isRunning)
                Text("Native tools update in place. Package-managed or custom commands are skipped unless replacement is selected; replacement installs in ~/.local/bin and may shadow another command. Existing native Claude updates keep its configured release channel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isRunning { ProgressView(cancelling ? "Cancelling…" : message).controlSize(.small) }
            else if !message.isEmpty { Text(message).font(.callout) }
            if !outcomes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(outcomes) { outcome in
                            Text("\(outcome.component.title): \(outcomeTitle(outcome.status))").font(.headline)
                            Text(outcome.message).font(.caption).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 200)
            }
            HStack {
                Spacer()
                Button(isRunning ? "Cancel" : "Close") {
                    if isRunning { cancelling = true; task?.cancel() } else { dismiss() }
                }.disabled(cancelling).keyboardShortcut(.cancelAction)
                Button("Update Selected", action: update)
                    .disabled(isRunning || inspection == nil || components.isEmpty || needsConfirmation)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("hostMaintenanceStart")
            }
        }
        .padding(24).frame(width: 610)
        .interactiveDismissDisabled(isRunning)
        .onAppear { destination = remote.maintenanceDestination?.value ?? "" }
        .onDisappear { task?.cancel() }
    }

    private var needsConfirmation: Bool {
        guard components.contains(.graftty), let inspection, let release = inspection.release else { return false }
        return release.requiresReplacementConfirmation(current: inspection.probe.version) && !confirmPublishedBuild
    }

    private func expectedIdentity() async throws -> LinuxHostIdentity {
        let id = pinnedHost.id
        let current = try await Task.detached {
            try PinnedHostStore(directory: PinnedHostStore.defaultDirectory).get(id: id)
        }.value
        guard current?.kind == .linux, current?.publicKey == pinnedHost.publicKey,
              current?.fingerprint == remote.fingerprint, let endpoint = remote.directEndpoint else {
            throw LinuxHostSetupError.invalidPlan("This host's trusted Linux pairing changed. Close the sheet and reconnect before updating.")
        }
        return .init(deviceID: id.value, displayName: remote.label, publicKey: pinnedHost.publicKey.rawRepresentation.base64EncodedString(), port: endpoint.port)
    }

    private func inspect() {
        confirmPublishedBuild = false
        isRunning = true; cancelling = false; outcomes = []; message = "Checking identity and published Linux releases…"
        task = Task {
            defer { isRunning = false; cancelling = false }
            do {
                let expected = try await expectedIdentity()
                let checked = try await maintenance.inspect(destination: LinuxHostDestination(destination), expected: expected,
                    includePrereleases: UserDefaults.standard.bool(forKey: UpdaterController.prereleaseUpdatesDefaultsKey))
                try Task.checkCancellation()
                try onValidated(checked.destination)
                inspection = checked
                if checked.release == nil { components.remove(.graftty) }
                message = "Identity verified. Review the selections before updating."
            } catch is CancellationError { message = "Host check cancelled. No installation was started." }
            catch { inspection = nil; message = error.localizedDescription }
        }
    }

    private func update() {
        guard let inspection else { return }
        isRunning = true; cancelling = false; outcomes = []; message = "Updating selected components…"
        task = Task {
            defer { isRunning = false; cancelling = false }
            do {
                _ = try await expectedIdentity()
                try onValidated(inspection.destination)
                outcomes = await maintenance.run(inspection: inspection, components: Array(components), replaceCustomTools: replaceCustomTools, confirmPublishedReplacement: confirmPublishedBuild) { outcome in
                    await MainActor.run {
                        outcomes.append(outcome)
                        message = "Finished \(outcome.component.title); continuing selected components…"
                    }
                }
                self.inspection = nil
                if Task.isCancelled { message = "Cancelled. Verify any interrupted component on the host before retrying."; self.inspection = nil; return }
                message = outcomes.allSatisfy { $0.status == .succeeded } ? "Selected components completed. Agent sign-in is separate." : "Some components did not complete. Review their results before retrying."
                if outcomes.contains(where: { $0.component == .graftty && $0.status == .succeeded }) {
                    if !(await onReconnect()) { message += " Graftty installed, but reconnect failed. Check the host connection." }
                    if Task.isCancelled { message = "Updates finished; reconnect was cancelled. Use Connect in Remote Hosts to reconnect." }
                }
                if outcomes.contains(where: { $0.status == .unknown }) { self.inspection = nil }
            } catch { message = error.localizedDescription }
        }
    }

    private func outcomeTitle(_ status: LinuxHostComponentOutcome.Status) -> String {
        switch status { case .succeeded: "Completed"; case .failed: "Failed"; case .unknown: "Outcome unknown"; case .skipped: "Not started" }
    }
}

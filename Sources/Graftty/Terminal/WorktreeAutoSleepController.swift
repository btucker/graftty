import AppKit
import Combine
import Darwin
import GrafttyKit

@MainActor
final class WorktreeSleepState: ObservableObject {
    @Published var paths: Set<String> = []
}

/// Host-owned automatic sleep. Remote viewer worktrees never enter this
/// controller; remote attach invokes the thread-safe coordinator directly.
@MainActor
final class WorktreeAutoSleepController {
    private weak var terminalManager: TerminalManager?
    private var timer: Timer?
    private var state: (() -> AppState)?
    private var windows: [String: WorktreeSleepActivityWindow] = [:]
    private let jobTracker = WorktreeSleepJobTracker()
    private var providerEvidence: [String: (sessionID: String, activity: ProviderSleepActivity, uptime: TimeInterval)] = [:]
    private var unknownProviderPaths: Set<String> = []
    private var codexProbeUptimes: [String: TimeInterval] = [:]
    private let guardian: SleepRecoveryGuardian
    let coordinator: WorktreeSleepCoordinator

    init(terminalManager: TerminalManager, directory: URL = AppState.defaultDirectory) {
        self.terminalManager = terminalManager
        let guardian = SleepRecoveryGuardian(directory: directory.appendingPathComponent("worktree-sleep"))
        self.guardian = guardian
        self.coordinator = WorktreeSleepCoordinator(
            read: { SleepProcessReader.sample(pid: $0.pid) },
            signal: SleepProcessReader.signal,
            persist: { guardian.save($0) },
            recoveryReady: { guardian.isReady }
        )
    }

    func start(state: @escaping () -> AppState) {
        self.state = state
        guardian.recoverPreviousInstances()
        guardian.start()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func register(session: String, path: String) { coordinator.register(session: session, path: path) }

    @discardableResult func wake(path: String) -> Bool {
        windows[path] = nil
        if let worktree = state?().worktree(forPath: path) {
            for session in worktree.paneSessions.values {
                guard coordinator.wake(session: ZmxLauncher.sessionName(for: session)) else { publish(); return false }
            }
        }
        let success = coordinator.wake(path: path)
        publish()
        return success
    }

    func providerActivity(path: String, session: String?, sessionID: String?, activity: ProviderSleepActivity, runtime: TeamHookRuntime) {
        _ = wake(path: path)
        guard let session, let sessionID, !sessionID.isEmpty,
              let worktree = state?().worktree(forPath: path), worktree.paneSlot(forSessionName: session) != nil else {
            unknownProviderPaths.insert(path)
            return
        }
        providerEvidence[session] = (sessionID, activity, ProcessInfo.processInfo.systemUptime)
        if runtime == .codex { probeCodex(path: path, session: session, threadID: sessionID) }
    }

    private func probeCodex(path: String, session: String, threadID: String) {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.worktreeAutoSleep),
              let repo = state?().repos.first(where: { $0.worktrees.contains { $0.path == path } }) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = codexProbeUptimes[session], now - last < 30 { return }
        codexProbeUptimes[session] = now
        let storage = CodexAppServerSessionStorage(rootDirectory: TeamPresenceStorage.defaultRoot())
        guard let record = try? storage.read(teamID: repo.path, worktree: path, paneSessionName: session),
              record.threadID == threadID,
              let start = record.appServerProcessStartTimeMicroseconds,
              ProcessIdentityReader.startTimeMicroseconds(ofPID: record.appServerPID) == start else { return }
        let evidenceUptime = providerEvidence[session]?.uptime
        Task { [weak self] in
            let activity = await CodexAppServerClient().sleepActivity(binaryPath: record.realBinaryPath,
                socketPath: record.socketPath, expectedCWD: path,
                target: CodexAppServerTarget(threadID: threadID, activeTurnID: record.activeTurnID))
            guard let self, self.providerEvidence[session]?.sessionID == threadID,
                  self.providerEvidence[session]?.uptime == evidenceUptime else { return }
            self.providerEvidence[session] = (threadID, activity, ProcessInfo.processInfo.systemUptime)
        }
    }

    func shutdown() { timer?.invalidate(); _ = coordinator.wakeAll(); publish() }

    func tick() {
        guardian.recoverPreviousInstances()
        guard let state = state?(), let tm = terminalManager else { return }
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: SettingsKeys.worktreeAutoSleep)
        guard enabled else {
            _ = coordinator.wakeAll()
            windows.removeAll()
            publish()
            return
        }
        guardian.start()
        let duration = WorktreeSleepPreferences.duration(defaults: defaults)
        let now = ProcessInfo.processInfo.systemUptime
        let running = state.repos.flatMap(\.worktrees).filter { $0.state == .running }
        let paths = Set(running.map(\.path))
        for oldPath in coordinator.suspendedPaths.subtracting(paths) { _ = coordinator.wake(path: oldPath) }
        for path in windows.keys where !paths.contains(path) { windows[path] = nil }
        for worktree in running {
            let path = worktree.path
            if coordinator.isSleeping(path: path) {
                if !basicEligibility(worktree, state: state, manager: tm) || !guardian.isReady { _ = wake(path: path) }
                continue
            }
            guard basicEligibility(worktree, state: state, manager: tm),
                  let samples = samples(worktree, manager: tm) else { windows[path] = nil; continue }
            var window = windows[path] ?? WorktreeSleepActivityWindow()
            let idle = window.observe(samples, at: now, duration: duration)
            windows[path] = window
            guard idle else { continue }
            if let last = coordinator.lastInteractionUptime(path: path), now - last < duration { continue }
            let success = coordinator.suspend(path: path, processes: samples) { [weak self, weak tm] in
                guard let self, let tm, let state = self.state?(),
                      let current = state.worktree(forPath: path),
                      current.splitTree.allLeaves == worktree.splitTree.allLeaves,
                      self.basicEligibility(current, state: state, manager: tm),
                      let currentSamples = self.samples(current, manager: tm),
                      currentSamples.map(\.identity) == samples.map(\.identity) else { return false }
                if let last = self.coordinator.lastInteractionUptime(path: path),
                   ProcessInfo.processInfo.systemUptime - last < duration { return false }
                return zip(samples, currentSamples).allSatisfy { old, new in
                    new.cpuNanoseconds >= old.cpuNanoseconds && new.cpuNanoseconds - old.cpuNanoseconds <= 1_000_000
                        && new.diskBytes == old.diskBytes
                }
            }
            if success {
                for pane in worktree.splitTree.allLeaves { tm.evictSurface(terminalID: pane) }
            } else { windows[path] = nil }
        }
        publish()
    }

    private func basicEligibility(_ worktree: WorktreeEntry, state: AppState, manager: TerminalManager) -> Bool {
        guard worktree.state == .running, !worktree.splitTree.allLeaves.isEmpty,
              UserDefaults.standard.bool(forKey: SettingsKeys.worktreeAutoSleep),
              !WorktreeSleepPreferences.keepsAwake(worktree.path),
              !unknownProviderPaths.contains(worktree.path),
              state.selectedWorktreePath != worktree.path else { return false }
        for pane in worktree.splitTree.allLeaves {
            guard let session = manager.zmxSessionName(for: pane), manager.isShellReady(pane),
                  manager.remoteAttachmentRegistry?.isRemoteAttached(sessionName: session) == false else { return false }
            if manager.view(for: pane)?.window?.isVisible == true && manager.view(for: pane)?.isHidden == false { return false }
            if let evidence = providerEvidence[session] {
                guard evidence.activity == .idle, ProcessInfo.processInfo.systemUptime - evidence.uptime <= 60 else { return false }
            }
        }
        return true
    }

    private func samples(_ worktree: WorktreeEntry, manager: TerminalManager) -> [SleepProcessSample]? {
        guard let launcher = manager.zmxLauncher, launcher.isAvailable else { return nil }
        var result: [SleepProcessSample] = []
        var jobIdentities: [SleepProcessIdentity] = []
        var busy = false
        var incomplete = false
        for pane in worktree.splitTree.allLeaves {
            guard let session = manager.zmxSessionName(for: pane),
                  let pid = ZmxPIDLookup.shellPID(logFile: launcher.logFile(forSession: session), sessionName: session),
                  let sample = SleepProcessReader.sample(pid: pid),
                  SleepProcessReader.ownedShell(pid: pid, sessionSocket: launcher.zmxDir.appendingPathComponent(session), zmxExecutable: launcher.executable) else { incomplete = true; continue }
            result.append(sample)
            if !ShellSleepActivity.isAtPrompt(file: ShellSleepActivity.file(directory: launcher.zmxDir, session: session), identity: sample.identity,
                minimumBoundary: coordinator.lastInputBoundary(session: session)) { incomplete = true }
        }
        let subtrees = ProcessTreeWalker().descendants(rootedAt: result.map { $0.identity.pid })
        for sample in result {
            let pid = sample.identity.pid
            let descendants = subtrees[pid] ?? []
            if !descendants.contains(pid) { incomplete = true }
            // Any job is unverified for suspension, regardless of its name,
            // foreground status, output, or CPU usage. Retain escaped jobs
            // observed in earlier samples until their exact identity exits.
            for child in descendants where child != pid {
                guard let childSample = SleepProcessReader.sample(pid: child) else { incomplete = true; continue }
                jobIdentities.append(childSample.identity)
                busy = true
            }
            var children = [Int32](repeating: 0, count: 256)
            let childResult = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<Int32>.size))
            if childResult < 0 { incomplete = true }
            if childResult > 0 { busy = true }
        }
        let noJobs = jobTracker.observe(path: worktree.path, descendants: jobIdentities) {
            if let start = ProcessIdentityReader.startTimeMicroseconds(ofPID: $0.pid) { return start == $0.startTime }
            if kill($0.pid, 0) == -1 && errno == ESRCH { return false }
            return nil
        }
        guard !incomplete, !busy, noJobs, !SleepKeepAwakeRegistration.hasLiveRegistration(path: worktree.path) else { return nil }
        return result
    }

    private func publish() {
        guard let tm = terminalManager, let state = state?() else { return }
        tm.setSleepingWorktreePaths(Set(state.repos.flatMap(\.worktrees).map(\.path).filter { coordinator.isSleeping(path: $0) }))
    }
}

/// Recovery admission is fail-closed. A missing or incompatible bundled CLI,
/// failed journal write, or dead guardian prevents every subsequent SIGSTOP.
private final class SleepRecoveryGuardian {
    private let directory: URL
    private let journalURL: URL
    private let readyURL: URL
    private let owner: SleepProcessIdentity?
    private var process: Process?
    private var didStart = false
    private var pendingRecovery: [URL: WorktreeSleepJournal] = [:]
    private var recoveryLeases: [URL: WorktreeSleepRecoveryLease] = [:]

    init(directory: URL) {
        self.directory = directory
        let instance = UUID().uuidString
        journalURL = directory.appendingPathComponent(instance + ".json")
        readyURL = directory.appendingPathComponent(instance + ".ready")
        owner = SleepProcessReader.sample(pid: getpid())?.identity
    }

    var isReady: Bool {
        guard let process, process.isRunning, let data = try? Data(contentsOf: readyURL),
              let ready = try? JSONDecoder().decode(SleepGuardReadiness.self, from: data),
              ready.identity.pid == process.processIdentifier,
              let sample = SleepProcessReader.sample(pid: ready.identity.pid), !sample.isStopped,
              sample.identity == ready.identity else { return false }
        let age = ProcessInfo.processInfo.systemUptime - ready.uptime
        return age >= 0 && age <= 10
    }

    func save(_ records: [SuspendedSleepProcess]) -> Bool {
        guard let owner else { return false }
        do { try WorktreeSleepJournal(owner: owner, processes: records).save(to: journalURL); return true }
        catch { return false }
    }

    func start() {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.worktreeAutoSleep), !didStart else { return }
        didStart = true
        guard save([]) else { return }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/graftty")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = ["internal", "sleep-guard", "--journal", journalURL.path, "--ready", readyURL.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do { try helper.run(); process = helper } catch { process = nil }
    }

    func recoverPreviousInstances() {
        // Recover journals whose app and watchdog are both gone. A watchdog
        // still alive owns its journal and will finish recovery itself.
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            guard let stored = WorktreeSleepJournal.load(from: file), !stored.ownerIsAlive else { continue }
            if recoveryLeases[file] == nil {
                guard let lease = WorktreeSleepRecoveryLease(journal: file) else { continue }
                recoveryLeases[file] = lease
            }
            var journal: WorktreeSleepJournal
            if let pending = pendingRecovery[file] {
                // Completed resumes remain authoritative while this lease
                // is held, even if a later disk read is unavailable.
                guard pending.owner == stored.owner else { continue }
                journal = pending
            } else {
                // The helper could finish between the preliminary read and
                // lease acquisition. Reload before sending any signals.
                guard let current = WorktreeSleepJournal.load(from: file), !current.ownerIsAlive else {
                    recoveryLeases[file] = nil
                    continue
                }
                journal = current
            }
            journal.recover()
            pendingRecovery[file] = journal
            do {
                if journal.processes.isEmpty { try FileManager.default.removeItem(at: file) }
                else { try journal.save(to: file) }
                pendingRecovery[file] = nil
                recoveryLeases[file] = nil
            } catch { /* Retry persistence without signaling completed resumes again. */ }
        }
    }
}

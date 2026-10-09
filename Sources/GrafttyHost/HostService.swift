#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@MainActor
final class HostService {
    let configuration: HostConfiguration
    private let lease: HostProcessLease
    private let runtime: HeadlessHostRuntime
    private let socket: SocketServer
    private let ssh: DirectSSHHostServer
    private var admin: HostAdministrationServer?
    private var http: LANRemoteAccessServer?
    private let pairing: HostPairingServer
    private var peers: [RemoteDeviceID: TeamRPCSession] = [:]
    private var signalSources: [DispatchSourceSignal] = []
    private var pairingTicker: Task<Void, Never>?

    nonisolated static var cliPath: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("graftty").path
    }

    nonisolated static func identity(configuration: HostConfiguration) throws -> LinuxHostIdentity {
        let key = try HostIdentityStore(directory: configuration.identityDirectory).loadOrGenerateAndPersist()
        let id = try HostDeviceIDStore(directory: configuration.identityDirectory).loadOrGenerateAndPersist()
        return LinuxHostIdentity(deviceID: id.value, displayName: ProcessInfo.processInfo.hostName,
            publicKey: key.publicKey.rawRepresentation.base64EncodedString(), port: configuration.sshPort)
    }

    nonisolated static func trust(_ request: LinuxHostTrustRequest, publicKeyData: Data, configuration: HostConfiguration) throws {
        try request.validate()
        let key = try RemoteIdentityPublicKey(rawRepresentation: publicKeyData)
        let peer = TrustedPeer(id: RemoteDeviceID(value: request.deviceID), kind: .mac, publicKey: key,
            displayName: request.displayName, capabilities: .defaultsAfterPairing, pairedAt: Date(), lastSeenAt: nil)
        try TrustedPeerStore(directory: configuration.identityDirectory).upsertAfterPairing(peer)
    }

    init(configuration: HostConfiguration, enablePairing: Bool) throws {
        self.configuration = configuration
        lease = try HostProcessLease(configuration: configuration)
        try configuration.save()
        ZmxLauncher.sanitizeProcessEnvironment()
        _ = try AgentHookInstaller(rootDirectory: configuration.hooksDirectory, grafttyCLIPath: Self.cliPath).install()
        runtime = try HeadlessHostRuntime(configuration: configuration)
        let identity = try Self.identity(configuration: configuration)
        let id = RemoteDeviceID(value: identity.deviceID)
        runtime.origin = WorktreeOrigin(deviceID: id, deviceLabel: identity.displayName, relayDepth: 0)
        let identityStore = HostIdentityStore(directory: configuration.identityDirectory)
        let trusted = TrustedPeerStore(directory: configuration.identityDirectory)
        guard let kind = RemoteDeviceKind(rawValue: "linux") else { throw HostRuntimeError.invalid("Linux host identity is not supported by this protocol build") }
        let base = URL(string: "http://127.0.0.1:\(configuration.httpPort)")!
        pairing = HostPairingServer(session: HostPairingSession(identityStore: identityStore, peerStore: trusted,
            hostDeviceID: id, hostKind: kind, hostDisplayName: identity.displayName,
            pairingURLProvider: { base.appendingPathComponent("v2/pairing") }))
        let runtime = runtime
        let launcher = runtime.launcher
        let ownership = SessionDisplayOwnershipStore()
        let attachment = RemoteAttachmentRegistry()
        let subscribe: PanesStateChannelHandler.Subscribe = { onChange in
            let initial = await MainActor.run {
                PanesStateMessage.snapshot(runtime.snapshot(), sidebar: SidebarSnapshot(projects: runtime.state.repos.map {
                    SidebarProject(id: $0.path, repositoryID: $0.path, name: $0.displayName, owner: runtime.origin, supportsWorktreeEditing: true)
                }))
            }
            await onChange(initial)
            let task = Task {
                var last = initial
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    let next = await MainActor.run {
                        PanesStateMessage.snapshot(runtime.snapshot(), sidebar: SidebarSnapshot(projects: runtime.state.repos.map {
                            SidebarProject(id: $0.path, repositoryID: $0.path, name: $0.displayName, owner: runtime.origin, supportsWorktreeEditing: true)
                        }))
                    }
                    if next != last { last = next; await onChange(next) }
                }
            }
            return .init { task.cancel() }
        }
        ssh = DirectSSHHostServer(hostKey: try identityStore.loadOrGenerateAndPersist(), trustedPeerStore: trusted,
            streamFactory: { target in
                let config = try await runtime.sessionConfiguration(target)
                let engine = ZmxAttachEngine(config: .init(zmxExecutable: launcher.executable, zmxDir: launcher.zmxDir,
                    sessionName: target, workingDirectory: config.workingDirectory, spawnConfiguration: config))
                engine.attachmentRegistry = attachment
                try await Task.detached { try engine.start() }.value
                return engine
            }, pagedFactory: { target in
                let config = try await runtime.sessionConfiguration(target)
                let engine = PagedZmxAttachEngine(config: .init(zmxExecutable: launcher.executable, zmxDir: launcher.zmxDir,
                    sessionName: target, workingDirectory: config.workingDirectory, spawnConfiguration: config))
                engine.attachmentRegistry = attachment
                try await engine.start()
                return engine
            }, panesStateSubscribe: subscribe, panesStateV2Subscribe: subscribe,
            paneControlMutator: { await runtime.control($0) }, worktreeManagementMutator: { await runtime.manage($0) },
            displayOwnershipStore: ownership)
        socket = SocketServer(socketPath: configuration.socketPath)
        socket.onAsyncRequest = { await runtime.handle($0) }
        socket.onMessage = { message in
            // Request-style messages are dispatched once by onAsyncRequest.
            if !message.expectsResponse { Task { _ = await runtime.handle(message) } }
        }
        let pairing = pairing
        admin = HostAdministrationServer(configuration: configuration) { request in
            switch request {
            case .status:
                return await MainActor.run { .status(HostStatus(running: true, configuration: configuration,
                    repositoryCount: runtime.state.repos.count, paneCount: runtime.sessions().count)) }
            case .pairingStatus:
                if case .pendingConfirmation(_, _, _, let name, _, let code, _) = await pairing.currentState() {
                    return .pairing(displayName: name, code: code.display)
                }
                return .error("no client is awaiting confirmation")
            case .confirmPairing(let code):
                guard case .pendingConfirmation(_, _, _, _, _, let expected, _) = await pairing.currentState(),
                      code.replacingOccurrences(of: " ", with: "") == expected.digits else {
                    return .error("verification code does not match the pending client")
                }
                do { _ = try await pairing.confirm(); return .ok }
                catch { return .error(String(describing: error)) }
            case .cancelPairing: await pairing.cancel(); return .ok
            case .registerRepository(let path):
                do { return .repository(try await runtime.registerRepository(path)) }
                catch { return .error(String(describing: error)) }
            }
        }
        runtime.remoteTeamSender = { [weak self] message in
            guard let self, case .teamSend(let path, let agent, let recipient, let text, let priority) = message,
                  let address = RemoteTeamAddress(rawValue: recipient), let session = self.peers[address.deviceID] else {
                return .error("remote team connection is unavailable")
            }
            guard runtime.state.worktree(forPath: path) != nil else { return .error("caller is not registered") }
            do {
                let request = RemoteTeamRequest.send(senderWorktree: path, senderAgentID: agent,
                    recipientWorktree: address.worktreePath, recipientSuffix: address.suffix, text: text, priority: priority)
                let bytes = try await session.send(JSONEncoder().encode(request))
                let response = try JSONDecoder().decode(RemoteTeamResponse.self, from: bytes)
                if case .error(let error) = response { return .error(error) }
                return .ok
            } catch { return .error(String(describing: error)) }
        }
        if enablePairing {
            let pairing = pairing
            let routes = LANRemoteAccessRouteHandler(lanBaseURLProvider: { base },
                rateLimit: .init(maxRequests: 30, window: 60),
                beginPairing: { validFor, url in
                    let current = await pairing.currentState()
                    if case .pendingConfirmation = current { return .failure(.init(code: .pairingBusy, error: "client confirmation pending")) }
                    do { return .success(try await pairing.start(validFor: validFor, pairingURL: url)) }
                    catch { return .failure(.init(code: .internalError, error: String(describing: error))) }
                }, handleIntroduce: { await pairing.handleIntroduce($0) },
                handleAwaitOutcome: { await pairing.handleAwaitOutcome($0) },
                handleCancelPairing: { await pairing.handleCancel($0) },
                handleSignalingChallenge: { _ in .failure(.init(code: .unsupportedVersion, error: "Use the direct SSH listener")) },
                handleSignalingOffer: { _ in .unavailable("Use the direct SSH listener") })
            http = LANRemoteAccessServer(config: .init(port: configuration.httpPort, bindHost: configuration.bindAddress), routeHandler: routes)
        }
    }

    func run() async throws {
        do {
            try await runtime.restore()
            runtime.startTeamDelivery()
            runtime.startMaintenance()
            try socket.start()
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: configuration.socketPath)
            try admin?.start()
            try http?.start()
            _ = try await ssh.start(host: configuration.bindAddress, port: configuration.sshPort)
            await ssh.setTeamMessaging(handler: { [runtime] device, bytes in
                guard let request = try? JSONDecoder().decode(RemoteTeamRequest.self, from: bytes) else { return Data() }
                let response = await runtime.remoteTeam(request, deviceID: device)
                return (try? JSONEncoder().encode(response)) ?? Data()
            }, onConnect: { [weak self] device, session in await self?.connected(device, session: session) },
                onDisconnect: { [weak self] device, id in await self?.disconnected(device, id: id) })
            pairingTicker = Task { [pairing] in
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); await pairing.tick() }
            }
            await waitForTermination()
            await stop()
        } catch { await stop(); throw error }
    }

    private func connected(_ device: RemoteDeviceID, session: TeamRPCSession) { peers[device] = session }
    private func disconnected(_ device: RemoteDeviceID, id: UUID) { if peers[device]?.id == id { peers[device] = nil } }

    private func stop() async {
        for source in signalSources { source.cancel() }
        signalSources.removeAll()
        pairingTicker?.cancel(); pairingTicker = nil
        await pairing.cancel()
        await ssh.close()
        http?.stop(); admin?.stop(); socket.stop()
        try? runtime.shutdown()
        withExtendedLifetime(lease) {}
    }

    private func waitForTermination() async {
        await withCheckedContinuation { continuation in
            signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            var resumed = false
            for number in [SIGINT, SIGTERM] {
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler {
                    guard !resumed else { return }
                    resumed = true; continuation.resume()
                }
                signalSources.append(source); source.resume()
            }
        }
    }
}

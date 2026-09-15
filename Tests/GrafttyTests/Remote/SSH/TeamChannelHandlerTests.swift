import CryptoKit
import Foundation
import GrafttyRemoteClient
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing

struct TeamChannelHandlerTests {
    @Test("@spec TEAM-14.23: When a peer opens the team subsystem, the application shall admit the channel only when team messaging is configured and the authenticated peer is an allowed Mac.")
    func admission() async throws {
        for allowed in [false, true] {
            let box = TeamHostTestBox()
            let channel = NIOAsyncTestingChannel()
            let dispatcher = SubsystemDispatcher(
                streamFactory: { _ in throw TeamRPCSession.SessionError.channelClosed },
                panesStateSubscribe: { _ in .init(cancel: {}) },
                paneControlMutator: { _ in .ok },
                ownershipStore: SessionDisplayOwnershipStore(),
                ownershipBroadcaster: DisplayOwnershipBroadcaster(),
                deviceIDProvider: { RemoteDeviceID(value: "paired-mac") },
                teamHandler: { _, payload in payload },
                teamOnConnect: { _, session in await box.register(session) },
                teamAllowed: { allowed }
            )
            try await channel.pipeline.addHandler(dispatcher).get()
            try await channel.connect(to: .init(unixDomainSocketPath: "/tmp/team-channel-test")).get()
            channel.pipeline.fireUserInboundEventTriggered(SSHChannelRequestEvent.SubsystemRequest(subsystem: SSHChannelTypeNames.team, wantReply: false))
            if allowed {
                try await wait(channel) { await box.session != nil }
                #expect(channel.isActive)
            } else {
                try await wait(channel) { !channel.isActive }
                #expect(await box.session == nil)
            }
            _ = try? await channel.finish()
        }
    }

    @Test("@spec TEAM-14.24: When a paired Mac opens a team channel, the application shall expose that same channel for host-originated requests and remove its session after channel closure.")
    func hostCanSendAndReceive() async throws {
        let box = TeamHostTestBox()
        let channel = NIOAsyncTestingChannel()
        let device = RemoteDeviceID(value: "paired-mac")
        try await channel.connect(to: .init(unixDomainSocketPath: "/tmp/team-channel-test")).get()
        try await channel.pipeline.addHandler(TeamChannelHandler(
            deviceID: device,
            handler: { peer, bytes in
                #expect(peer == device)
                return Data("host:".utf8) + bytes
            },
            onConnect: { peer, session in
                #expect(peer == device)
                await box.register(session)
            },
            onDisconnect: { peer, id in
                #expect(peer == device)
                await box.unregister(id)
            }
        )).get()
        try await wait(channel) { await box.session != nil }
        let session = try #require(await box.session)
        let inbound = TeamRPCEnvelope(kind: .request, requestID: UUID(), payload: Data("hello".utf8))
        try await channel.writeInbound(ByteBuffer(bytes: JSONEncoder().encode(inbound)))
        let response = try await readEnvelope(channel)
        #expect(response.requestID == inbound.requestID)
        #expect(response.kind == .response)
        #expect(response.payload == Data("host:hello".utf8))

        let reverse = Task { try await session.send(Data("reverse".utf8)) }
        let request = try await readEnvelope(channel)
        #expect(request.kind == .request)
        #expect(request.payload == Data("reverse".utf8))
        let reply = TeamRPCEnvelope(kind: .response, requestID: request.requestID, payload: Data("client:reply".utf8))
        try await channel.writeInbound(ByteBuffer(bytes: JSONEncoder().encode(reply)))
        #expect(try await reverse.value == Data("client:reply".utf8))
        _ = try await channel.finish()
        try await wait(channel) { await box.disconnectedID != nil }
        #expect(await box.disconnectedID == session.id)
        await #expect(throws: TeamRPCSession.SessionError.channelClosed) { try await session.send(Data()) }
    }

    @Test("@spec TEAM-14.26: When a Mac opens an authenticated SSH team subsystem, the application shall exchange concurrent requests in both directions and notify both endpoints when the subsystem closes.", arguments: [false, true])
    func sshLoopback(hostCloses: Bool) async throws {
        let box = TeamHostTestBox()
        let clientChannel = NIOAsyncTestingChannel()
        let serverChannel = NIOAsyncTestingChannel()
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrustedPeerStore(directory: directory)
        let peer = SSHUserAuthTestSupport.makePeer(key: clientKey, kind: .mac)
        try store.add(peer)
        let serverHandler = SSHServerSetup.makeHandler(
            hostKey: serverKey,
            trustedPeerStore: store,
            allocator: serverChannel.allocator,
            inboundChildChannelInitializer: { child, _ in
                child.pipeline.addHandler(SubsystemDispatcher(
                    streamFactory: { _ in throw TeamRPCSession.SessionError.channelClosed },
                    panesStateSubscribe: { _ in .init(cancel: {}) },
                    paneControlMutator: { _ in .ok },
                    ownershipStore: SessionDisplayOwnershipStore(),
                    ownershipBroadcaster: DisplayOwnershipBroadcaster(),
                    deviceIDProvider: { peer.id },
                    teamHandler: { _, data in Data("server:".utf8) + data },
                    teamOnConnect: { _, session in await box.register(session) },
                    teamOnDisconnect: { _, id in await box.unregister(id) },
                    teamAllowed: { true }
                ))
            }
        )
        let clientHandler = SSHClientSetup.makeHandler(
            clientKey: clientKey,
            expectedHostFingerprint: RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: serverKey.publicKey.rawRepresentation)),
            allocator: clientChannel.allocator
        )
        let serverHandlerBox = TeamSSHHandlerBox(handler: serverHandler)
        let clientHandlerBox = TeamSSHHandlerBox(handler: clientHandler)
        try await serverChannel.testingEventLoop.executeInContext {
            try serverChannel.pipeline.syncOperations.addHandler(serverHandlerBox.handler)
        }
        try await clientChannel.testingEventLoop.executeInContext {
            try clientChannel.pipeline.syncOperations.addHandler(clientHandlerBox.handler)
        }
        try await serverChannel.connect(to: .init(unixDomainSocketPath: "/tmp/team-ssh-server")).get()
        try await clientChannel.connect(to: .init(unixDomainSocketPath: "/tmp/team-ssh-client")).get()
        let pump = Task {
            while !Task.isCancelled {
                await clientChannel.testingEventLoop.run()
                await serverChannel.testingEventLoop.run()
                while let bytes = try await clientChannel.readOutbound(as: IOData.self) {
                    try await serverChannel.writeInbound(bytes)
                }
                while let bytes = try await serverChannel.readOutbound(as: IOData.self) {
                    try await clientChannel.writeInbound(bytes)
                }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        defer { pump.cancel() }
        let client = TeamChannelClient(parentChannel: clientChannel, parentHandler: clientHandler,
            handler: { Data("client:".utf8) + $0 }, onClose: { await box.clientDidClose() })
        do {
            try await client.open()
            try await wait(serverChannel) { await box.session != nil }
            let reverseSession = try #require(await box.session)
            async let forward = client.send(Data("forward".utf8))
            async let reverse = reverseSession.send(Data("reverse".utf8))
            #expect(try await forward == Data("server:forward".utf8))
            #expect(try await reverse == Data("client:reverse".utf8))
            if hostCloses {
                await reverseSession.close()
            } else {
                client.close()
            }
            try await wait(serverChannel) { await box.bothClosed }
            #expect(await box.disconnectedID == reverseSession.id)
        } catch {
            client.close()
            _ = try? await clientChannel.finish()
            _ = try? await serverChannel.finish()
            throw error
        }
        _ = try? await clientChannel.finish()
        _ = try? await serverChannel.finish()
    }

    @Test("@spec TEAM-14.27: If a team channel receives a malformed envelope, then the application shall close its transport and remove the registered team session.")
    func malformedEnvelopeClosesTransport() async throws {
        let box = TeamHostTestBox()
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: .init(unixDomainSocketPath: "/tmp/team-channel-test")).get()
        try await channel.pipeline.addHandler(TeamChannelHandler(
            deviceID: .generate(), handler: { _, data in data },
            onConnect: { _, session in await box.register(session) },
            onDisconnect: { _, id in await box.unregister(id) }
        )).get()
        try await wait(channel) { await box.session != nil }
        try await channel.writeInbound(ByteBuffer(bytes: Data("invalid-json".utf8)))
        try await wait(channel) { await box.disconnectedID != nil }
        #expect(!channel.isActive)
        _ = try? await channel.finish()
    }

    @Test("@spec TEAM-14.28: When a host registers a team channel, the application shall defer incoming requests until registration completes while permitting replies to requests originated during registration.")
    func registrationPrecedesIncomingRequests() async throws {
        let box = TeamHostTestBox()
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: .init(unixDomainSocketPath: "/tmp/team-registration-test")).get()
        try await channel.pipeline.addHandler(TeamChannelHandler(
            deviceID: .generate(),
            handler: { _, _ in
                await box.recordIncomingRequest()
                return Data("handled".utf8)
            },
            onConnect: { _, session in
                _ = try? await session.send(Data("register".utf8))
                await box.register(session)
            },
            onDisconnect: { _, id in await box.unregister(id) }
        )).get()
        do {
            let registrationRequest = try await readEnvelope(channel)
            let incoming = TeamRPCEnvelope(kind: .request, requestID: UUID(), payload: Data("send".utf8))
            try await channel.writeInbound(ByteBuffer(bytes: JSONEncoder().encode(incoming)))
            for _ in 0..<10 {
                await channel.testingEventLoop.run()
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await box.incomingRequestCount == 0)
            let reply = TeamRPCEnvelope(kind: .response, requestID: registrationRequest.requestID, payload: Data())
            try await channel.writeInbound(ByteBuffer(bytes: JSONEncoder().encode(reply)))
            let response = try await readEnvelope(channel)
            #expect(response.requestID == incoming.requestID)
            #expect(await box.incomingRequestCount == 1)
            #expect(await box.requestHandledBeforeRegistration == false)
        } catch {
            _ = try? await channel.finish()
            throw error
        }
        _ = try await channel.finish()
    }

    private func readEnvelope(_ channel: NIOAsyncTestingChannel) async throws -> TeamRPCEnvelope {
        var bytes: ByteBuffer?
        try await wait(channel) {
            bytes = try await channel.readOutbound(as: ByteBuffer.self)
            return bytes != nil
        }
        return try JSONDecoder().decode(TeamRPCEnvelope.self, from: Data(try #require(bytes).readableBytesView))
    }

    private func wait(_ channel: NIOAsyncTestingChannel, condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            await channel.testingEventLoop.run()
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TeamRPCSession.SessionError.timedOut
    }
}

private actor TeamHostTestBox {
    var session: TeamRPCSession?
    var disconnectedID: UUID?
    var clientClosed = false
    var incomingRequestCount = 0
    var requestHandledBeforeRegistration = false
    var bothClosed: Bool { disconnectedID != nil && clientClosed }
    func clientDidClose() { clientClosed = true }
    func register(_ session: TeamRPCSession) { self.session = session }
    func unregister(_ id: UUID) { disconnectedID = id; session = nil }
    func recordIncomingRequest() {
        incomingRequestCount += 1
        requestHandledBeforeRegistration = session == nil
    }
}

private struct TeamSSHHandlerBox: @unchecked Sendable {
    let handler: NIOSSHHandler
}

#if os(macOS)
import Foundation
import GrafttyProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import GrafttyKit

private final class ChromeSmokePage: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        let html = """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:0;height:4000px}input{position:absolute;left:0;top:0;width:300px;height:60px}i{position:fixed;top:80px;animation:a .3s infinite alternate}@keyframes a{to{transform:translateX(80px)}}</style>
        <input id="field"><i>stream</i><script>window.keys=[];field.addEventListener('keydown',e=>keys.push(e.key));</script>
        """
        let body = context.channel.allocator.buffer(string: html)
        let headers = HTTPHeaders([("Content-Type", "text/html"), ("Content-Length", String(body.readableBytes))])
        context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

@Suite(.serialized)
struct DedicatedChromeBackendTests {
    @Test("@spec CHROME-1.8: If pane ownership changes while an OAuth dispatch receipt is persisted, then the application shall recheck ownership before Chrome navigation and release the unsent receipt for a later authorized retry.", .timeLimit(.minutes(1)))
    func nativeOfferRevokedBeforeDispatch() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("graftty-native-revoke-\(UUID())")
        let profile = root.appendingPathComponent(String(repeating: "c", count: 64))
        let backend = DedicatedChromeBackend(testProfile: profile)
        do {
            let before = try await backend.perform(.list, authorize: { true })
            let id = UUID(), original = "http://127.0.0.1:9/authorize?state=original"
            let storage = profile.appendingPathComponent("GrafttyOfferLaunches.json")
            await #expect(throws: (any Error).self) {
                try await backend.perform(.launchOffer(id: id, url: original), authorize: {
                    !FileManager.default.fileExists(atPath: storage.path)
                })
            }
            #expect(try ChromeOfferLaunchLedger(storageURL: storage).tab(for: id, url: original) == nil)
            let after = try await backend.perform(.list, authorize: { true })
            #expect(after.tabs.count == before.tabs.count)
            let retry = try await backend.perform(.launchOffer(id: id, url: original), authorize: { true })
            #expect(retry.tabs.count == before.tabs.count + 1)
            #expect(retry.selectedTabID != nil)
        } catch {
            await backend.shutdownForTesting(); try? FileManager.default.removeItem(at: root); throw error
        }
        await backend.shutdownForTesting()
        try FileManager.default.removeItem(at: root)
    }

    @Test("@spec CHROME-1.7: When a host Chrome OAuth launch succeeds but its viewer reply is lost, the application shall preserve the original state and callback URL and select the same host tab on reconnection without relaunching it.", .timeLimit(.minutes(1)))
    func nativeOfferLostReplyReconnect() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("graftty-native-offer-\(UUID())")
        let profile = root.appendingPathComponent(String(repeating: "b", count: 64))
        let backend = DedicatedChromeBackend(testProfile: profile)
        var rehydrated: DedicatedChromeBackend?
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap { channel.pipeline.addHandler(ChromeSmokePage()) }
        }.bind(host: "127.0.0.1", port: 0).get()
        do {
            let port = try #require(server.localAddress?.port)
            let original = "http://127.0.0.1:\(port)/authorize?state=A%2Bb&redirect_uri=http%3A%2F%2Flocalhost%3A4567%2Fcallback"
            let id = UUID(), viewer = UUID()
            let broker = ChromeTabBroker(authorize: { _, _ in "/test-worktree" }, makeBackend: { _ in backend })
            let request = ChromeTabRequest(target: "pane", action: .launchOffer(id: id, url: original))
            // The host completes, but the viewer never sees this response.
            let lost = await broker.handle(request, peerID: "trusted", viewerID: viewer)
            #expect(lost.error == nil)
            let tab = try #require(lost.state?.selectedTabID)
            #expect(try await backend.evaluateForTesting("location.href") == original)
            _ = await broker.handle(.init(target: "pane", action: .text(tabID: tab, text: "")), peerID: "trusted", viewerID: viewer)
            await broker.disconnect(viewerID: viewer)
            let retried = await broker.handle(request, peerID: "trusted", viewerID: UUID())
            #expect(retried.error == nil)
            #expect(retried.state?.selectedTabID == tab)
            #expect(retried.state?.tabs.count == lost.state?.tabs.count)
            #expect(try await backend.evaluateForTesting("location.href") == original)
            // Recreate the production backend as after a host app restart while Chrome survives.
            rehydrated = DedicatedChromeBackend(testProfile: profile)
            let freshBroker = ChromeTabBroker(authorize: { _, _ in "/test-worktree" }, makeBackend: { [newBackend = rehydrated!] _ in newBackend })
            let restored = await freshBroker.handle(request, peerID: "trusted", viewerID: UUID())
            #expect(restored.error == nil)
            #expect(restored.state?.selectedTabID == tab)
            #expect(restored.state?.tabs.count == lost.state?.tabs.count)

        } catch {
            await rehydrated?.shutdownForTesting()
            await backend.shutdownForTesting()
            try? await server.close().get(); try? await group.shutdownGracefully()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await rehydrated?.shutdownForTesting()
        await backend.shutdownForTesting()
        try await server.close().get(); try await group.shutdownGracefully()
        try FileManager.default.removeItem(at: root)
    }

    @Test("@spec CHROME-1.4: While an authorized phone controls a dedicated Chrome tab, the application shall stream bounded selected-tab screencast frames, dispatch tap, scroll, text and keyboard input on the host, and retain tab state across viewer reconnects.", .timeLimit(.minutes(1)))
    func nativeCDPVerticalSmoke() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("graftty-native-chrome-\(UUID())")
        let directory = root.appendingPathComponent(String(repeating: "a", count: 64))
        let backend = DedicatedChromeBackend(testProfile: directory)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap { channel.pipeline.addHandler(ChromeSmokePage()) }
        }.bind(host: "127.0.0.1", port: 0).get()
        let port = try #require(server.localAddress?.port)
        let broker = ChromeTabBroker(authorize: { _, peer in peer == "trusted" ? "/test-worktree" : nil }, makeBackend: { _ in backend })
        let viewer = UUID()
        var debugPort: Int?
        do {
            let launched = await broker.handle(.init(target: "pane", action: .launch(url: "http://127.0.0.1:\(port)")), peerID: "trusted", viewerID: viewer)
            #expect(launched.error == nil)
            let endpoint = try String(contentsOf: directory.appendingPathComponent("DevToolsActivePort"), encoding: .utf8)
            debugPort = endpoint.split(separator: "\n").first.flatMap { Int($0) }
            #expect(ChromeDebugPortRegistry.shared.contains(port: try #require(debugPort)))
            // Simulate registry initialization in a restarted host app.
            let restored = ChromeDebugPortRegistry(profileRoot: root)
            #expect(restored.contains(port: try #require(debugPort)))
            let tab = try #require(launched.state?.selectedTabID)
            var frame: ChromeTabFrame?
            for _ in 0..<30 {
                let response = await broker.handle(.init(target: "pane", action: .frame(tabID: tab)), peerID: "trusted", viewerID: viewer)
                frame = response.state?.frame
                if frame != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let jpeg = try #require(frame?.jpeg)
            #expect(jpeg.prefix(2) == Data([0xff, 0xd8]))
            #expect(jpeg.count <= ChromeTabFrame.maximumJPEGBytes)
            let initialSequence = try #require(frame?.sequence)
            let actions: [ChromeTabAction] = [.tap(tabID: tab, x: 0.1, y: 0.04), .text(tabID: tab, text: "Graftty phone input ✓"), .key(tabID: tab, key: .backspace), .key(tabID: tab, key: .enter), .scroll(tabID: tab, x: 0.5, y: 0.5, deltaX: 0, deltaY: 400)]
            for action in actions {
                let response = await broker.handle(.init(target: "pane", action: action), peerID: "trusted", viewerID: viewer)
                #expect(response.error == nil)
            }
            #expect(try await backend.evaluateForTesting("field.value") == "Graftty phone input ")
            #expect(try await backend.evaluateForTesting("keys.includes('Enter')") == "1")
            try await Task.sleep(for: .milliseconds(250))
            #expect(Int(try await backend.evaluateForTesting("window.scrollY")) ?? 0 > 0)
            let otherViewer = await broker.handle(.init(target: "pane", action: .list), peerID: "trusted", viewerID: UUID())
            #expect(otherViewer.error != nil)
            await broker.disconnect(viewerID: viewer)
            let secondViewer = UUID()
            let listed = await broker.handle(.init(target: "pane", action: .list), peerID: "trusted", viewerID: secondViewer)
            #expect(listed.state?.tabs.contains(where: { $0.id == tab }) == true)
            #expect(listed.state?.frame == nil)
            _ = await broker.handle(.init(target: "pane", action: .select(tabID: tab)), peerID: "trusted", viewerID: secondViewer)
            #expect(try await backend.evaluateForTesting("field.value") == "Graftty phone input ")
            for _ in 0..<30 {
                let response = await broker.handle(.init(target: "pane", action: .frame(tabID: tab)), peerID: "trusted", viewerID: secondViewer)
                frame = response.state?.frame
                if frame?.sequence ?? 0 > initialSequence { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(frame?.sequence ?? 0 > initialSequence)
            let stale = await broker.handle(.init(target: "pane", action: .text(tabID: "obsolete", text: "wrong")), peerID: "trusted", viewerID: secondViewer)
            #expect(stale.error != nil)
            await broker.disconnect(viewerID: secondViewer)
            #expect(ChromeDebugPortRegistry.shared.contains(port: try #require(debugPort)))
            await backend.shutdownForTesting()
            #expect(!ChromeDebugPortRegistry.shared.contains(port: try #require(debugPort)))
            #expect(!restored.contains(port: try #require(debugPort)))
            let restarted = await broker.handle(.init(target: "pane", action: .launch(url: "http://127.0.0.1:\(port)")), peerID: "trusted", viewerID: UUID())
            #expect(restarted.error == nil)
            let restartedEndpoint = try String(contentsOf: directory.appendingPathComponent("DevToolsActivePort"), encoding: .utf8)
            let restartedPort = try #require(restartedEndpoint.split(separator: "\n").first.flatMap { Int($0) })
            #expect(ChromeDebugPortRegistry.shared.contains(port: restartedPort))
            if restartedPort != debugPort { #expect(!ChromeDebugPortRegistry.shared.contains(port: try #require(debugPort))) }
            debugPort = restartedPort
        } catch {
            await backend.shutdownForTesting()
            try? await server.close().get(); try? await group.shutdownGracefully()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await backend.shutdownForTesting()
        #expect(!ChromeDebugPortRegistry.shared.contains(port: try #require(debugPort)))
        try await server.close().get(); try await group.shutdownGracefully()
        try FileManager.default.removeItem(at: root)
    }
}
#endif

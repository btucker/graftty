#if os(macOS)
import Foundation
import GrafttyProtocol
import ImageIO
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Testing
@testable import GrafttyKit

private enum CDPHistoryReply: Sendable {
    case normal, error(String), disconnect, stall
}

/// A local CDP peer controls frame order and transport failures independently of Chrome rendering.
private final class ViewportCDPPeer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    struct Snapshot: Sendable {
        var session: String?
        var metricsCount = 0
        var inputCount = 0
        var historyCount = 0
        var lastX: Double?
        var lastY: Double?
    }
    let historyReply: CDPHistoryReply
    let longURL: String?
    var channel: Channel?
    var snapshot = Snapshot()
    private var attachments = 0
    init(historyReply: CDPHistoryReply, longURL: String? = nil) { self.historyReply = historyReply; self.longURL = longURL }
    func handlerAdded(context: ChannelHandlerContext) { channel = context.channel }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        if frame.opcode == .connectionClose { context.close(promise: nil); return }
        guard frame.opcode == .text,
              let json = try? JSONSerialization.jsonObject(with: Data(frame.unmaskedData.readableBytesView)) as? [String: Any],
              let id = json["id"] as? Int, let method = json["method"] as? String else { return }
        var result: [String: Any] = [:]
        switch method {
        case "Target.getTargets":
            let targets = (0..<(longURL == nil ? 1 : 32)).map { index in
                ["type": "page", "targetId": index == 0 ? "tab" : "tab\(index)",
                 "title": String(repeating: "\"\\", count: 128), "url": longURL ?? "https://example.com/"]
            }
            result = ["targetInfos": targets]
        case "Target.attachToTarget":
            attachments += 1
            snapshot.session = "capture\(attachments)"
            result = ["sessionId": snapshot.session!]
        case "Emulation.setDeviceMetricsOverride": snapshot.metricsCount += 1
        case "Input.dispatchMouseEvent", "Input.insertText", "Input.dispatchKeyEvent":
            snapshot.inputCount += 1
            let params = json["params"] as? [String: Any]
            snapshot.lastX = params?["x"] as? Double
            snapshot.lastY = params?["y"] as? Double
        case "Page.getNavigationHistory":
            snapshot.historyCount += 1
            switch historyReply {
            case .normal: result = ["currentIndex": 0, "entries": [["id": 1]]]
            case .error(let message):
                write(["id": id, "error": ["message": message]], context: context); return
            case .disconnect: context.close(promise: nil); return
            case .stall: return
            }
        default: break
        }
        write(["id": id, "result": result], context: context)
    }

    private func write(_ json: [String: Any], context: ChannelHandlerContext) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: json) else { return }
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: buffer)), promise: nil)
    }

    func sendFrame(session: String, width: Int, height: Int, jpeg: Data) async throws {
        let channel = try #require(channel)
        let bytes = try JSONSerialization.data(withJSONObject: [
            "method": "Page.screencastFrame", "sessionId": session,
            "params": ["sessionId": 1, "data": jpeg.base64EncodedString(),
                       "metadata": ["deviceWidth": width, "deviceHeight": height, "pageScaleFactor": 1]]
        ])
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buffer)).get()
    }

    func readSnapshot() async throws -> Snapshot {
        guard let channel else { return Snapshot() }
        return try await channel.eventLoop.submit { self.snapshot }.get()
    }
}

private actor ViewportPermission {
    private var checks = 0
    func permits() -> Bool { checks += 1; return checks < 4 }
}

@Suite(.serialized)
struct DedicatedChromeViewportTests {
    @Test("@spec CHROME-1.13: If pane ownership changes during a resize or a viewport frame's capture session, CSS dimensions, or JPEG dimensions differ from the selected viewport, then the application shall discard stale frames and reject input until that viewport has a fresh authorized frame.")
    func rejectsStaleFramesAndInputAndRevokedResize() async throws {
        try await withCDPPeer(.normal) { backend, peer in
            let selected = try await backend.perform(.select(tabID: "tab"), authorize: { true })
            let oldSession = try #require(try await peer.readSnapshot().session)
            let oldJPEG = try viewportJPEG(width: 1024, height: 768)
            try await peer.sendFrame(session: oldSession, width: 1024, height: 768, jpeg: oldJPEG)
            let initial = try await backend.perform(.frame(tabID: "tab"), authorize: { true })
            #expect(initial.frame?.jpeg == oldJPEG)
            let resized = try await backend.perform(.viewport(tabID: "tab", width: 375, height: 812), authorize: { true })
            let newSession = try #require(try await peer.readSnapshot().session)
            #expect(newSession != oldSession)
            #expect(resized.viewportID != selected.viewportID)
            #expect(resized.frame == nil)
            try await peer.sendFrame(session: oldSession, width: 375, height: 812, jpeg: oldJPEG)
            try await peer.sendFrame(session: newSession, width: 1024, height: 768, jpeg: oldJPEG)
            try await peer.sendFrame(session: newSession, width: 375, height: 812, jpeg: oldJPEG)
            #expect(try await backend.perform(.frame(tabID: "tab"), authorize: { true }).frame == nil)
            for action in [ChromeTabAction.tap(tabID: "tab", x: 0.75, y: 0.75),
                           .scroll(tabID: "tab", x: 0.5, y: 0.5, deltaX: 0, deltaY: 100),
                           .text(tabID: "tab", text: "typed"), .key(tabID: "tab", key: .enter)] {
                await #expect(throws: (any Error).self) { try await backend.perform(action, authorize: { true }) }
            }
            #expect(try await peer.readSnapshot().inputCount == 0)
            let newJPEG = try viewportJPEG(width: 375, height: 812)
            try await peer.sendFrame(session: newSession, width: 375, height: 812, jpeg: newJPEG)
            let fresh = try await backend.perform(.frame(tabID: "tab"), authorize: { true })
            #expect(fresh.frame?.jpeg == newJPEG)
            #expect(fresh.frame?.viewportID == resized.viewportID)
            #expect(fresh.frame?.width == 375 && fresh.frame?.height == 812)
            _ = try await backend.perform(.tap(tabID: "tab", x: 0.75, y: 0.75), authorize: { true })
            let input = try await peer.readSnapshot()
            #expect(input.inputCount == 2)
            #expect(input.lastX == 281.25 && input.lastY == 609)

            let landscape = try await backend.perform(.viewport(tabID: "tab", width: 1024, height: 768), authorize: { true })
            try await peer.sendFrame(session: oldSession, width: 1024, height: 768, jpeg: oldJPEG)
            try await peer.sendFrame(session: newSession, width: 375, height: 812, jpeg: newJPEG)
            #expect(try await backend.perform(.frame(tabID: "tab"), authorize: { true }).frame == nil)
            #expect(landscape.viewportID != resized.viewportID)
            let permission = ViewportPermission()
            await #expect(throws: (any Error).self) {
                try await backend.perform(.viewport(tabID: "tab", width: 400, height: 800), authorize: { await permission.permits() })
            }
            #expect(try await peer.readSnapshot().metricsCount == 3)
            #expect(try await backend.perform(.list, authorize: { true }).frame == nil)
            await #expect(throws: (any Error).self) {
                try await backend.perform(.viewport(tabID: "unselected", width: 375, height: 812), authorize: { true })
            }
        }
    }

    @Test("@spec CHROME-1.14: If navigation availability fails because the CDP transport disconnects, times out, or reports an error other than a document-swap attachment gap on the same live session, then the application shall return the failure instead of stale navigation success.", .timeLimit(.minutes(1)))
    func surfacesNavigationHistoryTransportAndProtocolFailures() async throws {
        for reply in [CDPHistoryReply.disconnect, .stall, .error("Unexpected history failure")] {
            try await withCDPPeer(reply) { backend, _ in
                await #expect(throws: (any Error).self) {
                    try await backend.perform(.select(tabID: "tab"), authorize: { true })
                }
            }
        }
        try await withCDPPeer(.error("Not attached to an active page")) { backend, _ in
            let state = try await backend.perform(.select(tabID: "tab"), authorize: { true })
            #expect(state.selectedTabID == "tab")
            #expect(state.canGoBack == nil && state.canGoForward == nil)
        }
        try await withCDPPeer(.error("Not attached to an active page")) { backend, peer in
            await #expect(throws: (any Error).self) {
                try await backend.perform(.select(tabID: "tab"), authorize: {
                    if (try? await peer.readSnapshot().historyCount) ?? 0 > 0 { await backend.stopCapture() }
                    return true
                })
            }
        }
    }

    @Test("@spec CHROME-1.16: While a selected host tab exposes an exact navigable URL, the application shall bound other tab URLs to 2048 UTF8 bytes and flag shortened metadata so that JSON escaping and a maximum-size JPEG fit within the Chrome response limit.")
    func boundsUnselectedMetadataUnderWorstJSONEscaping() async throws {
        let url = "https://example.com/" + String(repeating: "\"\\", count: (8192 - 20) / 2)
        try await withCDPPeer(.normal, longURL: url) { backend, _ in
            let state = try await backend.perform(.select(tabID: "tab"), authorize: { true })
            #expect(state.tabs.count == 32)
            for tab in state.tabs {
                #expect(tab.url.utf8.count == (tab.id == "tab" ? 8192 : 2048))
                #expect(tab.urlTruncated == (tab.id != "tab"))
            }
            var response = state
            response.frame = ChromeTabFrame(tabID: "tab", jpeg: Data(repeating: 0xff, count: ChromeTabFrame.maximumJPEGBytes), sequence: 1, width: 375, height: 812, viewportID: 1)
            #expect(try ChromeTabResponse(state: response).encoded().count <= ChromeTabRequest.maximumResponseBytes)
        }
    }
}

private func viewportJPEG(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func withCDPPeer(_ history: CDPHistoryReply, longURL: String? = nil, body: @Sendable (DedicatedChromeBackend, ViewportCDPPeer) async throws -> Void) async throws {
    let root = URL.temporaryDirectory.appendingPathComponent("graftty-cdp-viewport-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let peer = ViewportCDPPeer(historyReply: history, longURL: longURL)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
        let upgrader = NIOWebSocketServerUpgrader(maxFrameSize: 2 * 1024 * 1024, shouldUpgrade: { channel, _ in
            channel.eventLoop.makeSucceededFuture(HTTPHeaders())
        }, upgradePipelineHandler: { channel, _ in channel.pipeline.addHandler(peer) })
        return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
    }.bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(server.localAddress?.port)
    try "\(port)\n/devtools/browser/fixture\n".write(to: root.appendingPathComponent("DevToolsActivePort"), atomically: true, encoding: .utf8)
    let backend = DedicatedChromeBackend(testProfile: root)
    do {
        try await body(backend, peer)
    } catch {
        await backend.shutdownForTesting()
        try? await server.close().get(); try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(at: root)
        throw error
    }
    await backend.shutdownForTesting()
    try await server.close().get(); try await group.shutdownGracefully()
    try FileManager.default.removeItem(at: root)
}
#endif

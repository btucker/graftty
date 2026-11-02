import Foundation
import Testing
import NIOCore
import NIOEmbedded
@testable import GrafttyKit

private final class LocalAPICompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Data, any Error>?
    var result: Result<Data, any Error>? { lock.withLock { stored } }
    func record(_ result: Result<Data, any Error>) { lock.withLock { stored = result } }
}

@Suite("@spec WEB-1.21: While a LocalAPI request is pending, the application shall bound sending to two seconds and receive inactivity to two seconds for status and whois or ninety seconds for certificates, refreshing the receive deadline as bytes arrive.")
struct TailscaleLocalAPITimeoutTests {
    @Test("@spec WEB-1.22: When a LocalAPI request write completes, the application shall start the endpoint receive deadline on its event loop before resuming the caller's task, so executor delays cannot shorten certificate provisioning time.")
    func successfulWriteStartsReceiveDeadlineWithoutTaskResumption() throws {
        let loop = EmbeddedEventLoop()
        let response = loop.makePromise(of: Data.self)
        let completion = LocalAPICompletion()
        response.futureResult.whenComplete { completion.record($0) }
        let channel = EmbeddedChannel(
            handler: LocalAPIResponseHandler(response: response, receiveTimeout: .seconds(90)),
            loop: loop
        )
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        // Complete the real write path without awaiting its future in a Task.
        _ = TailscaleLocalAPI.writeRequest("GET /cert HTTP/1.0\r\n\r\n", on: channel)
        _ = try channel.readOutbound(as: ByteBuffer.self)
        loop.advanceTime(by: .seconds(2))
        #expect(completion.result == nil, "completed write retained the send deadline")
        loop.advanceTime(by: .seconds(88))
        guard case .failure(let error) = completion.result else {
            Issue.record("certificate receive deadline did not expire")
            _ = try channel.finish(acceptAlreadyClosed: true)
            return
        }
        #expect(error as? TailscaleLocalAPI.Error == .malformedResponse)
        _ = try channel.finish(acceptAlreadyClosed: true)
    }

    @Test(arguments: [Int64(2), Int64(90)])
    func receiveDeadlineMatchesEndpointAndRefreshesOnBytes(seconds: Int64) throws {
        let loop = EmbeddedEventLoop()
        let response = loop.makePromise(of: Data.self)
        let completion = LocalAPICompletion()
        response.futureResult.whenComplete { completion.record($0) }
        let channel = EmbeddedChannel(
            handler: LocalAPIResponseHandler(response: response, receiveTimeout: .seconds(seconds)),
            loop: loop
        )
        channel.pipeline.fireChannelActive()
        channel.pipeline.fireUserInboundEventTriggered(LocalAPIRequestSent())
        loop.advanceTime(by: .seconds(seconds - 1))
        #expect(completion.result == nil)
        var bytes = channel.allocator.buffer(capacity: 0)
        bytes.writeString("HTTP/1.0 ")
        _ = try channel.writeInbound(bytes)
        loop.advanceTime(by: .seconds(seconds - 1))
        #expect(completion.result == nil)
        loop.advanceTime(by: .seconds(1))
        guard case .failure(let error) = completion.result else {
            Issue.record("inactivity deadline did not fail the request")
            _ = try channel.finish(acceptAlreadyClosed: true)
            return
        }
        #expect(error as? TailscaleLocalAPI.Error == .malformedResponse)
        _ = try channel.finish(acceptAlreadyClosed: true)
    }

    @Test func sendDeadlineStaysShortDuringCertificateMint() throws {
        let loop = EmbeddedEventLoop()
        let response = loop.makePromise(of: Data.self)
        let completion = LocalAPICompletion()
        response.futureResult.whenComplete { completion.record($0) }
        let channel = EmbeddedChannel(
            handler: LocalAPIResponseHandler(response: response, receiveTimeout: .seconds(90)),
            loop: loop
        )
        channel.pipeline.fireChannelActive()
        loop.advanceTime(by: .seconds(2))
        guard case .failure(let error) = completion.result else {
            Issue.record("certificate send used the long receive deadline")
            _ = try channel.finish(acceptAlreadyClosed: true)
            return
        }
        #expect(error as? TailscaleLocalAPI.Error == .socketUnreachable)
        _ = try channel.finish(acceptAlreadyClosed: true)
    }
}

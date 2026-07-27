import NIOCore
import NIOSSH

/// Translates between `SSHChannelData` (the raw type delivered by
/// `NIOSSHHandler` on child channels) and `ByteBuffer` (the type expected
/// by length-prefixed framing decoders and application-level handlers).
///
/// Install as the first handler on SSH session child channels that use
/// `LengthPrefixedFraming`, BEFORE the framing decoder/prepender.
///
/// Mirrors `DataToBufferCodec` from swift-nio-ssh's NIOSSHServer example.
final class SSHChannelDataCodec: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .channel = channelData.type,
              case .byteBuffer(let buf) = channelData.data
        else {
            // Non-channel data (e.g. extended data / stderr) — drop silently.
            return
        }
        context.fireChannelRead(wrapInboundOut(buf))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))), promise: promise)
    }
}

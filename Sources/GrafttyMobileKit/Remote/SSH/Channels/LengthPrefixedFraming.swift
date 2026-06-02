#if canImport(UIKit)
import NIOCore
import NIOExtras

/// Mobile-side mirror of `GrafttyHostAgent`'s `LengthPrefixedFraming`.
/// Same configuration (4-byte big-endian length field) so server and
/// client agree on wire format.
public enum LengthPrefixedFraming {
    public static func makeFrameDecoder() -> ByteToMessageHandler<LengthFieldBasedFrameDecoder> {
        ByteToMessageHandler(LengthFieldBasedFrameDecoder(lengthFieldLength: .four))
    }

    public static func makeFramePrepender() -> LengthFieldPrepender {
        LengthFieldPrepender(lengthFieldLength: .four)
    }
}
#endif

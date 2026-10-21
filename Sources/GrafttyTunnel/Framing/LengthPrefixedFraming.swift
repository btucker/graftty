import NIOCore
import NIOExtras

/// Length-prefixed framing helpers for graftty's custom SSH channels.
/// Each application message on `panes-state@graftty.dev` and
/// `pane-control@graftty.dev` is `<u32 BE length><JSON>` over the SSH
/// channel byte stream (parent design §8.2).
///
/// `NIOExtras` ships exactly the codecs we need; this file just names
/// the configured constructors so the host and the remote client agree
/// on the same field width (4 bytes, big-endian).
public enum LengthPrefixedFraming {
    /// Decode `<u32 BE length><payload>` into one `ByteBuffer` per
    /// payload. Add directly to the pipeline via `addHandler`.
    /// `maximumBufferSize` bounds buffered undecoded bytes (prefix
    /// included) for subsystems with a declared frame limit; `nil` is
    /// unbounded.
    public static func makeFrameDecoder(
        maximumBufferSize: Int? = nil
    ) -> ByteToMessageHandler<LengthFieldBasedFrameDecoder> {
        ByteToMessageHandler(
            LengthFieldBasedFrameDecoder(lengthFieldLength: .four),
            maximumBufferSize: maximumBufferSize
        )
    }

    /// Prepend `<u32 BE length>` to each outbound `ByteBuffer`. Add
    /// directly to the pipeline via `addHandler` —
    /// `LengthFieldPrepender` is a `ChannelOutboundHandler`, not a
    /// `MessageToByteEncoder`.
    public static func makeFramePrepender() -> LengthFieldPrepender {
        LengthFieldPrepender(lengthFieldLength: .four)
    }
}

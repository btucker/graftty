import Foundation

/// Encodes a `ChannelFrame` into the wire layout documented in the
/// M1.4 plan, and decodes it back. The encoder produces a single
/// `Data` blob sized to fit in one `RTCDataBuffer`.
public enum ChannelFrameCoder {

    public enum DecodeError: Error, Equatable, Sendable {
        case truncated
        case unknownType(UInt8)
        case malformedJSON(String)
        case payloadLengthMismatch
    }

    public static func encode(_ frame: ChannelFrame) throws -> Data {
        let typeByte: UInt8
        let metadataJSON: Data
        let payload: Data
        let encoder = JSONEncoder()
        switch frame {
        case .open(let m):
            typeByte = FrameType.open.rawValue
            metadataJSON = try encoder.encode(m)
            payload = Data()
        case .close(let m):
            typeByte = FrameType.close.rawValue
            metadataJSON = try encoder.encode(m)
            payload = Data()
        case .payload(let m, let bytes):
            typeByte = FrameType.payload.rawValue
            metadataJSON = try encoder.encode(m)
            payload = bytes
        case .error(let m):
            typeByte = FrameType.error.rawValue
            metadataJSON = try encoder.encode(m)
            payload = Data()
        }
        var out = Data()
        out.reserveCapacity(1 + 4 + metadataJSON.count + 4 + payload.count)
        out.append(typeByte)
        appendLittleEndianUInt32(UInt32(metadataJSON.count), to: &out)
        out.append(metadataJSON)
        appendLittleEndianUInt32(UInt32(payload.count), to: &out)
        out.append(payload)
        return out
    }

    public static func decode(_ data: Data) throws -> ChannelFrame {
        guard data.count >= 9 else { throw DecodeError.truncated }
        var cursor = data.startIndex
        let typeByte = data[cursor]
        cursor = data.index(after: cursor)
        guard let frameType = FrameType(rawValue: typeByte) else {
            throw DecodeError.unknownType(typeByte)
        }
        let metadataLength = try readLittleEndianUInt32(from: data, at: &cursor)
        guard cursor + Int(metadataLength) <= data.endIndex else {
            throw DecodeError.truncated
        }
        let metadataJSON = data[cursor..<(cursor + Int(metadataLength))]
        cursor = cursor + Int(metadataLength)
        let payloadLength = try readLittleEndianUInt32(from: data, at: &cursor)
        guard cursor + Int(payloadLength) <= data.endIndex else {
            throw DecodeError.payloadLengthMismatch
        }
        let payload = data[cursor..<(cursor + Int(payloadLength))]
        let decoder = JSONDecoder()
        switch frameType {
        case .open:
            let m = try decoder.decode(ChannelOpen.self, from: Data(metadataJSON))
            return .open(m)
        case .close:
            let m = try decoder.decode(ChannelClose.self, from: Data(metadataJSON))
            return .close(m)
        case .payload:
            let m = try decoder.decode(ChannelPayload.self, from: Data(metadataJSON))
            return .payload(m, Data(payload))
        case .error:
            let m = try decoder.decode(ChannelError.self, from: Data(metadataJSON))
            return .error(m)
        }
    }

    private static func appendLittleEndianUInt32(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func readLittleEndianUInt32(
        from data: Data,
        at cursor: inout Data.Index
    ) throws -> UInt32 {
        guard cursor + 4 <= data.endIndex else { throw DecodeError.truncated }
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { buf in
            for i in 0..<4 {
                buf[i] = data[cursor + i]
            }
        }
        cursor = cursor + 4
        return UInt32(littleEndian: value)
    }
}

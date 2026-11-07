import Foundation

/// Optional checkpoint/page encoding inside the existing length-prefixed control
/// carrier: magic + version, u32 metadata length, JSON metadata, raw payload.
/// Metadata uses the existing envelope with an empty Data field. Only the bulk
/// bytes change encoding; identities, validation and stream order stay shared.
public enum PagedTerminalBinary {
    public static let environmentName = "GRAFTTY_TERMINAL_PAGING_ENCODING"
    public static let encodingName = "binary-v1"
    private static let magic: [UInt8] = [0x89, 0x47, 0x50, 0x47]
    private static let version: UInt8 = 1
    private static let metadataLimit = 4096

    /// Version-independent detection lets callers reject an unsupported binary
    /// version instead of silently dropping it as malformed UTF-8 control text.
    public static func isBinary(_ data: Data) -> Bool { data.starts(with: magic) }

    public static func encode(_ event: PagedTerminalEvent) throws -> Data {
        try PagedTerminalEnvelope(event: event).validate()
        let bytes = try payload(of: event)
        let metadata = try JSONEncoder().encode(PagedTerminalEnvelope(event: replacingPayload(of: event, with: Data())))
        guard metadata.count <= metadataLimit else { throw PagedTerminalEnvelope.Error.tooLarge }
        let count = UInt32(metadata.count)
        var wire = Data(magic)
        wire.reserveCapacity(9 + metadata.count + bytes.count)
        wire.append(contentsOf: [version, UInt8(count >> 24), UInt8(truncatingIfNeeded: count >> 16),
                                UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)])
        wire.append(metadata)
        wire.append(bytes)
        return wire
    }

    public static func decode(_ wire: Data) throws -> PagedTerminalEvent {
        guard wire.count <= StdErrControlFraming.maxFrameLength else { throw PagedTerminalEnvelope.Error.tooLarge }
        let header = Array(wire.prefix(9))
        guard header.count == 9, header.starts(with: magic), header[4] == version else {
            throw PagedTerminalEnvelope.Error.invalid
        }
        let size = Int(UInt32(header[5]) << 24 | UInt32(header[6]) << 16 | UInt32(header[7]) << 8 | UInt32(header[8]))
        guard size > 0, size <= metadataLimit, size <= wire.count - 9 else {
            throw PagedTerminalEnvelope.Error.invalid
        }
        let metadata = try JSONDecoder().decode(PagedTerminalEnvelope.self, from: Data(wire.dropFirst(9).prefix(size)))
        guard metadata.terminalPaging == 1, metadata.request == nil, let event = metadata.event,
              try payload(of: event).isEmpty else { throw PagedTerminalEnvelope.Error.invalid }
        let decoded = try replacingPayload(of: event, with: Data(wire.dropFirst(9 + size)))
        try PagedTerminalEnvelope(event: decoded).validate()
        return decoded
    }

    private static func payload(of event: PagedTerminalEvent) throws -> Data {
        switch event {
        case .checkpoint(let checkpoint): return checkpoint.ready
        case .page(let page): return page.data
        default: throw PagedTerminalEnvelope.Error.invalid
        }
    }

    private static func replacingPayload(of event: PagedTerminalEvent, with data: Data) throws -> PagedTerminalEvent {
        switch event {
        case .checkpoint(let value):
            return .checkpoint(.init(incarnation: value.incarnation, id: value.id, codec: value.codec,
                cols: value.cols, rows: value.rows, ready: data,
                hasPrimaryHistory: value.hasPrimaryHistory, hasAlternateHistory: value.hasAlternateHistory))
        case .page(let value):
            return .page(.init(incarnation: value.incarnation, checkpointID: value.checkpointID,
                requestID: value.requestID, ordinal: value.ordinal, screen: value.screen, data: data, complete: value.complete))
        default: throw PagedTerminalEnvelope.Error.invalid
        }
    }
}

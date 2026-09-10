import Foundation

/// The codec is pinned independently of the SSH subsystem version.
public enum PagedTerminalLimits {
    public static let codec = "ghostty-8af6897c-paging-1"
    public static let readyBytes = 512 * 1024
    public static let pageBytes = 256 * 1024
}

public struct PagedTerminalCheckpoint: Codable, Equatable, Sendable {
    public let incarnation: UInt64
    public let id: UInt64
    public let codec: String
    public let cols: UInt16
    public let rows: UInt16
    public let ready: Data
    public let hasPrimaryHistory: Bool
    public let hasAlternateHistory: Bool

    public init(incarnation: UInt64, id: UInt64, codec: String = PagedTerminalLimits.codec,
                cols: UInt16, rows: UInt16, ready: Data,
                hasPrimaryHistory: Bool, hasAlternateHistory: Bool) {
        self.incarnation = incarnation
        self.id = id
        self.codec = codec
        self.cols = cols
        self.rows = rows
        self.ready = ready
        self.hasPrimaryHistory = hasPrimaryHistory
        self.hasAlternateHistory = hasAlternateHistory
    }
}

public struct PagedTerminalHistoryRequest: Codable, Equatable, Sendable {
    public let incarnation: UInt64
    public let checkpointID: UInt64
    public let requestID: UInt64
    public let ordinal: UInt64
    public let screen: UInt16

    public init(incarnation: UInt64, checkpointID: UInt64, requestID: UInt64,
                ordinal: UInt64, screen: UInt16) {
        self.incarnation = incarnation
        self.checkpointID = checkpointID
        self.requestID = requestID
        self.ordinal = ordinal
        self.screen = screen
    }
}

public struct PagedTerminalPage: Codable, Equatable, Sendable {
    public let incarnation: UInt64
    public let checkpointID: UInt64
    public let requestID: UInt64
    public let ordinal: UInt64
    public let screen: UInt16
    public let data: Data
    public let complete: Bool

    public init(incarnation: UInt64, checkpointID: UInt64, requestID: UInt64,
                ordinal: UInt64, screen: UInt16, data: Data, complete: Bool) {
        self.incarnation = incarnation
        self.checkpointID = checkpointID
        self.requestID = requestID
        self.ordinal = ordinal
        self.screen = screen
        self.data = data
        self.complete = complete
    }

    public var request: PagedTerminalHistoryRequest {
        .init(incarnation: incarnation, checkpointID: checkpointID, requestID: requestID,
              ordinal: ordinal, screen: screen)
    }
}

public struct PagedTerminalHistoryFailure: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case expired, incompatible, limit, unavailable
    }
    public let request: PagedTerminalHistoryRequest
    public let reason: Reason

    public init(request: PagedTerminalHistoryRequest, reason: Reason) {
        self.request = request
        self.reason = reason
    }
}

public enum PagedTerminalEvent: Codable, Equatable, Sendable {
    case checkpoint(PagedTerminalCheckpoint)
    case grid(cols: UInt16, rows: UInt16)
    case output(Data)
    case page(PagedTerminalPage)
    case unavailable(PagedTerminalHistoryFailure)
    case ended(Int32)
}

public enum PagedTerminalRequest: Codable, Equatable, Sendable {
    case history(PagedTerminalHistoryRequest)
    case checkpoint
}

/// Paging uses the authenticated terminal channel's existing control framing.
/// Ordinary VT output stays on the binary carrier; it is never JSON encoded.
public struct PagedTerminalEnvelope: Codable, Equatable, Sendable {
    public let terminalPaging: Int
    public let event: PagedTerminalEvent?
    public let request: PagedTerminalRequest?

    public init(event: PagedTerminalEvent) {
        terminalPaging = 1
        self.event = event
        request = nil
    }

    public init(request: PagedTerminalRequest) {
        terminalPaging = 1
        event = nil
        self.request = request
    }

    public func encoded() throws -> String {
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= StdErrControlFraming.maxFrameLength else { throw Error.tooLarge }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= StdErrControlFraming.maxFrameLength else { throw Error.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard value.terminalPaging == 1, (value.event == nil) != (value.request == nil) else {
            throw Error.invalid
        }
        switch value.event {
        case .grid(let cols, let rows):
            guard cols > 0, rows > 0,
                  cols <= WebControlEnvelope.maxGridDimension,
                  rows <= WebControlEnvelope.maxGridDimension else { throw Error.invalid }
        case .checkpoint(let checkpoint):
            guard checkpoint.codec == PagedTerminalLimits.codec,
                  checkpoint.incarnation != 0, checkpoint.id != 0,
                  checkpoint.cols > 0, checkpoint.rows > 0,
                  checkpoint.cols <= WebControlEnvelope.maxGridDimension,
                  checkpoint.rows <= WebControlEnvelope.maxGridDimension,
                  !checkpoint.ready.isEmpty,
                  checkpoint.ready.count <= PagedTerminalLimits.readyBytes else { throw Error.invalid }
        case .page(let page):
            guard valid(page.request), page.data.count <= PagedTerminalLimits.pageBytes,
                  page.complete || !page.data.isEmpty else { throw Error.invalid }
        case .unavailable(let failure):
            guard valid(failure.request) else { throw Error.invalid }
        case .output, .ended:
            throw Error.invalid
        case nil:
            break
        }
        if case .history(let request) = value.request, !valid(request) { throw Error.invalid }
        return value
    }

    private static func valid(_ request: PagedTerminalHistoryRequest) -> Bool {
        request.incarnation != 0 && request.checkpointID != 0 && request.requestID != 0 && request.screen < 2
    }

    public enum Error: Swift.Error { case invalid, tooLarge }
}

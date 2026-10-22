import Foundation

extension JSONEncoder {
    /// Encoder with Foundation's default configuration, shared so per-frame
    /// wire paths don't allocate one each time. Encoding is thread-safe;
    /// never change its configuration.
    public static let shared = JSONEncoder()

    /// Encoder preconfigured with the iso8601 date strategy that every
    /// Graftty wire shape uses for `Date` fields.
    public static func iso8601() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    /// Decoder with Foundation's default configuration, shared so per-frame
    /// wire paths don't allocate one each time. Decoding is thread-safe;
    /// never change its configuration.
    public static let shared = JSONDecoder()

    /// Decoder preconfigured with the iso8601 date strategy that every
    /// Graftty wire shape uses for `Date` fields.
    public static func iso8601() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

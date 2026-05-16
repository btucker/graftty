import Foundation

extension JSONEncoder {
    /// Encoder preconfigured with the iso8601 date strategy that every
    /// Graftty wire shape uses for `Date` fields.
    public static func iso8601() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    /// Decoder preconfigured with the iso8601 date strategy that every
    /// Graftty wire shape uses for `Date` fields.
    public static func iso8601() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

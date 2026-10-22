import Foundation
import GrafttyProtocol
import Testing

struct JSONCodersTests {
    private struct Sample: Codable, Equatable {
        let createdAt: Date
        let snake_case: String
        let camelCase: Data
    }

    private let sample = Sample(
        createdAt: Date(timeIntervalSince1970: 1_234_567.25),
        snake_case: "x",
        camelCase: Data([0, 1, 2])
    )

    // Channel code swapped per-frame `JSONEncoder()` / `JSONDecoder()` for the
    // shared coders; the wire bytes must not change.
    @Test func sharedCodersMatchFoundationDefaults() throws {
        let shared = try JSONEncoder.shared.encode(sample)
        #expect(shared == (try JSONEncoder().encode(sample)))
        #expect(try JSONDecoder.shared.decode(Sample.self, from: shared) == sample)
        #expect(try JSONDecoder().decode(Sample.self, from: shared) == sample)
    }
}

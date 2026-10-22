import Foundation
import Testing

/// JSON captured from released encoders under `Fixtures/`, shared by the
/// wire-compatibility suites.
enum WireFixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}

import Foundation

/// A `readData` double for file-backed stores: the first `failures` reads
/// throw a permission error, and every later read returns the file's bytes.
public func readDataFailingFirst(_ failures: Int) -> @Sendable (URL) throws -> Data {
    let remaining = MutableBox(failures)
    return { url in
        let fails = remaining.withValue { (count: inout Int) -> Bool in
            defer { count = max(0, count - 1) }
            return count > 0
        }
        if fails { throw CocoaError(.fileReadNoPermission) }
        return try Data(contentsOf: url)
    }
}

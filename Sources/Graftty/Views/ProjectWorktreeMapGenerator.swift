import Foundation

enum ProjectWorktreeMapGenerator {
    @MainActor
    static func generate(_ input: WorktreeMapGeneration) async throws -> Data {
        try WorktreeSVGMap.generate(input)
    }
}

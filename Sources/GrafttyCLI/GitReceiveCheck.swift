import ArgumentParser
import Foundation
import GrafttyKit

struct GitReceiveCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "git-receive-check",
        abstract: "Validate a Git pre-receive transaction using parent-owned authenticated context")
    @Option(help: "Parent-created local receive context file") var context: String
    func run() async throws {
        guard context.hasPrefix("/") else { throw GitReceiveHookError.invalidContext }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: context))
        defer { try? handle.close() }
        let data = try GitReceiveHook.readBounded(handle, maximumBytes: GitReceiveHook.maximumContextBytes)
        let context = try JSONDecoder().decode(GitReceiveHookContext.self, from: data)
        guard CanonicalPath.canonicalize(FileManager.default.currentDirectoryPath) == CanonicalPath.canonicalize(context.repositoryPath) else {
            throw GitReceiveHookError.wrongRepository
        }
        let updates = try GitReceiveHook.readBounded(.standardInput, maximumBytes: GitReceiveHook.maximumInputBytes)
        try await GitReceiveHook.validate(updates, context: context)
    }
}

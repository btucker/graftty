import ArgumentParser
import Foundation

@main
struct EspalierCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "espalier",
        abstract: "Espalier terminal multiplexer CLI"
    )

    func run() throws {
        print("espalier CLI")
    }
}

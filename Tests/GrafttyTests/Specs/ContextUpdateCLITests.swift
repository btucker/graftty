import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCLI

struct ContextUpdateCLITests {
    @Test("@spec CONTEXT-72: When the context update command receives sparse JSON, the CLI shall validate changed groups without requiring repeated identity fields and reject unknown top-level fields and unsafe drawings.")
    func sparseValidation() throws {
        let recap = try ContextUpdate.decodeUpdate(Data(#"{"now":{"summary":"Tests passed."}}"#.utf8))
        #expect(recap.isValid)
        #expect(recap.contextUpdate?.now?.summary == "Tests passed.")
        #expect(recap.emoji == nil)
        #expect(try ContextUpdate.decodeUpdate(Data(#"{"unchanged":true}"#.utf8)).isValid)
        for json in [#"{}"#, #"{"now":{"summary":"Done."},"typo":true}"#,
                     #"{"unchanged":true,"attention":{"kind":"ask","question":"Ship?"}}"#,
                     #"{"icon":"<svg viewBox='0 0 96 64'><script>x()</script></svg>"}"#] {
            #expect(throws: (any Error).self) { try ContextUpdate.decodeUpdate(Data(json.utf8)) }
        }
    }
}

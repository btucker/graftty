import XCTest
@testable import GrafttyKit

final class MCPStdioServerTests: XCTestCase {
    func testInitializeRequestProducesCapabilitiesAndInstructions() throws {
        var out = Data()
        let server = MCPStdioServer(
            name: "graftty-channel",
            version: "0.1.0",
            instructions: "hello",
            output: { out.append($0) }
        )

        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}"#
        server.handleLine(request)

        let response = String(data: out, encoding: .utf8) ?? ""
        XCTAssertTrue(response.contains("\"jsonrpc\":\"2.0\""))
        XCTAssertTrue(response.contains("\"id\":1"))
        XCTAssertTrue(response.contains("\"claude/channel\""))
        XCTAssertTrue(response.contains("\"graftty-channel\""))
        XCTAssertTrue(response.contains("\"hello\""))
    }

    func testNotificationEmitsSingleLineJSONRPC() throws {
        var out = Data()
        let server = MCPStdioServer(
            name: "n", version: "0", instructions: "",
            output: { out.append($0) }
        )

        server.emitChannelNotification(
            content: "PR #1 merged",
            meta: ["type": "pr_state_changed", "pr_number": "1"]
        )

        let response = String(data: out, encoding: .utf8) ?? ""
        let lines = response.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(response.contains("\"method\":\"notifications/claude/channel\""))
        XCTAssertTrue(response.contains("\"content\":\"PR #1 merged\""))
        XCTAssertTrue(response.contains("\"pr_number\":\"1\""))
    }

    func testUnknownMethodReturnsJSONRPCError() throws {
        var out = Data()
        let server = MCPStdioServer(
            name: "n", version: "0", instructions: "",
            output: { out.append($0) }
        )

        server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"bogus","params":{}}"#)

        let response = String(data: out, encoding: .utf8) ?? ""
        XCTAssertTrue(response.contains("\"error\""))
        XCTAssertTrue(response.contains("\"id\":2"))
        XCTAssertTrue(response.contains("-32601"))
    }

    func testMalformedJSONProducesNoOutput() throws {
        var out = Data()
        let server = MCPStdioServer(
            name: "n", version: "0", instructions: "",
            output: { out.append($0) }
        )
        server.handleLine("not json")
        XCTAssertTrue(out.isEmpty, "expected no output for malformed input, got \(String(data: out, encoding: .utf8) ?? "")")
    }

    func testNotificationsInitializedIsNoOp() throws {
        var out = Data()
        let server = MCPStdioServer(
            name: "n", version: "0", instructions: "",
            output: { out.append($0) }
        )
        server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#)
        XCTAssertTrue(out.isEmpty)
    }

    func testEmptyLineIsNoOp() throws {
        var out = Data()
        let server = MCPStdioServer(
            name: "n", version: "0", instructions: "",
            output: { out.append($0) }
        )
        server.handleLine("")
        server.handleLine("   \n")
        XCTAssertTrue(out.isEmpty)
    }
}

// Tests/GrafttyKitTests/Ports/LsofOutputParserTests.swift
import Testing
@testable import GrafttyKit

@Suite("LsofOutputParser")
struct LsofOutputParserTests {
    @Test("Parses a single IPv4 loopback row")
    func parsesIPv4Loopback() {
        let raw = """
        COMMAND   PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node    12345 alice   23u  IPv4 0x12345678   0t0   TCP 127.0.0.1:3000 (LISTEN)
        """
        let rows = LsofOutputParser.parse(raw)
        #expect(rows.count == 1)
        #expect(rows[0].pid == 12345)
        #expect(rows[0].port == 3000)
        #expect(rows[0].address == "127.0.0.1")
        #expect(rows[0].processName == "node")
    }

    @Test("Parses IPv6 wildcard")
    func parsesIPv6Wildcard() {
        let raw = """
        COMMAND   PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node    12345 alice   23u  IPv6 0x12345678   0t0   TCP *:3000 (LISTEN)
        """
        let rows = LsofOutputParser.parse(raw)
        #expect(rows.count == 1)
        #expect(rows[0].address == "*")
        #expect(rows[0].port == 3000)
    }

    @Test("Parses bracketed IPv6 literal")
    func parsesBracketedIPv6() {
        let raw = """
        COMMAND   PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node    12345 alice   23u  IPv6 0x12345678   0t0   TCP [::1]:8080 (LISTEN)
        """
        let rows = LsofOutputParser.parse(raw)
        #expect(rows.count == 1)
        #expect(rows[0].address == "::1")
        #expect(rows[0].port == 8080)
    }

    @Test("Skips header and ignores blank lines")
    func skipsHeader() {
        let raw = """
        COMMAND   PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME

        node    12345 alice   23u  IPv4 0x12345678   0t0   TCP 127.0.0.1:3000 (LISTEN)
        """
        let rows = LsofOutputParser.parse(raw)
        #expect(rows.count == 1)
    }

    @Test("Empty input returns empty array")
    func emptyInput() {
        #expect(LsofOutputParser.parse("").isEmpty)
        #expect(LsofOutputParser.parse("COMMAND   PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME").isEmpty)
    }

    @Test("Process names without spaces are preserved")
    func processNameCommonCase() {
        let raw = """
        COMMAND   PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        Python   42 alice   3u   IPv4 0x12345678   0t0   TCP *:8000 (LISTEN)
        """
        let rows = LsofOutputParser.parse(raw)
        #expect(rows.count == 1)
        #expect(rows[0].processName == "Python")
    }
}

import Testing
@testable import Graftty

@Suite("LANAddress Tests")
struct LANAddressTests {

    @Test("select prefers an en* interface over other usable interfaces regardless of order")
    func prefersEnInterfaces() {
        let picked = LANAddress.select(from: [
            (name: "bridge100", address: "10.211.55.2"),
            (name: "en0", address: "192.168.1.20"),
        ])
        #expect(picked == "192.168.1.20")
    }

    @Test("select skips loopback, utun*, and awdl* interfaces")
    func skipsVirtualAndLoopbackInterfaces() {
        let picked = LANAddress.select(from: [
            (name: "lo0", address: "127.0.0.1"),
            (name: "utun3", address: "100.64.0.1"),
            (name: "awdl0", address: "10.0.0.5"),
            (name: "en1", address: "192.168.4.7"),
        ])
        #expect(picked == "192.168.4.7")
    }

    @Test("select skips link-local 169.254.* addresses even on en* interfaces")
    func skipsLinkLocalAddresses() {
        let picked = LANAddress.select(from: [
            (name: "en0", address: "169.254.10.20"),
            (name: "en1", address: "192.168.4.7"),
        ])
        #expect(picked == "192.168.4.7")
    }

    @Test("select falls back to a usable non-en interface when no en* interface qualifies")
    func fallsBackToNonEnInterfaces() {
        let picked = LANAddress.select(from: [
            (name: "lo0", address: "127.0.0.1"),
            (name: "bridge100", address: "10.211.55.2"),
        ])
        #expect(picked == "10.211.55.2")
    }

    @Test("select returns nil when every candidate is filtered out")
    func returnsNilWhenNothingUsable() {
        #expect(LANAddress.select(from: []) == nil)
        let picked = LANAddress.select(from: [
            (name: "lo0", address: "127.0.0.1"),
            (name: "utun0", address: "100.64.0.1"),
            (name: "en0", address: "169.254.1.1"),
        ])
        #expect(picked == nil)
    }
}

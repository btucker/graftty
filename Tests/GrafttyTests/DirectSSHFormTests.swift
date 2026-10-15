import GrafttyKit
import Testing
@testable import Graftty

struct DirectSSHFormTests {
    @Test("@spec REMOTE-20.6: When direct SSH is selected during pairing, the application shall save a separately validated Graftty host and port instead of the pairing or OpenSSH port.")
    func directEndpointUsesGrafttyPort() throws {
        var form = AddRemoteMacFormController()
        #expect(form.transport == .webRTC)
        form.updateManualURL("http://linux.example:8800")
        form.transport = .directSSH
        #expect(try form.directEndpoint() == DirectSSHEndpoint(host: "linux.example", port: 8801))
        form.directHostString = "other.example"
        form.directPortString = "9001"
        #expect(try form.directEndpoint() == DirectSSHEndpoint(host: "other.example", port: 9001))
        form.directPortString = "22oops"
        #expect(throws: DirectSSHEndpoint.ValidationError.self) { try form.directEndpoint() }
    }
}

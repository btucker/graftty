import Foundation
import Testing

struct WSLHostSetupTests {
    @Test("@spec REMOTE-32.14: When preparing a WSL2 host, the application shall report effective CPU and memory limits and propose resource settings with explicit Windows memory headroom while preserving unrelated existing WSL configuration.", .enabled(if: wslHasPowerShell, "PowerShell configuration checks also run in Windows CI"))
    func resourceConfiguration() throws {
        try run(["pwsh", "-NoProfile", "-NonInteractive", "-File", "scripts/windows/test-wsl-setup.ps1"])
    }

    @Test("@spec REMOTE-32.17: When enabling Windows sign-in startup for a WSL2 host, the installer shall scope the startup task to the current interactive user without elevation and retain a foreground Linux process without requiring an open terminal window.", .enabled(if: wslHasPowerShell, "PowerShell startup checks also run in Windows CI"))
    func startupConfiguration() throws {
        try run(["pwsh", "-NoProfile", "-NonInteractive", "-File", "scripts/windows/test-wsl-setup.ps1", "-StartupOnly"])
    }

    @Test("@spec REMOTE-32.16: When locally installing a WSL2 host, the application shall verify the supplied archive digest, reject unsafe archive entries, and reuse the Linux installer with loopback listeners without reporting remote readiness before enrollment and connection.")
    func verifiedLocalInstallation() throws {
        try run(["python3", "scripts/windows/test-wsl-install.py"])
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

private var wslHasPowerShell: Bool {
    (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains {
        FileManager.default.isExecutableFile(atPath: "\($0)/pwsh")
    }
}

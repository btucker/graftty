import Foundation
import Testing
@testable import GrafttyKit

#if os(macOS)
struct CodexBrowserLauncherTests {
    @Test("@spec PORTS-5.42: When a wrapper-managed browser-hook Codex TUI offers an authorization URL, the application shall send the unchanged URL and pane session through Graftty open while its app-server continues to run the original native Codex binary.")
    func fullWrapperKeepsBackendAndRoutesBrowserOffer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-browser-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let hooks = root.appendingPathComponent("hooks")
        let realBin = root.appendingPathComponent("real-bin")
        let managed = hooks.appendingPathComponent("codex-browser/codex")
        for directory in [realBin, managed.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func executable(_ text: String, at path: URL) throws {
            try text.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        let native = realBin.appendingPathComponent("codex")
        try executable("""
        #!/bin/sh
        if [ "$1" = --version ]; then printf 'codex-cli 0.162.1\\n'; exit 0; fi
        if [ "$1" = --enable ]; then shift 2; fi
        if [ "$1" != app-server ]; then exit 91; fi
        exec /usr/bin/python3 -c 'import os,signal,socket,sys; open(os.environ["FIXTURE_BACKEND"], "w").write("original-native"); s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); signal.pause()' "${3#unix://}"
        """, at: native)
        try executable("""
        #!/bin/sh
        if [ "$1" = --version ]; then printf 'codex-cli 0.162.1\\n'; exit 0; fi
        printf '%s\\n' "$@" > "$FIXTURE_TUI_ARGS"
        exec "$CODEX_BROWSER_COMMAND" "$FIXTURE_URL"
        """, at: managed)
        let cli = root.appendingPathComponent("graftty cli's")
        try executable("""
        #!/bin/sh
        if [ "$1" = team ] && [ "$2" = codex-app-server ] && [ "$3" = resolve-binary ]; then
          printf '%s\\n' "$FIXTURE_NATIVE"
        elif [ "$1" = open ]; then
          printf '%s\\n' "$#" "$1" "$2" "$ZMX_SESSION" > "$FIXTURE_OFFER"
        fi
        """, at: cli)
        _ = try AgentHookInstaller(rootDirectory: hooks, grafttyCLIPath: cli.path).install()
        let process = Process()
        process.executableURL = hooks.appendingPathComponent("bin/codex")
        process.arguments = ["resume", "thread-fixture"]
        let offer = root.appendingPathComponent("offer")
        let backend = root.appendingPathComponent("backend")
        let arguments = root.appendingPathComponent("tui-args")
        let url = "https://example.com/oauth?state=a'b&literal=$(printf oops)"
        process.environment = [
            "PATH": "\(hooks.appendingPathComponent("bin").path):\(realBin.path):/usr/bin:/bin",
            "GRAFTTY_SOCK": "/fixture.sock", "ZMX_SESSION": "graftty-fixture-pane",
            "FIXTURE_NATIVE": native.path, "FIXTURE_URL": url,
            "FIXTURE_OFFER": offer.path, "FIXTURE_BACKEND": backend.path,
            "FIXTURE_TUI_ARGS": arguments.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: backend, encoding: .utf8) == "original-native")
        #expect(try String(contentsOf: offer, encoding: .utf8) == "2\nopen\n\(url)\ngraftty-fixture-pane\n")
        let tuiArguments = try String(contentsOf: arguments, encoding: .utf8).split(separator: "\n").map(String.init)
        try #require(tuiArguments.count == 6)
        #expect(tuiArguments.prefix(3) == ["--enable", "hooks", "--remote"])
        #expect(tuiArguments[3].hasPrefix("unix://"))
        #expect(tuiArguments.suffix(2) == ["resume", "thread-fixture"])
    }

    @Test("@spec PORTS-5.41: When a Mac pane launches a wrapper-managed Codex TUI and an installed browser-hook TUI matches its native Codex version, the application shall route TUI browser URLs through the pane's Graftty helper, retain the original app-server binary, and use the original TUI outside a pane or after a version mismatch.")
    func selectsMatchingTUIOnlyInsidePane() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-browser-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("codex-browser/codex")
        try FileManager.default.createDirectory(at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
        let native = root.appendingPathComponent("native codex's")
        let original = root.appendingPathComponent("original tui")
        let cli = root.appendingPathComponent("graftty cli's")
        for (file, label, version) in [(native, "native", "0.162.1"), (original, "original", "0.162.1"), (managed, "managed", "0.162.1")] {
            try "#!/bin/sh\nif [ \"$1\" = --version ]; then printf 'codex-cli \(version)\\n'; exit 0; fi\nprintf '\(label)\\n%s\\n' \"${CODEX_BROWSER_COMMAND:-}\"\nprintf '%s\\n' \"$@\"\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        _ = try AgentHookInstaller(rootDirectory: root, grafttyCLIPath: cli.path).install()
        let launcher = root.appendingPathComponent("bin/codex-browser-tui")
        try #require(FileManager.default.isExecutableFile(atPath: launcher.path))
        let helper = root.appendingPathComponent("bin/browser-offer")
        try #require(FileManager.default.isExecutableFile(atPath: helper.path))
        let url = "https://example.com/oauth?state=a'b&literal=$(printf oops)"
        func run(pane: Bool, expected: String) throws {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = launcher
            process.arguments = [native.path, original.path, "--remote", "unix:///fixture.sock", url]
            process.environment = ["PATH": "/usr/bin:/bin", "CODEX_BROWSER_COMMAND": "/unrelated/inherited-helper"]
            if pane {
                process.environment?["GRAFTTY_SOCK"] = "/fixture.sock"
                process.environment?["ZMX_SESSION"] = "graftty-pane"
            }
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let expectedHelper = expected == "managed" ? helper.path : "/unrelated/inherited-helper"
            #expect(output == "\(expected)\n\(expectedHelper)\n--remote\nunix:///fixture.sock\n\(url)\n")
            #expect(process.terminationStatus == 0)
        }
        try run(pane: true, expected: "managed")
        try run(pane: false, expected: "original")
        try "#!/bin/sh\nprintf 'codex-cli 0.999.0\\n'\n".write(to: managed, atomically: true, encoding: .utf8)
        try run(pane: true, expected: "original")
        try FileManager.default.removeItem(at: managed)
        try run(pane: true, expected: "original")
    }
}
#endif

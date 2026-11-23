import Darwin
import Foundation
import os
import Testing
@testable import Graftty

@MainActor
@Suite("""
@spec LAYOUT-5.4: When Graftty starts on macOS without Full Disk Access, \
the application shall check Full Disk Access off the main actor and present \
a window-attached sheet prompting the user to grant it in System Settings \
(`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`), \
firing at most once per process, skipping when Full Disk Access is granted \
or indeterminate, and remaining permanently suppressible via a "Don't Ask Again" \
choice persisted in UserDefaults.
""", .serialized)
struct FullDiskAccessPromptTests {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "FullDiskAccessPromptTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    init() {
        FullDiskAccessPromptPresenter.resetForTests()
    }

    @Test func defaultProbePathsIncludeTCCDatabasesAndTimeMachine() {
        let home = URL(fileURLWithPath: "/Users/example")
        let paths = FullDiskAccess.defaultProbePaths(homeDirectory: home)
        #expect(paths == [
            "/Users/example/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Preferences/com.apple.TimeMachine.plist",
        ])
    }

    @Test func probeReturnsGrantedWhenAnyCandidatePathOpens() {
        var visited: [String] = []
        let status = FullDiskAccess.checkStatus(
            probePaths: ["/missing/TCC.db", "/system/TCC.db", "/extra/plist"],
            openFile: { path in
                visited.append(path)
                if path == "/missing/TCC.db" { return .failed(ENOENT) }
                return .opened
            }
        )
        #expect(status == .granted)
        #expect(visited == ["/missing/TCC.db", "/system/TCC.db"])
    }

    @Test func probeReturnsDeniedWhenExistingPathsDenyPermission() {
        let epermStatus = FullDiskAccess.checkStatus(
            probePaths: ["/missing/TCC.db", "/system/TCC.db"],
            openFile: { path in
                path == "/missing/TCC.db" ? .failed(ENOENT) : .failed(EPERM)
            }
        )
        #expect(epermStatus == .denied)

        let eaccesStatus = FullDiskAccess.checkStatus(
            probePaths: ["/system/TCC.db"],
            openFile: { _ in .failed(EACCES) }
        )
        #expect(eaccesStatus == .denied)
    }

    @Test func probeReturnsUnknownWhenNoCandidatePathExists() {
        let status = FullDiskAccess.checkStatus(
            probePaths: ["/missing/one", "/missing/two"],
            openFile: { _ in .failed(ENOENT) }
        )
        #expect(status == .unknown)
    }

    @Test func policyOnlyPromptsWhenDeniedAndNotSuppressed() {
        #expect(FullDiskAccessPromptPolicy.shouldPrompt(status: .denied, isSuppressed: false))
        #expect(!FullDiskAccessPromptPolicy.shouldPrompt(status: .denied, isSuppressed: true))
        #expect(!FullDiskAccessPromptPolicy.shouldPrompt(status: .granted, isSuppressed: false))
        #expect(!FullDiskAccessPromptPolicy.shouldPrompt(status: .unknown, isSuppressed: false))
    }

    @Test func primaryOpensSystemSettingsWithoutSuppressingAndFiresOncePerProcess() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let probeCount = OSAllocatedUnfairLock(initialState: 0)
        var presentedConfigs: [SheetAlert.Configuration] = []
        var openedURLs: [URL] = []

        await FullDiskAccessPromptPresenter.presentWhenWindowIsReady(
            defaults: defaults,
            checkStatus: {
                probeCount.withLock { $0 += 1 }
                return .denied
            },
            presentOnReadyWindow: { config, completion in
                presentedConfigs.append(config)
                completion(.primary)
                return true
            },
            openURL: { url in
                openedURLs.append(url)
            },
            retryDelay: .zero
        )

        #expect(probeCount.withLock { $0 } == 1)
        #expect(presentedConfigs.count == 1)
        #expect(presentedConfigs[0].primaryButton == "Open System Settings")
        #expect(presentedConfigs[0].secondaryButton == "Not Now")
        #expect(presentedConfigs[0].tertiaryButton == "Don't Ask Again")
        #expect(openedURLs == [FullDiskAccess.settingsURL])
        #expect(
            FullDiskAccess.settingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
        #expect(!FullDiskAccessPromptPolicy.isSuppressed(in: defaults))

        // Second call in the same process is a no-op.
        await FullDiskAccessPromptPresenter.presentWhenWindowIsReady(
            defaults: defaults,
            checkStatus: {
                probeCount.withLock { $0 += 1 }
                return .denied
            },
            presentOnReadyWindow: { config, _ in
                presentedConfigs.append(config)
                return true
            },
            openURL: { openedURLs.append($0) },
            retryDelay: .zero
        )
        #expect(probeCount.withLock { $0 } == 1)
        #expect(presentedConfigs.count == 1)
    }

    @Test func notNowDismissesWithoutSuppressingOrOpeningSettings() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var openedURLs: [URL] = []
        var presented = false

        await FullDiskAccessPromptPresenter.presentWhenWindowIsReady(
            defaults: defaults,
            checkStatus: { .denied },
            presentOnReadyWindow: { _, completion in
                presented = true
                completion(.secondary)
                return true
            },
            openURL: { openedURLs.append($0) },
            retryDelay: .zero
        )

        #expect(presented)
        #expect(openedURLs.isEmpty)
        #expect(!FullDiskAccessPromptPolicy.isSuppressed(in: defaults))
    }

    @Test func dontAskAgainPersistsSuppressionAcrossLaunches() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var openedURLs: [URL] = []

        await FullDiskAccessPromptPresenter.presentWhenWindowIsReady(
            defaults: defaults,
            checkStatus: { .denied },
            presentOnReadyWindow: { _, completion in
                completion(.tertiary)
                return true
            },
            openURL: { openedURLs.append($0) },
            retryDelay: .zero
        )

        #expect(openedURLs.isEmpty)
        #expect(FullDiskAccessPromptPolicy.isSuppressed(in: defaults))

        // Simulate next app launch: suppressed launches skip probing and prompting.
        FullDiskAccessPromptPresenter.resetForTests()
        let probedNextLaunch = OSAllocatedUnfairLock(initialState: false)
        var presentedNextLaunch = false
        await FullDiskAccessPromptPresenter.presentWhenWindowIsReady(
            defaults: defaults,
            checkStatus: {
                probedNextLaunch.withLock { $0 = true }
                return .denied
            },
            presentOnReadyWindow: { _, _ in
                presentedNextLaunch = true
                return true
            },
            openURL: { openedURLs.append($0) },
            retryDelay: .zero
        )

        #expect(!probedNextLaunch.withLock { $0 })
        #expect(!presentedNextLaunch)
    }

    @Test func skipsWhenGrantedOrUnknown() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        for status in [FullDiskAccessStatus.granted, .unknown] {
            FullDiskAccessPromptPresenter.resetForTests()
            var presented = false
            await FullDiskAccessPromptPresenter.presentWhenWindowIsReady(
                defaults: defaults,
                checkStatus: { status },
                presentOnReadyWindow: { _, _ in
                    presented = true
                    return true
                },
                openURL: { _ in },
                retryDelay: .zero
            )
            #expect(!presented)
        }
    }

    @Test func retriesUntilWindowIsReady() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var attempts = 0
        await FullDiskAccessPromptPresenter.presentWhenWindowIsReady(
            defaults: defaults,
            checkStatus: { .denied },
            presentOnReadyWindow: { _, completion in
                attempts += 1
                guard attempts >= 3 else { return false }
                completion(.secondary)
                return true
            },
            openURL: { _ in },
            retryDelay: .zero
        )
        #expect(attempts == 3)
    }
}

import AppKit
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

    @Test func probeReturnsDeniedImmediatelyOnEPERMWithoutFallingBack() {
        var visited: [String] = []
        let status = FullDiskAccess.checkStatus(
            probePaths: ["/missing/TCC.db", "/system/TCC.db", "/fallback/TimeMachine.plist"],
            openFile: { path in
                visited.append(path)
                switch path {
                case "/missing/TCC.db": return .failed(ENOENT)
                case "/system/TCC.db": return .failed(EPERM)
                default: return .opened
                }
            }
        )
        #expect(status == .denied)
        #expect(visited == ["/missing/TCC.db", "/system/TCC.db"])
    }

    @Test func probeTreatsPosixEACCESAsInconclusiveAndContinues() {
        let grantedViaFallback = FullDiskAccess.checkStatus(
            probePaths: ["/restricted/TCC.db", "/readable/TCC.db"],
            openFile: { path in
                path == "/restricted/TCC.db" ? .failed(EACCES) : .opened
            }
        )
        #expect(grantedViaFallback == .granted)

        let onlyEACCES = FullDiskAccess.checkStatus(
            probePaths: ["/restricted/TCC.db"],
            openFile: { _ in .failed(EACCES) }
        )
        #expect(onlyEACCES == .unknown)
    }

    @Test func probeReturnsUnknownWhenNoCandidatePathExistsOrListIsEmpty() {
        let missing = FullDiskAccess.checkStatus(
            probePaths: ["/missing/one", "/missing/two"],
            openFile: { _ in .failed(ENOENT) }
        )
        #expect(missing == .unknown)

        let empty = FullDiskAccess.checkStatus(probePaths: [], openFile: { _ in .opened })
        #expect(empty == .unknown)
    }

    @Test func defaultOpenFileReportsOpenedMissingAndPermissionFailure() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullDiskAccessProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let readable = dir.appendingPathComponent("readable.txt")
        try Data("ok".utf8).write(to: readable)
        #expect(FullDiskAccess.defaultOpenFile(readable.path) == .opened)

        let missing = dir.appendingPathComponent("missing.txt")
        #expect(FullDiskAccess.defaultOpenFile(missing.path) == .failed(ENOENT))

        if geteuid() != 0 {
            let unreadable = dir.appendingPathComponent("unreadable.txt")
            try Data("locked".utf8).write(to: unreadable)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
            #expect(FullDiskAccess.defaultOpenFile(unreadable.path) == .failed(EACCES))
        }
    }

    @Test func policyOnlyPromptsWhenDeniedAndNotSuppressed() {
        #expect(FullDiskAccessPromptPolicy.shouldPrompt(status: .denied, isSuppressed: false))
        #expect(!FullDiskAccessPromptPolicy.shouldPrompt(status: .denied, isSuppressed: true))
        #expect(!FullDiskAccessPromptPolicy.shouldPrompt(status: .granted, isSuppressed: false))
        #expect(!FullDiskAccessPromptPolicy.shouldPrompt(status: .unknown, isSuppressed: false))
    }

    @Test func primaryProbesOffMainOpensSystemSettingsWithoutSuppressingAndFiresOncePerProcess() async {
        defer { FullDiskAccessPromptPresenter.resetForTests() }
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let probeCount = OSAllocatedUnfairLock(initialState: 0)
        let ranOnMain = OSAllocatedUnfairLock(initialState: true)
        var presentedConfigs: [SheetAlert.Configuration] = []
        var openedURLs: [URL] = []

        await FullDiskAccessPromptPresenter.presentWhenWindowIsReady(
            defaults: defaults,
            checkStatus: {
                probeCount.withLock { $0 += 1 }
                ranOnMain.withLock { $0 = Thread.isMainThread }
                return .denied
            },
            presentSheet: { config in
                presentedConfigs.append(config)
                return .primary
            },
            openURL: { url in
                openedURLs.append(url)
            }
        )

        #expect(probeCount.withLock { $0 } == 1)
        #expect(!ranOnMain.withLock { $0 })
        #expect(presentedConfigs.count == 1)
        #expect(presentedConfigs[0].primaryButton == "Open System Settings")
        #expect(presentedConfigs[0].secondaryButton == "Not Now")
        #expect(presentedConfigs[0].tertiaryButton == "Don't Ask Again")
        #expect(presentedConfigs[0].escapeButton == .secondary)
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
            presentSheet: { config in
                presentedConfigs.append(config)
                return .primary
            },
            openURL: { openedURLs.append($0) }
        )
        #expect(probeCount.withLock { $0 } == 1)
        #expect(presentedConfigs.count == 1)
    }

    @Test func notNowAndCancelledDismissWithoutSuppressingOrOpeningSettings() async {
        defer { FullDiskAccessPromptPresenter.resetForTests() }
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        for response in [SheetAlert.Response.secondary, .cancelled] {
            FullDiskAccessPromptPresenter.resetForTests()
            var openedURLs: [URL] = []
            var presented = false

            await FullDiskAccessPromptPresenter.presentWhenWindowIsReady(
                defaults: defaults,
                checkStatus: { .denied },
                presentSheet: { _ in
                    presented = true
                    return response
                },
                openURL: { openedURLs.append($0) }
            )

            #expect(presented)
            #expect(openedURLs.isEmpty)
            #expect(!FullDiskAccessPromptPolicy.isSuppressed(in: defaults))
        }
    }

    @Test func dontAskAgainPersistsSuppressionAcrossLaunches() async {
        defer { FullDiskAccessPromptPresenter.resetForTests() }
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var openedURLs: [URL] = []

        await FullDiskAccessPromptPresenter.presentWhenWindowIsReady(
            defaults: defaults,
            checkStatus: { .denied },
            presentSheet: { _ in .tertiary },
            openURL: { openedURLs.append($0) }
        )

        #expect(openedURLs.isEmpty)
        #expect(defaults.bool(forKey: SettingsKeys.suppressFullDiskAccessPrompt))
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
            presentSheet: { _ in
                presentedNextLaunch = true
                return .primary
            },
            openURL: { openedURLs.append($0) }
        )

        #expect(!probedNextLaunch.withLock { $0 })
        #expect(!presentedNextLaunch)
    }

    @Test func skipsWhenGrantedOrUnknown() async {
        defer { FullDiskAccessPromptPresenter.resetForTests() }
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        for status in [FullDiskAccessStatus.granted, .unknown] {
            FullDiskAccessPromptPresenter.resetForTests()
            var presented = false
            await FullDiskAccessPromptPresenter.presentWhenWindowIsReady(
                defaults: defaults,
                checkStatus: { status },
                presentSheet: { _ in
                    presented = true
                    return .primary
                },
                openURL: { _ in }
            )
            #expect(!presented)
        }
    }

    @Test func sheetAlertResponseMappingAndButtonHelpers() {
        #expect(SheetAlert.response(for: .alertFirstButtonReturn) == .primary)
        #expect(SheetAlert.response(for: .alertSecondButtonReturn) == .secondary)
        #expect(SheetAlert.response(for: .alertThirdButtonReturn) == .tertiary)
        #expect(SheetAlert.response(for: .abort) == .cancelled)
        #expect(SheetAlert.response(for: .cancel) == .cancelled)
        #expect(SheetAlert.response(for: .stop) == .cancelled)

        let config = FullDiskAccessPromptPresenter.alertConfiguration
        #expect(SheetAlert.buttonTitles(for: config) == [
            "Open System Settings",
            "Not Now",
            "Don't Ask Again",
        ])
        #expect(SheetAlert.escapeButtonIndex(for: config) == 1)
    }

    @Test func sheetAlertSelectReadyHostWindowEnforcesVisibilitySheetAndModalGuards() {
        let main = SheetAlert.HostWindowCandidate(
            index: 0, isVisible: true, isPanel: false, isSheet: false,
            isChildWindow: false, canBecomeMain: true, isNormalLevel: true
        )
        let panel = SheetAlert.HostWindowCandidate(
            index: 1, isVisible: true, isPanel: true, isSheet: false,
            isChildWindow: false, canBecomeMain: true, isNormalLevel: true
        )
        let sheet = SheetAlert.HostWindowCandidate(
            index: 2, isVisible: true, isPanel: false, isSheet: true,
            isChildWindow: false, canBecomeMain: true, isNormalLevel: true
        )
        let child = SheetAlert.HostWindowCandidate(
            index: 3, isVisible: true, isPanel: false, isSheet: false,
            isChildWindow: true, canBecomeMain: true, isNormalLevel: true
        )
        let hidden = SheetAlert.HostWindowCandidate(
            index: 4, isVisible: false, isPanel: false, isSheet: false,
            isChildWindow: false, canBecomeMain: true, isNormalLevel: true
        )

        #expect(SheetAlert.selectReadyHostWindow(
            hasModalWindow: true,
            anyWindowHasAttachedSheet: false,
            mainWindow: main,
            keyWindow: main,
            windows: [main]
        ) == nil)

        #expect(SheetAlert.selectReadyHostWindow(
            hasModalWindow: false,
            anyWindowHasAttachedSheet: true,
            mainWindow: main,
            keyWindow: main,
            windows: [main]
        ) == nil)

        #expect(SheetAlert.selectReadyHostWindow(
            hasModalWindow: false,
            anyWindowHasAttachedSheet: false,
            mainWindow: nil,
            keyWindow: panel,
            windows: [panel, sheet, child, hidden, main]
        ) == 0)
    }

    @Test func awaitReadyHostWindowReturnsNilWhenCancelledBeforeWindowAppears() async {
        let center = NotificationCenter()
        let task = Task { @MainActor in
            await SheetAlert.awaitReadyHostWindow(
                initialGraceDelay: .seconds(60),
                center: center,
                readyWindow: { nil }
            )
        }
        await Task.yield()
        task.cancel()
        let result = await task.value
        #expect(result == nil)
    }
}

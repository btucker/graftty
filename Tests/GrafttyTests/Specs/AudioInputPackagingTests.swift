import Foundation
import Testing

@Suite("@spec DIST-1.5: When a terminal child requests microphone access, the packaged macOS application shall declare why it uses the microphone and carry the audio-input entitlement so macOS can authorize the request for Graftty.")
struct AudioInputPackagingTests {
    @Test("Info.plist explains microphone use")
    func infoPlistExplainsMicrophoneUse() throws {
        let infoPlist = try Self.bundleInfoPlist()
        let usageDescription = try #require(
            infoPlist["NSMicrophoneUsageDescription"] as? String
        )
        #expect(!usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("codesigning grants audio input")
    func codesigningGrantsAudioInput() throws {
        let entitlements = try Self.propertyList(
            at: Self.repositoryRoot
                .appendingPathComponent("scripts")
                .appendingPathComponent("entitlements")
                .appendingPathComponent("Graftty.entitlements")
        )
        #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)

        let script = try Self.bundleScript()
        #expect(script.contains(
            #"ENTITLEMENTS_FILE="$SCRIPT_DIR/entitlements/Graftty.entitlements""#
        ))
        #expect(script.contains(
            #"codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS_FILE" "$APP""#
        ))
    }

    @Test("bundle verifies the final embedded audio-input entitlement")
    func bundleVerifiesEmbeddedAudioInputEntitlement() throws {
        let script = try Self.bundleScript()
        let finalAppSigning = try #require(script.range(of:
            #"codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS_FILE" "$APP""#
        ))
        let entitlementProbe = try #require(script.range(of:
            #"codesign --display --entitlements "$EMBEDDED_ENTITLEMENTS_FILE" --xml "$APP/Contents/MacOS/Graftty""#
        ))

        #expect(finalAppSigning.upperBound < entitlementProbe.lowerBound)
        #expect(script[entitlementProbe.lowerBound...].contains(
            "Print :com.apple.security.device.audio-input"
        ))
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func bundleInfoPlist() throws -> [String: Any] {
        let script = try bundleScript()
        let heredocStart = "cat > \"$APP/Contents/Info.plist\" <<PLIST\n"
        let plistStart = try #require(script.range(of: heredocStart)?.upperBound)
        let plistEnd = try #require(
            script.range(of: "\nPLIST", range: plistStart..<script.endIndex)?.lowerBound
        )
        let plistData = try #require(
            String(script[plistStart..<plistEnd]).data(using: .utf8)
        )
        return try propertyList(from: plistData)
    }

    private static func bundleScript() throws -> String {
        let scriptURL = repositoryRoot
            .appendingPathComponent("scripts")
            .appendingPathComponent("bundle.sh")
        return try String(contentsOf: scriptURL, encoding: .utf8)
    }

    private static func propertyList(at url: URL) throws -> [String: Any] {
        try propertyList(from: Data(contentsOf: url))
    }

    private static func propertyList(from data: Data) throws -> [String: Any] {
        try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
    }
}

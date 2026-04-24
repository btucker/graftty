#if canImport(UIKit)
import Foundation

public enum SSHOnboardingInstructions {
    public static func downloadedFile(filename: String = "graftty-mobile.pub") -> String {
        """
        mkdir -p ~/.ssh
        chmod 700 ~/.ssh
        cat ~/Downloads/\(filename) >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        """
    }

    public static func manualPaste(publicKey: String) -> String {
        """
        mkdir -p ~/.ssh
        chmod 700 ~/.ssh
        echo '\(shellSingleQuoted(publicKey))' >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        """
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}
#endif

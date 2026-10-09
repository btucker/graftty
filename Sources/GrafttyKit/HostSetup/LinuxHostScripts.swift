import Foundation

struct LinuxHostRepositorySnapshot: Sendable {
    let branch: String
    let commit: String
    let origin: String?
    let importKey: String
}

/// Scripts run by system OpenSSH. User-controlled values enter only as quoted
/// shell words. Paths use the authenticated user's permissions, never sudo.
enum LinuxHostScripts {
    static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let detect = """
    set -eu
    for tool in git tar systemctl mktemp sha256sum; do
      command -v "$tool" >/dev/null 2>&1 || { echo "GRAFTTY_MISSING:$tool" >&2; exit 70; }
    done
    systemctl --user show-environment >/dev/null 2>&1 || { echo 'GRAFTTY_MISSING:systemd-user-session' >&2; exit 70; }
    . /etc/os-release
    printf '%s\\n' "$ID" "${VERSION_ID:-unknown}" "$(uname -m)" "$HOME"
    """

    static func install(staging: String, archiveURL: URL?) -> String {
        let download: String
        if let archiveURL {
            download = """
            command -v curl >/dev/null 2>&1 || { echo 'GRAFTTY_MISSING:curl' >&2; exit 70; }
            curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 --output archive.tar.gz \(quote(archiveURL.absoluteString))
            curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 60 --output archive.sha256 \(quote(archiveURL.absoluteString + ".sha256"))
            expected=$(awk 'NR == 1 {print $1}' archive.sha256)
            test "${#expected}" = 64 || { echo 'Invalid release checksum' >&2; exit 71; }
            printf '%s  archive.tar.gz\\n' "$expected" | sha256sum --check -
            """
        } else {
            download = ""
        }
        return """
        set -eu
        umask 077
        cd \(quote(staging))
        \(download)
        tar -tzf archive.tar.gz > archive.list
        if grep -E '(^/|(^|/)\\.\\.(/|$))' archive.list >/dev/null; then
          echo 'Unsafe paths in Linux archive' >&2; exit 71
        fi
        mkdir unpacked
        tar -xzf archive.tar.gz -C unpacked --no-same-owner
        test -f unpacked/install.sh || { echo 'Linux archive is missing install.sh' >&2; exit 71; }
        /bin/bash unpacked/install.sh --bind-address 0.0.0.0 --ssh-port 8801 --http-port 8800
        """
    }

    static func importRepository(bundle: String, destination: String, snapshot: LinuxHostRepositorySnapshot) -> String {
        let marker = "\(snapshot.importKey)\n\(snapshot.commit)\n\(snapshot.branch)\n"
        let originSetup = snapshot.origin.map { "git -C \"$stage/repository\" remote set-url origin \(quote($0))" }
            ?? "git -C \"$stage/repository\" remote remove origin"
        // Ubuntu's GNU mv -T --no-clobber publishes the prepared directory
        // without nesting it into, or replacing, a concurrently created path.
        return """
        set -eu
        umask 077
        destination=\(quote(destination))
        parent=$(dirname "$destination")
        mkdir -p "$parent"
        lock="$destination.graftty-import-lock"
        mkdir "$lock" 2>/dev/null || { echo "GRAFTTY_IMPORT_LOCKED:$lock" >&2; exit 73; }
        stage=$(mktemp -d "$parent/.graftty-import.XXXXXXXX")
        cleanup() { rm -rf "$stage"; rmdir "$lock"; }
        trap cleanup EXIT
        trap 'exit 130' HUP INT TERM
        printf '%s' \(quote(marker)) > "$stage/expected"
        if test -e "$destination" || test -L "$destination"; then
          test ! -L "$destination" && test -d "$destination/.git" && test ! -L "$destination/.git" &&
          cmp -s "$stage/expected" "$destination/.git/graftty-import" &&
          test "$(git -C "$destination" rev-parse HEAD)" = \(quote(snapshot.commit)) &&
          test "$(git -C "$destination" symbolic-ref --short HEAD)" = \(quote(snapshot.branch)) &&
          status=$(git -C "$destination" status --porcelain --untracked-files=all --ignored) &&
          test -z "$status" || {
            echo "GRAFTTY_REPOSITORY_CONFLICT:$destination" >&2; exit 72;
          }
          exit 0
        fi
        git -c core.hooksPath=/dev/null clone --no-hardlinks --branch \(quote(snapshot.branch)) -- \(quote(bundle)) "$stage/repository"
        test "$(git -C "$stage/repository" rev-parse HEAD)" = \(quote(snapshot.commit))
        # clone puts nonselected heads under refs/remotes/origin. Materialize
        # all original local branches before removing or repointing that remote.
        git bundle list-heads \(quote(bundle)) > "$stage/heads"
        while IFS=' ' read -r commit ref; do
          case "$ref" in
            refs/heads/*) git -C "$stage/repository" update-ref "$ref" "$commit" ;;
          esac
        done < "$stage/heads"
        \(originSetup)
        cp "$stage/expected" "$stage/repository/.git/graftty-import"
        mv -T --no-clobber "$stage/repository" "$destination"
        test ! -d "$stage/repository" || { echo "GRAFTTY_REPOSITORY_CONFLICT:$destination" >&2; exit 72; }
        """
    }
}

# Template file — not installable as-is. The release workflow rewrites
# version + sha256 in the tap repo (btucker/homebrew-espalier) on each
# publish. See docs/release/README.md for the bootstrap procedure.

cask "espalier" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/btucker/espalier/releases/download/v#{version}/Espalier-#{version}.zip"
  name "Espalier"
  desc "Worktree-aware terminal multiplexer"
  homepage "https://github.com/btucker/espalier"

  depends_on macos: ">= :sonoma"

  app "Espalier.app"
  binary "#{appdir}/Espalier.app/Contents/Helpers/espalier"

  zap trash: [
    "~/Library/Application Support/Espalier",
    "~/Library/Preferences/com.espalier.app.plist",
    "~/Library/Caches/com.espalier.app",
  ]

  caveats <<~EOS
    Espalier is currently ad-hoc signed (not notarized). On first launch,
    macOS will refuse to open it with a Gatekeeper warning. To approve it:

      1. Try to open Espalier from /Applications (it will fail)
      2. Open System Settings → Privacy & Security
      3. Scroll to the "Security" section and click "Open Anyway" next to
         the Espalier message
      4. Confirm in the dialog that appears

    (On macOS 14 Sonoma you can alternatively right-click Espalier in
    Applications and choose "Open".)
  EOS
end

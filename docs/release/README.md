# Releasing Espalier

Espalier is distributed as a Homebrew Cask from the personal tap
[`btucker/homebrew-espalier`](https://github.com/btucker/homebrew-espalier).
The `.github/workflows/release.yml` workflow handles per-release work:
it builds the bundle, ad-hoc codesigns it, zips it, attaches the zip to
a GitHub release, and pushes a version+sha256 bump to the tap.

## One-time setup

These steps need to happen once, by hand, before the first tagged
release will succeed.

### 1. Create the tap repository

Create an empty public repository on GitHub named exactly
`btucker/homebrew-espalier`. The `homebrew-` prefix is what makes
`brew tap btucker/espalier` resolvable by the short name.

### 2. Create a Personal Access Token for cross-repo writes

Go to GitHub → Settings → Developer settings → Personal access tokens
→ Fine-grained tokens → Generate new token.

- Name: `espalier-release-bot` (any name; this is just a label)
- Expiration: 1 year (renew as needed)
- Repository access: Only select repositories → `btucker/homebrew-espalier`
- Repository permissions: **Contents: Read and write**
- (Leave all other permissions at "no access".)

Copy the generated token. Then on `btucker/espalier` go to Settings →
Secrets and variables → Actions → New repository secret. Name it
**`HOMEBREW_TAP_TOKEN`** and paste the token value.

### 3. Bootstrap the tap with the initial cask file

Copy `docs/release/Casks/espalier.rb` from this repo into the tap
repo at the same path:

```bash
cd /tmp
git clone git@github.com:btucker/homebrew-espalier.git
mkdir -p homebrew-espalier/Casks
cp /path/to/espalier/docs/release/Casks/espalier.rb homebrew-espalier/Casks/espalier.rb
cd homebrew-espalier
git add Casks/espalier.rb
git commit -m "Initial cask"
git push
```

The `version "0.0.0"` and zero-filled `sha256` are placeholders; the
release workflow rewrites both on the first real release.

### Keeping the cask in sync

The release workflow only rewrites the `version` and `sha256` lines in
the tap's `Casks/espalier.rb` — every other stanza (`url`, `app`,
`binary`, `zap`, `caveats`, etc.) is the copy you bootstrapped above.
If you change any of those stanzas in this repo's
`docs/release/Casks/espalier.rb`, you must manually re-sync that change
into the tap repo. The workflow will not propagate it on the next
release.

## Cutting a release

Once setup is complete:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Watch GitHub Actions on `btucker/espalier`. The `release` workflow
will build, sign, zip, publish, and bump the cask. Within a few
minutes:

```bash
brew tap btucker/espalier        # one-time per machine
brew install --cask espalier
espalier --help
```

## Migration path: Developer ID + notarization

Once an Apple Developer ID Application certificate is available, the
single change is in `scripts/bundle.sh`'s codesign block: swap
`--sign -` (ad-hoc) for `--sign "Developer ID Application: …"` and
add `--options runtime`. Then the release workflow gains a
`xcrun notarytool submit … --wait` step before zipping, plus
`xcrun stapler staple` after notarization completes. Drop the
`caveats` stanza from the cask file in the same change. Nothing else
in this pipeline moves.

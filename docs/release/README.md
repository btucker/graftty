# Releasing Graftty

Graftty is distributed as a Homebrew Cask from the personal tap
[`btucker/homebrew-graftty`](https://github.com/btucker/homebrew-graftty).
The `.github/workflows/release.yml` workflow handles per-release work:
it builds the bundle, ad-hoc codesigns it, zips it, attaches the zip to
a GitHub release, and pushes a version+sha256 bump to the tap.

## One-time setup

These steps need to happen once, by hand, before the first tagged
release will succeed.

### 1. Create the tap repository

Create an empty public repository on GitHub named exactly
`btucker/homebrew-graftty`. The `homebrew-` prefix is what makes
`brew tap btucker/graftty` resolvable by the short name.

### 2. Create a Personal Access Token for cross-repo writes

Go to GitHub → Settings → Developer settings → Personal access tokens
→ Fine-grained tokens → Generate new token.

- Name: `graftty-release-bot` (any name; this is just a label)
- Expiration: 1 year (renew as needed)
- Repository access: Only select repositories → `btucker/homebrew-graftty`
- Repository permissions: **Contents: Read and write**
- (Leave all other permissions at "no access".)

Copy the generated token. Then on `btucker/graftty` go to Settings →
Secrets and variables → Actions → New repository secret. Name it
**`HOMEBREW_TAP_TOKEN`** and paste the token value.

### 3. Bootstrap the tap with the initial cask file

Copy `docs/release/Casks/graftty.rb` from this repo into the tap
repo at the same path:

```bash
cd /tmp
git clone git@github.com:btucker/homebrew-graftty.git
mkdir -p homebrew-graftty/Casks
cp /path/to/graftty/docs/release/Casks/graftty.rb homebrew-graftty/Casks/graftty.rb
cd homebrew-graftty
git add Casks/graftty.rb
git commit -m "Initial cask"
git push
```

The `version "0.0.0"` and zero-filled `sha256` are placeholders; the
release workflow rewrites both on the first real release.

### 4. Generate the Sparkle EdDSA keypair

Sparkle verifies every update download against a public key baked into
the app bundle. The private half signs release zips in CI.

```bash
brew install --cask sparkle          # one-time; installs generate_keys + sign_update
generate_keys                        # stores the keypair in the Keychain
generate_keys -p                     # prints the base64 public key
generate_keys -x ~/sparkle-private.key  # exports the private key to a file
```

**Wire the public key into bundle.sh.** Open `scripts/bundle.sh`, find
the `__SPARKLE_PUBLIC_ED_KEY__` sentinel inside the Info.plist heredoc,
and replace it with the output of `generate_keys -p`. Commit:

```bash
git add scripts/bundle.sh
git commit -m "build: install Sparkle public key"
```

**Wire the private key into CI.** On GitHub, go to Settings → Secrets
and variables → Actions → New repository secret. Name it
`SPARKLE_ED_PRIVATE_KEY`. The value is the contents of
`~/sparkle-private.key` (one base64 line).

**Guard the private key.** After setting the GitHub secret, back the
file up somewhere safe (password manager, offline drive) and then shred
it from the working copy:

```bash
rm -P ~/sparkle-private.key
```

Losing both the Keychain copy and the backup means every user has to
manually re-download a new build — there is no recovery path.

### 5. Flip `auto_updates true` in the tap

The release workflow only rewrites `version` and `sha256` in the tap's
copy of `Casks/graftty.rb`. Adding the `auto_updates true` stanza is a
one-time manual sync:

```bash
cd /tmp/homebrew-graftty   # or wherever your checkout lives
git pull
# Edit Casks/graftty.rb to add  `auto_updates true`  after the sha256 line.
git add Casks/graftty.rb
git commit -m "cask: declare auto_updates true (Sparkle owns updates)"
git push
```

Once this lands, `brew upgrade --cask graftty` on a machine with an
up-to-date Sparkle-installed build becomes a no-op instead of
reinstalling a possibly-older cask version.

### Keeping the cask in sync

The release workflow only rewrites the `version` and `sha256` lines in
the tap's `Casks/graftty.rb` — every other stanza (`url`, `app`,
`binary`, `zap`, `caveats`, etc.) is the copy you bootstrapped above.
If you change any of those stanzas in this repo's
`docs/release/Casks/graftty.rb`, you must manually re-sync that change
into the tap repo. The workflow will not propagate it on the next
release.

## Cutting a release

Once setup is complete:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Watch GitHub Actions on `btucker/graftty`. The `release` workflow
will build, sign, zip, publish, and bump the cask. Within a few
minutes:

```bash
brew tap btucker/graftty        # one-time per machine
brew install --cask graftty
graftty --help
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

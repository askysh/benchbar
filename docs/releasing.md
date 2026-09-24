# Releasing BenchBar

Status: **designed, not live.** There is no Apple Developer account yet, so
every build today is signed ad hoc and only runs on the Mac that built it.
Everything below is written and ready; it switches on when the secrets
exist. Until then the release workflow skips itself with a notice.

## What a release is

| File | For | Made by |
|---|---|---|
| `BenchBar-<version>.dmg` | people downloading it, and Homebrew | signed, notarized, stapled |
| `BenchBar-<version>.zip` | Sparkle updates inside the app | the stapled app, zipped with `ditto` |
| `appcast.xml` | Sparkle's update feed | `generate_appcast`, signed with the EdDSA key |
| `benchbar.rb` | the Homebrew cask | `packaging/homebrew/benchbar.rb.tmpl` with the DMG's sha256 |
| `SHA256SUMS` | checking downloads | `shasum -a 256` |

All of them come out of one command, `scripts/macos-release.sh <version>`,
locally or in GitHub Actions.

## One time setup

### 1. Apple Developer Program

1. Enroll at developer.apple.com/programs (paid, yearly).
2. Note the **Team ID** (10 characters) under Membership details.

### 2. A Developer ID Application certificate

This is the certificate for apps distributed outside the Mac App Store.

1. Open Xcode, Settings, Accounts, add your Apple ID.
2. Select the team, click Manage Certificates, click +, choose
   **Developer ID Application**.
3. Open Keychain Access, find "Developer ID Application: Your Name
   (TEAMID)", right click, Export, save as `.p12` with a strong password.
4. The identity string is that exact name:
   `Developer ID Application: Your Name (TEAMID)`. Check it with:
   ```bash
   security find-identity -v -p codesigning
   ```

### 3. An App Store Connect API key for notarization

`notarytool` uses an API key instead of your Apple ID password.

1. Open App Store Connect, Users and Access, Integrations, App Store
   Connect API, Team Keys.
2. Generate a key with the **Developer** role.
3. Download `AuthKey_<KEYID>.p8` (only possible once) and note the
   **Key ID** and the **Issuer ID** shown on that page.

### 4. Sparkle EdDSA keys

Sparkle checks that every update was signed by you. The tools come with
the Sparkle package, fetched by the first Sparkle build:

```bash
scripts/macos-build.sh --sparkle
tools="$(dirname "$(find macos/build/DerivedData/SourcePackages/artifacts -name generate_keys | head -n 1)")"
"$tools/generate_keys"                       # creates the key in your login keychain, prints the public key
"$tools/generate_keys" -x sparkle_ed.key     # exports the private key to a file, for CI
```

The **public** key goes into the app (`SUPublicEDKey`). The **private**
key signs updates; keep it in your password manager and as a CI secret,
never in the repo. Losing it means existing installs can no longer
update, so back it up.

### 5. The Homebrew tap

1. Create the repository `askysh/homebrew-tap` on GitHub, with a
   `Casks/` folder.
2. For automatic cask updates, create a fine grained personal access
   token with Contents and Pull requests write access to that repository
   only.

People then install with:

```bash
brew install --cask askysh/tap/benchbar
```

The official `homebrew/cask` needs a notable, notarized app with some
history; submit there once BenchBar qualifies (roadmap v1.0).

## Secrets

Add these in the GitHub repository, Settings, Secrets and variables,
Actions:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12` | the `.p12` from step 2, base64: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | its password |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_TEAM_ID` | the Team ID |
| `NOTARY_API_KEY_P8` | the `.p8` from step 3, base64 |
| `NOTARY_API_KEY_ID` | its Key ID |
| `NOTARY_API_ISSUER_ID` | its Issuer ID |
| `SPARKLE_ED_PRIVATE_KEY` | the contents of `sparkle_ed.key` |
| `SPARKLE_ED_PUBLIC_KEY` | the public key `generate_keys` printed |
| `HOMEBREW_TAP_TOKEN` | optional: the tap token from step 5 |

The workflow's first job only checks that the first nine exist. If any is
missing, the release job is skipped and the run shows "Release skipped"
with the missing names.

## Cutting a release

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in
   `macos/project.yml`, and `FL_VERSION` in `benchbar` if the CLI changed.
2. Add the CHANGELOG entry.
3. Commit, then tag and push:
   ```bash
   git tag v0.3.0
   git push origin v0.3.0
   ```
4. GitHub Actions (`.github/workflows/macos-release.yml`) runs the CLI
   tests, then `scripts/macos-release.sh`, which runs the Swift tests and
   builds, then uploads the files to the GitHub release and opens a pull
   request on the tap.

The tag has to match `MARKETING_VERSION`; the script refuses otherwise.

### Locally, without CI

With the certificate in your keychain and the keys on disk:

```bash
export BENCHBAR_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export BENCHBAR_TEAM_ID=TEAMID
export NOTARY_KEY_PATH=~/keys/AuthKey_ABC123.p8 NOTARY_KEY_ID=ABC123 NOTARY_ISSUER_ID=...
export SPARKLE_ED_KEY_PATH=~/keys/sparkle_ed.key BENCHBAR_SPARKLE_PUBLIC_KEY=...
scripts/macos-release.sh --check      # tools, settings, identity, version
scripts/macos-release.sh 0.3.0
gh release create v0.3.0 dist/* --title "BenchBar 0.3.0" --generate-notes
```

## What each step does, and why

1. **Build and sign** (`scripts/macos-build.sh --sparkle` with
   `BENCHBAR_SIGN_IDENTITY` set). xcodebuild signs the app and Sparkle's
   helpers with the Developer ID, the Hardened Runtime and a secure
   timestamp. Notarization requires all three.
2. **Notarize the app.** `xcrun notarytool submit ... --wait` uploads a
   zip to Apple, which scans it and returns a ticket. Takes minutes.
3. **Staple.** `xcrun stapler staple BenchBar.app` attaches the ticket to
   the app, so Gatekeeper accepts it offline. The app is zipped again
   after stapling; that zip is the Sparkle download.
4. **DMG.** `hdiutil create` makes a compressed disk image holding the
   app and an Applications shortcut. The DMG is signed, notarized and
   stapled too, so the first open shows no warning.
5. **Appcast.** `generate_appcast` reads the zip, signs it with the
   EdDSA key and writes `appcast.xml` with the download URL on the GitHub
   release. The app's `SUFeedURL` points at
   `https://github.com/askysh/frappe-mac-dev-server/releases/latest/download/appcast.xml`,
   so the newest release's feed is always the one read.
6. **Cask.** The template gets the version and the DMG's sha256.

## Sparkle in the app

- Off by default. `scripts/macos-build.sh` builds without Sparkle; the
  app then contains no update code and makes no network requests.
- `scripts/macos-build.sh --sparkle` (or `BENCHBAR_SPARKLE=YES`) makes
  XcodeGen include `macos/sparkle.yml`: the Sparkle 2 package, the
  `SPARKLE` compilation condition, and `SUFeedURL`, `SUPublicEDKey` and
  `SUEnableAutomaticChecks` in Info.plist.
- `macos/BenchBar/Updates/Updater.swift` starts Sparkle's standard
  updater and adds **Check for Updates…** to the right click menu and the
  app menu.
- `BENCHBAR_APPCAST_URL` overrides the feed URL (for a test feed).

## Checking a signed build

```bash
codesign --verify --deep --strict --verbose=2 macos/build/BenchBar.app
spctl --assess --type execute --verbose=2 macos/build/BenchBar.app   # "source=Notarized Developer ID"
xcrun stapler validate dist/BenchBar-0.3.0.dmg
```

## Not in scope

- The Mac App Store: BenchBar has to run the `benchbar` CLI, which a
  sandboxed app cannot do.
- Intel builds: the app is Apple Silicon only (`ARCHS = arm64`).

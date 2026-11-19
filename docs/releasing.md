---
title: "Releasing BenchBar"
description: "How BenchBar releases are built, signed, notarized and published, with the ad hoc and Developer ID paths."
pagefind: false
---

One workflow, `.github/workflows/release.yml`, two paths. It runs when a
`v*` tag is pushed and drafts a GitHub release with the files below. You
review the draft and publish it. A tag with a suffix (`v0.9.0-rc.1`) is a
release candidate: the same build, drafted as a pre-release that no updater
offers (see [Release candidates](#release-candidates)).

| Path | When | What people get |
|---|---|---|
| **Developer ID** (since 0.6.1) | every `v*` tag | `BenchBar-<version>.zip`, `BenchBar-<version>.dmg` and `SHA256SUMS`, signed, notarized and stapled, plus `appcast.xml` for Sparkle and `benchbar-cli-<version>.tar.gz` for the Homebrew formula |
| **Ad hoc** (the only path up to 0.6.0) | a manual run with the `adhoc` input on, for a test | the same zip, dmg, CLI tarball and `SHA256SUMS`, ad hoc signed. A DMG download showed "Apple could not verify" once (the install page keeps the Open Anyway steps for those releases); `install.sh` downloads with curl, which sets no quarantine flag, so the app opened directly. |

The `check` job decides from the ref and the input, and reads no secret.
A tag build is always the Developer ID path. When one of the nine
secrets is missing, the run fails and names it; it never turns into an
unsigned release that looks normal in the draft (before 0.9.0 it did).
Ad hoc exists only when you start the workflow by hand with `adhoc` on,
and that job has no access to the secrets (see "Who can reach the keys").

## Branches

Work lands on `next-release`: every pull request targets it. `main` moves
only when a release is cut, so it always holds the last release, and so do
the one line installers and the docs site, which read from `main`. A push
to `main` with a new version tags it and starts the release builds
(`auto-tag.yml`).

A release is the same reviewed work moving up, not a new squash of it:
the maintainer **fast forwards `main` to the head of `next-release`**
(`git push origin <sha>:main`; no merge commit, no new commit at all). `main`
then holds the very commits that were reviewed and run by CI on
`next-release`, and its tip is a commit whose "CI result" is already green.
`main` and `next-release` are the same commit afterwards, so nothing has to
be merged back. A fast forward needs `main` to be an ancestor of
`next-release`. The one exception to "only a release moves `main`" is a
docs only pull request, which may target `main` so that it goes live on the
site at once (see [The docs site](#the-docs-site)): the next release first
brings those commits into `next-release` with one merge commit (step 5 of
[Cutting a release](#cutting-a-release)). A commit on `main` that changes
anything but docs makes the release refuse.

### Repository settings

These are settings of the repository, not files, so a pull request cannot
change them. The release does not need them to change; this is how they are
today, and the release relies on them:

- The `next-release` ruleset: changes go through a pull request, the only
  merge method is **squash**, and the check **CI result** must be green.
  Repository admins can bypass it.
- The `main` ruleset: **linear history**. Repository admins can bypass it,
  and that is how the maintainer pushes the fast forward (a fast forward
  keeps the history linear; the bypass is for the push, which does not come
  from a pull request). Nobody else can move `main`.
- The bot (`GITHUB_TOKEN`) pushes tags only, never a branch.

## The docs site

The site (<https://benchbar.akashmishra.com>) is built and deployed from
`main` only (`docs.yml`), so it describes the last release and never a
feature that has not shipped. A feature's pages are written on
`next-release`, in the pull request of the feature, and go live with the
release. Every pull request to `next-release` runs the docs test, the site
build and the internal link check; the external links are checked once a
week on `main` and a failure there means a link to fix, not a blocked
pull request. A page's "Edit page" link opens the file on `next-release`.

A docs only fix does not have to wait for a release (a wrong command, a
typo): a pull request that changes only docs (`docs/`, `site/`, `*.md`: the
rule of `scripts/docs-only.sh`) may target `main`, and the site shows it as
soon as it is merged. Everything else, and every pull request that also
touches code, targets `next-release`. The squash commit on `main` is a commit
`next-release` does not have, so the next release brings it in first, with one
merge commit of `main` into `next-release` (step 5). That merge changes only
docs, so CI runs no tests on it and the release gate walks back to the last
commit that did.

## Cutting a release

On `next-release`, then into `main`:

1. Run `scripts/bump-version.sh X.Y.Z`. It sets `FL_VERSION` in
   `benchbar`, `MARKETING_VERSION` in `macos/project.yml` and the version
   placeholder of the two bug report forms, folds the fragments in
   `changelog.d/` into `## Unreleased` of `CHANGELOG.md` (it runs
   `scripts/changelog-fold.sh`) and turns that section into
   `## X.Y.Z - date` with a new empty `## Unreleased` above it, and records
   the tray's CLI fixtures again (`tests/record-tray-fixtures.sh`: they hold
   `cli_version`). Commit what it changed.
2. Write the release paragraph in `README.md` and in `ROADMAP.md`: the only
   places the script cannot write for you. `scripts/check-version.sh` (the
   one check that `auto-tag.yml`, `release.yml` and
   `tests/test-version-sources.sh` all run) fails until both name the
   version, until the changelog has the section and until no fragment is
   left, so a gap shows on the release pull request and not after the
   merge. The workflow uses the changelog section as the release notes
   (`scripts/release-notes.sh`).
3. Write the section of this release in `docs/whats-new.md`: change
   `## X.Y.Z (coming)` to `## X.Y.Z (date)`, check its platform tags and
   upgrade notes against the folded `CHANGELOG.md` section, and add a
   section for a version that has none. `tests/test-docs.sh` fails when a
   version in `CHANGELOG.md` from 0.8.0 on has no section there.
4. Refresh the screenshots in `docs/images` for every screen the release
   changed, and add new ones where a page still has none:
   - The Mac first run wizard and the walkthrough: `WizardSnapshotTests`
     renders their pages with fixture data, in light and dark (the
     Snapshots workflow, `snapshots.yml`, runs on every pull request that
     changes `macos/` and uploads them as an artifact).
     Use them in `quick-start.md`, `install.md` and `app.md`.
   - The Windows first run wizard: take the screenshots on a Windows PC
     and use them in `windows.md`.
   - The BenchBar window panes: `window-general.png`, and a new
     `window-about.png`, since General and About moved back into the
     window in 0.8.1. `DocsSnapshotTests` renders the window panes, the
     Find User sheet and three wizard pages in a real key window (the
     window panes are captured as the window server draws them, so the
     sidebar and the selection look as in the app).
5. Merge those changes into `next-release` by pull request (squash, as
   always). For a release with a big change, cut a
   [release candidate](#release-candidates) first. Wait until the push run
   of CI on the new `next-release` head is green: that run is the one the
   release is built on. Merge nothing else until the tag exists.
6. Fast forward `main` to that commit. You need to be a repository admin who
   can bypass the `main` ruleset:

   ```bash
   git fetch origin
   git merge-base --is-ancestor origin/main origin/next-release   # must succeed
   git push origin origin/next-release:refs/heads/main
   ```

   Check first that the "CI result" of that commit is green, that
   `main` is an ancestor of it and that `scripts/check-version.sh --folded`
   passes on it. Never force the push.

   If `main` is not an ancestor, look at what only `main` has
   (`git log --oneline origin/next-release..origin/main`). When every commit
   changes only docs (`scripts/docs-only.sh --commit <sha>` for each), bring
   them into `next-release` with one merge commit and push it (a fast
   forward of `next-release`; the admin bypasses its ruleset), then wait for
   the "CI result" of the merge before step 5 again:

   ```bash
   git checkout --detach origin/next-release
   git merge --no-ff origin/main -m "Merge main into next-release (docs fixes)"
   git push origin HEAD:refs/heads/next-release
   ```

   On a conflict, stop (`git merge --abort`) and bring the change over by
   pull request. If any commit of `main` changes code, do not merge: ask the
   maintainer how to put `main` right.
7. `auto-tag.yml` runs `scripts/check-version.sh` (every place says the same
   version, CHANGELOG.md has its section, no fragment is left), refuses a
   release candidate version on `main`, tags `vX.Y.Z` on that commit and
   starts `release.yml` and `release-windows.yml` for the tag. A push to
   `main` that keeps the version and changes only docs tags nothing (a
   notice); one that changes code **fails** ("release PR merged without a
   version bump?"). A tag pushed by hand still starts both release workflows.
   If `main` has a commit that `next-release` has not, the push is not a
   fast forward and git refuses it: do not force it. Docs fixes are brought
   over by the merge of step 5; a code commit on `main` was pushed by
   mistake, and it is a decision about history (not a script) how to put
   `main` right.
8. Wait for the release workflows, open the draft on the Releases page,
   check the files, publish.
9. Publishing starts the Homebrew tap workflow (`homebrew-tap.yml`,
   below). It opens a pull request on `askysh/homebrew-tap` and stops.
   Read it (the formula and cask diff) and merge it yourself; until then
   `brew install` still gives the old version.

The version comes from the tag, so the checkout is never edited by CI:

- `CFBundleShortVersionString` is set from the tag.
- `CFBundleVersion` is set from the commit count.
- The Windows zips and the tray take the version from the tag too:
  `main.version` for `benchbar.exe`, `-p:Version` for the tray.

### The Windows zips

The same tag starts `release-windows.yml`. It builds `benchbar.exe` (Go)
and the tray app (framework dependent .NET 10) for x64 and Arm64, packs
`benchbar-windows-X.Y.Z-amd64.zip` and `-arm64.zip` (both programs, the
tray's files, `README.txt` and a `SHA256SUMS` inside), and attaches them
with `benchbar-windows-X.Y.Z-SHA256SUMS.txt` to the draft that
release.yml creates for the tag. On a tag push it waits up to 130 minutes for that
draft (the Mac job allows 120) and creates one only if none appears; a manual run attaches only to an existing draft. The sums file must not end
in `SHA256SUMS`: `install.sh` picks the first asset with that ending for
the Mac app. The workflow never publishes. Re-run it after a re-run of
release.yml, which replaces the notes and with them the Windows
paragraph.

Nothing in the zips is code signed: SignPath Foundation declined the
project on 2026-11-13 and the workflow has no signing step, no signing
secrets and no gate on signing. Every package job stops after 40
minutes. The package job still records what `Get-AuthenticodeSignature`
says about every `.exe` and `.dll` (`signing-ARCH.json`), and `README.txt`
and the release notes quote it, so a download says plainly what is
unsigned. When a signing route exists, add it back as its own job.

The release job also attests both zips with `actions/attest-build-provenance`
(it needs the `id-token` and `attestations` write permissions), so
`gh attestation verify benchbar-windows-X.Y.Z-amd64.zip -R askysh/benchbar`
works. The notes and `README.txt` tell users to run the one liner as
`& ([scriptblock]::Create((irm URL))) -Version X.Y.Z`, which pins the
version and sets nothing in their session. A build that is not a release
points at `main` instead of a tag.

Publish only after both release workflows (`release.yml` and
`release-windows.yml`) have finished: releases are immutable, so a
file that arrives after publishing can never be added.

Before publishing the draft, check:

1. Both zips and the sums file are attached, and the Windows paragraph
   of the notes names the unsigned binaries (all of them while there are no
   signing secrets).
2. `install.ps1 -Version X.Y.Z` cannot be tried on a draft (its assets
   answer 404): download the amd64 zip from the draft instead, unpack it,
   run `benchbar.exe --shim-version` and start `BenchBarTray.exe`
   against a distro with a bench.
3. After publishing, run the one liner from
   [Windows](windows.md#install) on a clean Windows 11 (a VM or Windows
   Sandbox) and check these:
   - One line installer: no dialog is expected.
   - Zip route (unpack, start a program yourself): the "Open File -
     Security Warning" is expected until the builds are signed.
   - Smart App Control on: the installer stops before it writes anything.
4. Submit the two zips at <https://www.microsoft.com/wdsi/filesubmission>
   as a software developer when Defender flags them. This is a manual
   step for each release.

To try the Windows build without a release, run Release Windows by
hand with a version and `draft_release` off: the zips land as workflow
artifacts only. A pull request that changes `release-windows.yml` or
`install.ps1` builds both zips and runs the installer on windows-latest.

To give testers a build before a release: run Release Windows by hand
from main with a version such as `0.8.0` and `draft_release` off, then
download the `windows-amd64` (and `windows-arm64`) artifact from the
run's summary page. Each holds the zip and its `sums-<arch>.txt`. Send
the zip; the tester unpacks it and runs its own `install.ps1`, as
[Windows](windows.md#a-test-build-you-were-sent) describes. The
programs are unsigned, so starting one from the unpacked folder shows the
Open File security warning and Smart App Control in enforce mode blocks them: testers need it off or in
evaluation mode.

### Trying a build without a release

Every pull request run of CI that builds the app (`ci.yml`, job "App
build, Swift tests and unsigned release bundle (macOS)") uploads the same zip, dmg and `SHA256SUMS` as a workflow artifact named
`BenchBar-unsigned-<sha>`: open the run on the Actions tab, scroll to
Artifacts, download. Locally, the same files come from:

```bash
brew install xcodegen
scripts/release-local.sh            # version from project.yml, Swift tests first
scripts/release-local.sh --skip-tests
ls dist/
```

`release-local.sh` needs full Xcode, XcodeGen and nothing else. It is the
ad hoc path of the workflow, running on your Mac.

## Release candidates

A release candidate (`X.Y.Z-rc.N`, for example `0.9.0-rc.1`) is the release
build, signed and notarized the same way, published as a GitHub
**pre-release**. It exists so one live QA pass can run on the real files
before the release. Nobody gets it by updating.

**Cut one.** On `next-release`:

1. `scripts/bump-version.sh 0.9.0-rc.1` sets the version in every place. A
   candidate needs no changelog section, no README or ROADMAP paragraph and
   no folded fragments; its notes are `## Unreleased` with the fragments
   folded in. Merge that change into `next-release` by pull request.
2. Tag the merged commit by hand and push the tag:
   `git tag v0.9.0-rc.1 COMMIT && git push origin v0.9.0-rc.1`. The tag
   starts `release.yml` and `release-windows.yml`. The `release` environment
   accepts it (its `v*` rule) and waits for you as for a release. The build
   refuses a tag whose commit is not on `main` or `next-release`.
3. When both workflows are done, open the draft: it is marked **pre-release**
   and not latest. Check the files as for a release, then publish. Publishing
   a pre-release does not move "latest".
4. Do the QA from the install line in the release notes, on a clean user or
   Mac: `curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/v0.9.0-rc.1/install.sh | bash -s -- --version v0.9.0-rc.1`,
   and on Windows the one liner of the notes with `-Version 0.9.0-rc.1`.
5. Fix what it shows with ordinary pull requests, and cut `rc.2` if the
   changes need another pass. Then run `scripts/bump-version.sh 0.9.0` and
   release as above. Do not delete a published candidate; releases are
   immutable.

**Who ignores it, and how.** Each of these reads GitHub's "latest release",
which is never a pre-release or a draft, or lists releases and skips
pre-releases:

| Reader | How it skips a candidate |
|---|---|
| Sparkle (the app's own updates) | The feed is `releases/latest/download/appcast.xml`: GitHub redirects it to the latest release, so a candidate's own `appcast.xml` is reachable only by its tag URL. |
| The app's update banner and Update Now | `UpdateCheck` reads `releases/latest` and also ignores an answer marked `prerelease` or `draft`. |
| `install.sh`, `benchbar self-update` | `releases/latest`. |
| Homebrew tap (`homebrew-tap.yml`) | The job has `if: ... !github.event.release.prerelease`, so it does not even ask for the environment. A run by hand for a version with a suffix stops at once. The nightly formula check skips a candidate too. |
| `install.ps1`, `benchbar.exe self-update`, the tray's update check | They list releases and skip a draft, a pre-release and any tag that is not `X.Y.Z`. |

**Opt in.** Name the version: `install.sh --version v0.9.0-rc.1`,
`install.ps1 -Version 0.9.0-rc.1`, `benchbar.exe self-update --version
0.9.0-rc.1`. The Mac app built from a candidate carries `0.9.0-rc.1` as its
version, so Sparkle later moves it to `0.9.0` (its build number, the commit
count, is higher). `benchbar.exe` built from a candidate behaves as a
development build: it never offers an update, so a Windows tester installs
the release with the one liner. `benchbar self-update` has no `--version`:
to leave a candidate on the Mac, run the installer without a version.

## The Developer ID path: one time setup

Everything below needs the nine secrets (and the tap token) in the
`release` environment; the repository has had them since 0.6.1. A tag
build without them fails.

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

`askysh/homebrew-tap` holds two benchbar files, both written by
`.github/workflows/homebrew-tap.yml` when a release is published. The
tap also holds the cask of [Margin](https://github.com/askysh/margin),
which its own workflow updates.

| File | Installs | Updated for |
|---|---|---|
| `Formula/benchbar.rb` | the CLI, from `benchbar-cli-<version>.tar.gz` | every release |
| `Casks/benchbar-app.rb` | BenchBar.app, from the DMG; depends on the formula | signed releases (those with `appcast.xml`) |

The workflow runs on publish, not with the draft: a draft's download
URLs answer 404, so a formula merged earlier would break `brew install`.
It downloads the release's tarball and DMG, checks them against
`SHA256SUMS`, renders the formula and cask from `packaging/homebrew`
with `scripts/homebrew-render.sh`, runs `brew style` and `brew audit
--strict --online`, installs both, runs `brew test`, uninstalls, and
opens a pull request on the tap. It does not merge it: you read the
pull request and merge it once the tap's checks pass. It also closes the open tap pull requests of older
benchbar versions. The tap's `tests` check audits, installs and
uninstalls only the files a pull request changes. Thus a Margin release
at the same time does not block a benchbar release. A prerelease leaves
the tap alone. Run it by hand
to redo one: Actions tab, Homebrew tap, Run workflow, choose the tag
`vX.Y.Z` as the branch or tag, and type the version. A run on a branch
is refused by the `release` environment.

It needs `HOMEBREW_TAP_TOKEN`: a fine grained personal access token
with Contents and Pull requests write access to `askysh/homebrew-tap`
only, kept in the `release` environment. Only the last step reads it:
the tap is cloned without it, so no credential sits in the clone while
`brew` runs the formula. Without the token the workflow still checks
everything and prints the two files to copy by hand. The tap's `tests`
check should be required on `main`. The token acts as the owner's
account, so it could merge a tap pull request too; the workflow never
does. Closing that gap needs a second identity (a GitHub App) and is a
known residual risk.

People then install with:

```bash
brew install askysh/tap/benchbar askysh/tap/benchbar-app   # CLI and app
brew install askysh/tap/benchbar                           # CLI only
```

Both names are typed because Homebrew only trusts a third party tap for
the names given on the command line; the cask alone would be refused its
formula. Since 0.7.1 the app also carries its own copy of the CLI (the
same files as the formula's tarball, copied in by
`scripts/app-embed-cli.sh` when the app is built), and the formula's
`benchbar` hands off to it. The formula still stands on its own, so it
works on Intel Macs too while the cask is Apple silicon only.

Pull requests that change the CLI or `packaging/homebrew` also run
`homebrew-formula.yml`, which builds the tarball from the checkout,
installs it from a throwaway local tap with a `file://` url, and runs
the CLI in an empty HOME; it runs nightly too, since brew itself
changes. It is not a required check.

The official `homebrew/cask` needs a notable, notarized app with some
history; submit there once BenchBar qualifies (roadmap v1.0).

### Who can reach the keys

The ten secrets below live in the **`release` environment**, not in the
repository secrets. Settings, Environments, `release`:

- **Deployment branches and tags:** only tags matching `v*`. A run on
  any other ref cannot start a job that names the environment.
- **Required reviewer:** the maintainer (`askysh`). Every job that reads a
  secret waits for the approval.

Every job that reads a secret declares `environment: release`: the
`build-signed` job of `release.yml` and the `tap` job of
`homebrew-tap.yml`. No other job does, and no job that runs for a pull
request does, so a pull request never reaches the environment. The
signed build is started with the tag as its ref, by `auto-tag.yml`
(`gh workflow run release.yml --ref vX.Y.Z`, dispatched with the
`GITHUB_TOKEN`) or by a pushed tag, so the deployment ref is the tag
and the `v*` rule matches. A dispatch from a branch (without `adhoc`)
fails in the `check` job before the environment is asked.
`tests/test-release-workflows.sh` fails when a workflow reads one of
these secrets in a job without the environment, or names the
environment without needing a secret.

**What you approve.** GitHub shows "Review pending deployments" on the
run: it names the workflow, the tag and the commit, and says the job
wants the `release` environment. Check that the tag is the one you cut
(`auto-tag.yml` tagged it, or you did), that its commit is the merge
commit you expect on `main`, and that nobody pushed a different commit
under that tag. Approving hands the keys to that commit's
`scripts/macos-release.sh` and workflow files, so read the diff of
`.github/`, `scripts/` and `packaging/` since the last release first if
anyone else had write access. Reject anything else: a rejected run
costs nothing and can be started again. The `tap` job is approved
the same way after you publish the draft; check the version only.

The keys sit on the runner for as short a time as the build allows. The
certificate is imported into a temporary keychain in the step that
signs, for `codesign` only, and its file is deleted at once. The keychain
locks after an hour without use (not shorter: signing, a notarization
that can take 50 minutes, and signing again). The notary
key and the Sparkle key are not in the environment of the build or its
tests: `macos-release.sh` writes each to a 0600 file in one folder
(`BENCHBAR_KEY_DIR`) for the one command that uses it (`notarytool`,
`generate_appcast`) and deletes it. An `always()` step deletes the
keychain and that folder right after the build, before the draft is
created, and the checkout keeps no token in `.git/config`.

**Rotating a key.** Make the new one, set it in the `release`
environment (Settings, Environments, `release`, edit the secret), cut or
re-run a release candidate to prove it, then revoke the old one:

| Key | New one | Revoke the old one |
|---|---|---|
| `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGN_IDENTITY` | step 2 above; update the identity string too | Apple Developer, Certificates, Revoke (apps already signed keep working) |
| `NOTARY_API_KEY_P8`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER_ID` | step 3 | App Store Connect, Integrations, Revoke |
| `SPARKLE_ED_PRIVATE_KEY`, `SPARKLE_ED_PUBLIC_KEY` | do not rotate lightly: installed apps trust the old public key, so an update signed with a new one is refused. Ship a release signed with the old key that carries the new public key first (`SUPublicEDKey`), then switch | nothing to revoke; delete the old key only after the last install has updated |
| `HOMEBREW_TAP_TOKEN` | a new fine grained token, one repository (`askysh/homebrew-tap`), Contents and Pull requests write, 90 day expiry; put the expiry date in your calendar | delete the old token in GitHub, Settings, Developer settings |

If a key may have leaked (a run you did not approve, a laptop lost),
revoke first and rotate after. For Sparkle there is no revoke: ship a
release with a new key pair signed by the old one, and say so in
`SECURITY.md`.

### Who may change the release code

`.github/CODEOWNERS` names the maintainer on `.github/`, `.claude/`,
`scripts/`, `packaging/`, `install.sh`, `install.ps1` and the release
files (`config/release-profiles.tsv`, `macos/project.yml`,
`macos/sparkle.yml`, `windows/shim/versioninfo.json`, this page). It
takes effect when the ruleset on `main` turns on "Require review from
Code Owners". Beside it the repository needs a tag ruleset for `v*`
(no deletion, no update) and the "Immutable releases"
setting, so a published tag and its files cannot be replaced (the tag
ruleset restricts update and deletion only: `auto-tag.yml` still creates
the tag with the `GITHUB_TOKEN`). The release workflows fail on a
published release and never use `--clobber`; the tap
needs the same Code Owners rule on `Formula/` and `Casks/`.

### Secrets

Add these in the GitHub repository, Settings, Environments, `release`,
Environment secrets (not Repository secrets):

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
| `HOMEBREW_TAP_TOKEN` | the tap token from step 5; without it the tap is updated by hand |

The `build-signed` job needs the first nine and checks them before it
builds. With any missing it fails and names them; it does not fall back
to ad hoc.

### Locally, without CI

With the certificate in your keychain and the keys on disk:

```bash
export BENCHBAR_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export BENCHBAR_TEAM_ID=TEAMID
export NOTARY_KEY_PATH=~/keys/AuthKey_ABC123.p8 NOTARY_KEY_ID=ABC123 NOTARY_ISSUER_ID=...
export SPARKLE_ED_KEY_PATH=~/keys/sparkle_ed.key BENCHBAR_SPARKLE_PUBLIC_KEY=...
scripts/macos-release.sh --check      # tools, settings, identity, version
scripts/macos-release.sh 0.3.0        # NOTARY_TIMEOUT=2h for a slow first notarization
gh release create v0.3.0 dist/* --title "BenchBar 0.3.0" --draft
```

## What each step does, and why

### Ad hoc path (`scripts/release-local.sh`)

1. **Build** with `scripts/macos-build.sh`, version and build number from
   the environment, then `codesign --force --deep -s -`. An ad hoc
   signature satisfies Apple Silicon's requirement that every binary is
   signed, but carries no identity, so Gatekeeper cannot trust it.
2. **Zip** with `ditto -c -k --keepParent`, the form macOS expects for
   app bundles (resource forks and symlinks survive).
3. **DMG** with `hdiutil create`, holding the app and an Applications
   shortcut for drag and drop.
4. **SHA256SUMS** with `shasum -a 256`. `install.sh` checks the zip
   against it before unpacking.

### Developer ID path (`scripts/macos-release.sh`)

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
5. **Appcast.** `scripts/macos-appcast.sh` runs `generate_appcast`, which
   reads the zip, signs it with the EdDSA key and writes `appcast.xml` with
   the download URL on the GitHub release and a link to the release notes
   (`--full-release-notes-url`), then checks the result (every item has an
   https download, a build, a version and a signature). The app's `SUFeedURL`
   points at
   `https://github.com/askysh/benchbar/releases/latest/download/appcast.xml`,
   so the newest release's feed is always the one read. A folder with no
   `BenchBar-*.zip` (a release without Mac files) makes the script print
   `[SKIP]`, write nothing and exit 0.
6. **Cask.** Not part of this script. The tap's formula and cask are
   written after the release is published, from these files, by
   `homebrew-tap.yml`, which opens a pull request on the tap when
   `HOMEBREW_TAP_TOKEN` exists (see [The Homebrew tap](#5-the-homebrew-tap)).

## Sparkle in the app

- Off by default. `scripts/macos-build.sh` builds without Sparkle; the
  app then contains no update code and makes no network requests. The ad
  hoc path never includes it: Sparkle needs signed updates to be safe.
- `scripts/macos-build.sh --sparkle` (or `BENCHBAR_SPARKLE=YES`) makes
  XcodeGen include `macos/sparkle.yml`: the Sparkle 2 package, the
  `SPARKLE` compilation condition, and `SUFeedURL`, `SUPublicEDKey` and
  `SUEnableAutomaticChecks` in Info.plist.
- `macos/BenchBar/Updates/Updater.swift` starts Sparkle's standard
  updater and adds **Check for Updates…** to the right click menu and the
  app menu.
- `BENCHBAR_APPCAST_URL` overrides the feed URL (for a test feed).
- Pull request CI builds this configuration too (the `app` job): the
  Sparkle build, the updater test (`UpdaterTests`, which checks the feed key
  and the update switch in Info.plist) and an unsigned appcast made from the
  build's zip with `scripts/macos-appcast.sh --unsigned` and checked, with a
  placeholder public key and no secret. A break of the Sparkle package, of
  `sparkle.yml` or of the feed format shows on the pull request, not when
  a release is cut.

## Checking a build

```bash
codesign -dv --verbose=2 macos/build/BenchBar.app            # ad hoc: "Signature=adhoc"
codesign --verify --deep --strict --verbose=2 macos/build/BenchBar.app
spctl --assess --type execute --verbose=2 macos/build/BenchBar.app   # Developer ID: "source=Notarized Developer ID"
xcrun stapler validate dist/BenchBar-0.3.0.dmg                # Developer ID only
shasum -a 256 -c dist/SHA256SUMS
```

## Not in scope

- The Mac App Store: BenchBar has to run the `benchbar` CLI, which a
  sandboxed app cannot do.
- Intel builds: the app is Apple Silicon only (`ARCHS = arm64`).

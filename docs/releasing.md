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
brings those commits into `next-release` with one merge commit (step 6 of
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
merge commit of `main` into `next-release` (step 6). That merge changes only
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
2. Change the "The latest release is X.Y.Z" line in `README.md` and in
   `ROADMAP.md`: the only places the script cannot write for you. `scripts/check-version.sh` (the
   one check that `auto-tag.yml`, `release.yml` and
   `tests/test-version-sources.sh` all run) fails until both name the
   version, until the changelog has the section and until no fragment is
   left, so a gap shows on the pull request of step 5 and not after the
   merge. The workflow uses the changelog section as the release notes
   (`scripts/release-notes.sh`).
3. Write the section of this release in `docs/whats-new.md`: change
   `## X.Y.Z (coming)` to `## X.Y.Z (date)`, check its platform tags and
   upgrade notes against the folded `CHANGELOG.md` section, and add a
   section for a version that has none. `tests/test-docs.sh` fails when a
   version in `CHANGELOG.md` from 0.8.0 on has no section there, and when
   the section of the version in `benchbar` still says `(coming)`.
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
   release is built on. Then start the real installs on macOS on that
   commit and wait for them (7 and 8 minutes once two Macs are free):
   `gh workflow run real-install.yml --ref next-release`. The nightly run
   does not count: GitHub runs a schedule from `main`, so its result
   attaches to the head of `main`, not to the commit you release. No push starts
   them (they need two of the five macOS runners the repository gets), and
   the release gate refuses a commit that has no passed
   "Real install result (macOS)". Merge nothing else until the tag exists.
6. Fast forward `main` to that commit with `scripts/release-promote.sh`. You
   need gh signed in, and to be a repository admin who can bypass the `main`
   ruleset. Run it with `--dry-run` first: it prints the plan and pushes
   nothing. It checks, and stops at the first failure:
   - `main` is an ancestor of `next-release`. If it is not and only docs
     commits are missing from `next-release`, it offers the sync described
     below; otherwise it refuses. It never forces;
   - `benchbar` at that commit has a final version (not a candidate), every
     place agrees and no fragment is left (`scripts/check-version.sh --folded`
     on that commit's files);
   - the tag `vX.Y.Z` does not exist yet;
   - "CI result" is green on the commit, and on the nearest commit that
     changed code (`scripts/release-ci-gate.sh`: a push that changed only
     docs runs no tests, so its green says nothing about the code);
   - "Real install result (macOS)" is green on the commit, or on a docs
     only commit under it down to that code commit (the same script; the
     workflow is `real-install.yml`, started by hand in step 5).

   Then it asks, and pushes with `git push origin <sha>:refs/heads/main`
   (`--yes` skips the question).

   **When `main` is ahead (docs fixes).** A docs only pull request may
   target `main` (see [The docs site](#the-docs-site)), so `main` can have
   commits that `next-release` has not, and then it is not an ancestor. The
   script lists them. When every one changes only docs
   (`scripts/docs-only.sh`), it offers a sync: it makes one real merge
   commit of `origin/main` into `origin/next-release` (it builds the merge
   in memory, so your working tree and branches stay as they are), shows it
   and, after a yes (or with `--yes`), pushes it with
   `git push origin <merge>:refs/heads/next-release`: a fast forward of
   `next-release`, which the admin may push past the ruleset. A conflict
   stops it with nothing pushed: bring the docs change over by pull request.
   The merge is a commit CI has not run yet, so the script then stops at the
   gate ("CI result" is not green on the merge yet); wait for CI on
   `next-release`, run the script again, and it is a plain fast forward. The
   merge changes only docs, so the gate walks back to the last code commit
   and needs a green result there too. `--dry-run` shows the sync and
   pushes nothing. When any commit that only `main` has changes code, the
   script refuses and names it. It never forces, never rewrites history and
   never merges the other way (`next-release` into `main`).
7. `auto-tag.yml` runs `scripts/check-version.sh` (every place says the same
   version, CHANGELOG.md has its section, no fragment is left), refuses a
   release candidate version on `main`, tags `vX.Y.Z` on that commit and
   starts `release.yml` and `release-windows.yml` for the tag. A push to
   `main` that keeps the version and changes only docs tags nothing (a
   notice); one that changes code **fails** ("release PR merged without a
   version bump?"). A tag pushed by hand still starts both release workflows.
   If `main` has a commit that `next-release` has not (a docs fix that was
   merged to `main`), the script offers the sync below; for a commit that
   changes code it refuses, and git would refuse the push as well: do not
   force it. The commit was pushed to `main` by mistake or came from a fix
   made there; bring its change to `next-release` by pull request, and ask
   the maintainer how to put `main` right (it is a decision about history,
   not a script).
8. Wait for the release workflows, open the draft on the Releases page,
   check the files, publish.
9. Publishing starts the Homebrew tap workflow (`homebrew-tap.yml`,
   below). It opens a pull request on `askysh/homebrew-tap` and stops.
   Read it (the formula and cask diff) and merge it yourself; until then
   `brew install` still gives the old version.
10. Close the release's milestone. First close every issue in it that the
    release fixes, with a comment that names the version
    (`gh issue close N --comment "Fixed in X.Y.Z."`), and move what is
    not fixed to the next milestone. Issues do not close on their own:
    pull requests merge into `next-release`, and GitHub closes an issue
    only from a merge into `main` whose commit message holds the keyword,
    which a squash commit here does not. Then reply on every issue a user
    opened that the release answers, so the reporter hears it.

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

The release job also attests both zips and the checksums file with `actions/attest-build-provenance`
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

### When a test pass finds a bug

Write it in [Known issues](troubleshooting.md#known-issues) in the same
pull request that files or fixes it: the version, what a person sees, and
the way around it. Remove the line in the pull request that fixes it. A
bug found while a release is being cut and not fixed before the tag goes
in that list before the draft is published.

## Release candidates

A release candidate (`X.Y.Z-rc.N`, for example `0.9.0-rc.1`) is the release
build, signed and notarized the same way, published as a GitHub
**pre-release**. It exists so one live QA pass can run on the real files
before the release. Nobody gets it by updating.

**When it is required.** In the history up to 0.8.3, 13 of 17 gaps between
releases are under 48 hours, and the large 0.8.0 was followed by 0.8.1, 0.8.2
and 0.8.3 after 44, 133 and 270 hours: users got versions that needed a
live QA pass afterwards. A candidate is that pass, before they get the
release. Cut one when the release has any of these (a rule of thumb, change
it when it does not fit); a release with none may go straight to the release:

- [ ] a new feature area, or a command or Mac app screen that changes how
      people start, stop or install (the 0.8.0 wizard, 0.8.2 rooms);
- [ ] a change to an installer (`install.sh`, `install.ps1`), to the signing
      or update path, to a runner or service template, or to the Windows
      shim or tray;
- [ ] more than about 20 merged pull requests since the last release, or one
      of more than 1000 changed lines.

Before the release, with the candidate installed from its pinned
line on a clean Mac user (and a clean Windows 11 when Windows changed):

- [ ] `benchbar doctor` is clean, and `benchbar --version` and the app's
      About say the candidate's version;
- [ ] a first run: the wizard, then a bench from the app, then `benchup`
      and the site opening;
- [ ] an update over the previous release (install the previous release,
      then the candidate with `--version`): the existing bench still starts
      and nothing in `sites/` changed;
- [ ] the feature the release is about, once, by hand, in light and dark;
- [ ] Windows: the one liner of the notes with `-Version`, the tray's first
      start, and `benchbar.exe self-update --check`.

The pull request of step 5 of [Cutting a release](#cutting-a-release) says
which candidate passed this list. The release
itself is the merge of what the candidate tested plus fixes found by it.

**Cut one.** On `next-release`:

1. `scripts/bump-version.sh 0.9.0-rc.1` sets the version in every place. A
   candidate needs no changelog section, no README or ROADMAP paragraph and
   no folded fragments; its notes are `## Unreleased` with the fragments
   folded in. Merge that change into `next-release` by pull request.
2. Start the real installs on macOS on the merged commit and wait for
   them: `gh workflow run real-install.yml --ref next-release`. The release
   job refuses a candidate whose commit has no passed
   "Real install result (macOS)", as it does for a release.
3. Tag the merged commit by hand and push the tag:
   `git tag v0.9.0-rc.1 COMMIT && git push origin v0.9.0-rc.1`. The tag
   starts `release.yml` and `release-windows.yml`. The `release` environment
   accepts it (its `v*` rule) and waits for you as for a release. The build
   refuses a tag whose commit is not on `main` or `next-release`.
4. When both workflows are done, open the draft: it is marked **pre-release**
   and not latest. Check the files as for a release, then publish. Publishing
   a pre-release does not move "latest".
5. Do the QA from the install line in the release notes, on a clean user or
   Mac: `curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/askysh/benchbar/v0.9.0-rc.1/install.sh | bash -s -- --version v0.9.0-rc.1`,
   and on Windows the one liner of the notes with `-Version 0.9.0-rc.1`.
6. Fix what it shows with ordinary pull requests, and cut `rc.2` if the
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
the release with the one liner.

On a Mac, the installer pins both halves to the candidate: the app from the
pre-release, and the CLI as a detached checkout of the tag
(`install.sh --version v0.9.0-rc.1`, also with `--no-app` for the CLI alone).
Two other routes cannot install a candidate, by design: **Homebrew** only
ever sees a published release (the tap skips a candidate), and **`benchbar
self-update` has no `--version`**: it installs the latest release. To leave
a candidate and go back, run the installer without a version
(`install.sh --yes`): it switches the CLI back to `main` and installs the
latest app. An app update to a final release (Update Now) passes
`--version` too, but leaves the CLI on `main`.

## When a release goes wrong

Releases are immutable: a published release's files and its tag can never
be replaced or deleted, and the tag ruleset forbids moving any `v*` tag. So
every repair below ends in the same place: a **new version** (the next
patch), never an edit of the old one. What you can still change on a
published release is its notes and its flags.

### A release run failed

The release job does not run the test suite. It first checks that the CI
result of the tagged commit is green, and of the nearest commit that
changed code when the tagged one changed only docs
(`scripts/release-ci-gate.sh`), then `scripts/check-version.sh`, then builds.

| What failed | What to do |
|---|---|
| `auto-tag.yml` stopped on `check-version.sh` (nothing is tagged) | `main` already holds the fast forward (`release-promote.sh` runs the same check first, so this is rare). Fix the named place on `next-release` by pull request and run `scripts/release-promote.sh` again: `main` is an ancestor of the fix, and a push to `main` with a version that has no tag tags it. |
| The gate says CI is red or missing | Fix `next-release`, wait for a green push run, then release again as above. A tag that exists for a bad commit stays; the next patch version replaces it. |
| `release.yml` failed after the tag exists (signing, notarization, a runner) | Re-run the failed jobs on the same run, or start it again on the tag: `gh workflow run release.yml --ref vX.Y.Z -f version=X.Y.Z`. Approve the `release` environment again. A draft of that tag is reused: files of the same name are deleted from the draft and uploaded again, nothing is overwritten. |
| `release-windows.yml` failed | Re-run it the same way (`gh workflow run release-windows.yml --ref vX.Y.Z -f version=X.Y.Z -f draft_release=true`) after `release.yml` has made the draft. Re-run it again after any later `release.yml` run, which replaces the notes. |
| The release was published before a file arrived | A late file can never be added. Cut the next patch version. This is why you publish only after both workflows finish. |

### A published release is bad

Sparkle checks once a day, `install.sh` and `benchbar self-update` ask for
the latest release whenever they run, and the tap serves a release once its
pull request is merged. In this order:

1. **Stop the spread.** Mark the bad release as a pre-release:
   `gh release edit vX.Y.Z --prerelease`. GitHub's "latest" then falls back
   to the previous release, and every reader of it (the Sparkle feed,
   `install.sh`, `benchbar self-update`, the app's update check) stops
   offering the bad one; the Windows installer and `benchbar.exe
   self-update` skip pre-releases too. Check with
   `gh release view --json tagName` that "latest" is the previous release;
   if not, `gh release edit vPREVIOUS --latest`. If GitHub refuses to edit
   the flag of a published release, `--latest` on the previous one is
   enough.
2. **The tap.** If its pull request is open, close it. If it is merged, revert
   that commit in `askysh/homebrew-tap` by pull request and merge it, so
   `brew upgrade` and a fresh `brew install` give the previous version again.
3. **Say so.** Edit the notes of the bad release (notes stay editable): a line
   at the top that names the problem and the version to use.
4. **Fix forward.** Sparkle only moves forward (the build number is the
   commit count), so installs that already updated stay on the bad build
   until a newer one is out; nothing can take them back. Fix on `next-release`,
   run `scripts/bump-version.sh X.Y.Z+1`, release as usual (a candidate if
   the fix is not tiny), and put the cause in the changelog.

### A key may have leaked

A run you did not approve, a lost laptop, a secret in a log. **Revoke
first, rotate after.** If a run is pending, reject its deployment (a rejected
run costs nothing). Everything below is set in GitHub, Settings,
Environments, `release`, Environment secrets, unless it says otherwise.

| Secret | Revoke | Replace |
|---|---|---|
| `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGN_IDENTITY` | developer.apple.com, Certificates, revoke the Developer ID Application certificate | make a new one (setup step 2), set all three; ship a release signed with it at once, since Apple may refuse what the old one signed |
| `NOTARY_API_KEY_P8`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER_ID` | App Store Connect, Integrations, revoke the key | a new key (setup step 3), set all three |
| `SPARKLE_ED_PRIVATE_KEY`, `SPARKLE_ED_PUBLIC_KEY` | none exists: installed apps trust the old public key until an update tells them otherwise | two releases: generate a new pair, set only `SPARKLE_ED_PUBLIC_KEY` to the new public key and ship a release still signed with the old private key (apps accept it and now carry the new key); once it is out, set `SPARKLE_ED_PRIVATE_KEY` to the new private key and ship the next |
| `HOMEBREW_TAP_TOKEN` | GitHub, Settings, Developer settings, delete the token | a new fine grained token (setup step 5); read the tap's recent commits, branches and pull requests for anything you did not make |
| `APPLE_TEAM_ID` | not secret | nothing |

If the Sparkle or Developer ID key was used by someone else, say so: open a
draft security advisory (the repository's Security tab, Advisories), list the
affected versions and the fix, and name it in the notes of the release that
rotates the key. Until a release carries the new Sparkle public key, check
the Releases page for files you did not upload.

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
`SHA256SUMS`, runs `gh attestation verify` on them and on `SHA256SUMS`
(a file without build provenance from `release.yml` stops the run; a run for a version below 0.9.0 skips this, with a notice), renders the formula and cask from `packaging/homebrew`
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
installs on Intel Macs too (not checked on real hardware) while the cask
is Apple silicon only.

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

### If someone else cuts the release

Every step above is in this page or in a workflow, but four things are
settings and accounts that a second person must be given first. Until the
maintainer does, only the maintainer can finish a release:

- **Repository admin**, to push the fast forward to `main` (step 6): the
  `main` ruleset lets only admins bypass it.
- **Required reviewer of the `release` environment** (Settings,
  Environments, `release`), to approve the signed build and the tap job.
  Today the list is the maintainer alone; add the second person.
- **The ten secrets.** Their values live outside GitHub, in the
  maintainer's password manager: the Developer ID certificate and its
  `.p12` password, the App Store Connect key (`.p8`, Key ID, Issuer ID),
  the Sparkle private key and the tap token. A second person cannot read
  them back from GitHub; they re-create the certificate and the notary key
  from the Apple Developer account (the Team ID is in "Membership
  details") and set them with the table under "Secrets". The Sparkle
  private key cannot be re-created (see "Rotating a key"), so keep a
  backup of it with a second holder.
- **Merge rights on `askysh/homebrew-tap`**, for the pull request of
  step 9.

`.github/CODEOWNERS` names the maintainer on the release code, so a
second reviewer's approval counts for it only once CODEOWNERS lists them.

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
4. **SHA256SUMS** with `shasum -a 256`, and the lines for `install.sh` and
   `install.ps1` of the tag, which `benchbar self-update` checks the
   installer against. `install.sh` checks the zip against it before
   unpacking.

### Build provenance (`attest` job in `release.yml`)

After `build-signed`, the `attest` job downloads the workflow artifact
that `release-draft` uploaded and attests the DMG, the app zip, the CLI
tarball and `SHA256SUMS` with `actions/attest-build-provenance`. It has
`id-token: write` and `attestations: write`, and no other job in the file
does; it reads no secret and has no environment. An ad hoc run never
attests (it is refused on a tag, and a draft needs a tag). `gh attestation
verify FILE -R askysh/benchbar` checks a download; `install.sh` and
`homebrew-tap.yml` do it before they trust a file. Publish after the
`attest` job is green: a tag release whose files carry no attestation
fails the tap run and makes `install.sh` refuse when `gh` is signed in.

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

## What is pinned, and how to move it

A release builds the same way a week later. Nothing it uses follows
"latest":

| What | Where it is pinned | How it moves |
|---|---|---|
| GitHub Actions | a commit sha and a version comment on every `uses:` | Dependabot, weekly, a week after the release |
| Swift packages (Sparkle, swift-subprocess) | `macos/Package.resolved`, copied into the generated project by `scripts/macos-packages.sh`; builds run with `-disableAutomaticPackageResolution` | Dependabot reads `macos/Package.swift` and updates both files; change the same range in `project.yml` or `sparkle.yml` if the range moves (`tests/test-supply-chain.sh` fails when they differ) |
| XcodeGen, shellcheck, actionlint, zizmor | version and sha256 in `scripts/ci-install-tool.sh` | by hand: change the version, the URL and the sum together |
| Xcode | `xcode-version: '26.6'` in `ci.yml`, `snapshots.yml` and the `release-prepare` action | by hand, together with the snapshot references |
| Go (the shim) | `go` in `windows/shim/go.mod`; govulncheck in `ci.yml` fails the job on a known vulnerability | by hand, for a supported release; `x/sys` through Dependabot |
| NuGet and the .NET SDK (the tray) | `Directory.Packages.props`, `global.json` | Dependabot |
| `bash:3.2.57` image of the CI tests | its digest in `ci.yml` | by hand |
| uv and fnm installers of the Linux install | version, URL and sha256 at the top of `00-linux-system-deps.sh` | by hand |

Two things stay outside, and why. `actions/setup-go`, `setup-dotnet` and
`setup-bun` download their toolchain by version and offer no way to give
them a checksum, so those three are trusted as far as the action is.
`apk add` in the bash 3.2 container and `brew install` in the Homebrew
workflows follow their distribution on purpose: the first one tests the
suite on current Alpine tools, the second tests Homebrew itself. The
workflows are checked by actionlint and zizmor in the `workflows` job of
`ci.yml`; what they accept is in `.github/actionlint.yaml` and
`.github/zizmor.yml`, each with its reason.

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

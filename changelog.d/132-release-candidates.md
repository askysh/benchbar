### Install

- A release can now have candidates, `vX.Y.Z-rc.N`: the same signed build, published as a GitHub pre-release. Sparkle, the app's update banner, `benchbar self-update`, the one line installers, Homebrew and the Windows update check never offer one. You get one only by naming it: `install.sh --version v0.9.0-rc.1`, `install.ps1 -Version 0.9.0-rc.1` or `benchbar.exe self-update --version 0.9.0-rc.1` (#132).

### For contributors

- A release now moves `main` to the head of `next-release` by a fast forward instead of a new squash commit, so `main` is the very commit CI passed and nothing is merged back. `auto-tag.yml` no longer pushes a branch, and a push to `main` that keeps an already tagged version fails when it changes more than docs (#132).
- One version source: `scripts/bump-version.sh X.Y.Z` sets the version in every place (benchbar, `macos/project.yml`, the bug report forms, the changelog heading and the tray fixtures), and `scripts/check-version.sh` is the one check that `auto-tag.yml`, `release.yml` and a new test run. The version pattern in the three release workflows is strict: `1.2.3 --draft` no longer passes (#132).

### For contributors

- Every GitHub Action is pinned to a full commit, with its version in a comment. The build tools (XcodeGen, shellcheck, actionlint, zizmor) are installed at a pinned version after a sha256 check, and the Homebrew caches are gone from the app and release jobs. Xcode is `26.6`, not "latest".
- The app's Swift packages are pinned by a committed `macos/Package.resolved`, which the build installs and checks, so a release never builds with a newer Sparkle than the one that was tested.
- Dependabot now covers Go (the Windows shim), NuGet and the .NET SDK (the tray), the Swift packages and the Actions inside `.github/actions`, waits a week after a release, and targets `next-release`.
- A `workflows` job runs actionlint and zizmor on `.github/` and fails on any finding. Every job has a timeout. The bash 3.2 test image is pinned by digest.
- The shim is built with Go 1.27.4 (1.23 no longer got security fixes), `golang.org/x/sys` is updated, and the `shim` job runs `govulncheck`.

### Linux and WSL

- The uv and fnm installers that `benchbar install` runs on Linux are pinned to a version and checked against a sha256 before they run, and downloaded over https only. A script that does not match is not run.

### Windows tray

- NuGet advisories (NU1901 to NU1904) show as warnings and no longer stop a build.

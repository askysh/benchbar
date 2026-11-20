### Command line

- `benchbar self-update` no longer pipes an unchecked install.sh into bash. It downloads install.sh of the release it installs, compares its sha256 with the release's `SHA256SUMS`, and only then runs it. A release whose sums do not list `install.sh` is refused. On a Mac it then checks the CLI out at the release's tag, because install.sh pins only the app, so the CLI and the app are the same version. `BENCHBAR_API` and `BENCHBAR_INSTALLER_URL` are read only by the tests, and the installer it runs does not inherit `BENCHBAR_API` or `BENCHBAR_REPO` from your shell (#134).

### benchbar.exe

- `benchbar.exe self-update` runs `install.ps1` of the release's tag instead of the one on `main`, and no longer with a piped download: it downloads the file, checks its SHA256 against the release's checksums, then runs the file. A changed file, a missing download or checksums that do not list `install.ps1` stop the update before anything runs (#134).
- `benchbar.exe self-update --version 0.8.x` says plainly that a release before 0.9.0 cannot be checked (its checksums do not list `install.ps1`), runs nothing, and prints the installer line to run yourself.
- The line that installs the CLI inside WSL (the wizard's CLI step, and the line `doctor` and `adopt` print) no longer pipes the installer into bash for a release build: it downloads the tag's `install.sh`, checks it against the release's `SHA256SUMS` and then runs it. It also has `--proto '=https' --tlsv1.2`.

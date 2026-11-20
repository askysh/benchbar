### Install

- Every Mac release file (the DMG, the app zip, the CLI tarball and `SHA256SUMS`) now has build provenance, like the Windows zips: `gh attestation verify FILE -R askysh/benchbar` says this repository's release workflow built it (#134).
- `install.sh` checks the app zip's provenance when `gh` is installed and signed in, and stops on a failure. Without `gh` it says that only the checksum was checked and prints the command to run by hand. It then runs `codesign --verify --deep --strict` and `spctl --assess` on the unpacked app, because `curl` sets no quarantine flag and macOS never checks what it downloaded. The app is copied next to the old one and renamed over it, so a failed copy leaves the old app as it was.
- `install.sh` runs everything from one function called on its last line, so a download that is cut short runs nothing. `--help` reads its text from the script, not from `$0`, so it works through a pipe. Every `curl` line in the scripts and docs has `--proto '=https' --tlsv1.2`. `--uninstall --yes` removes `BENCHBAR_HOME` only when it holds `benchbar` and `.git`.
- The Homebrew tap workflow verifies the tarball, the DMG and `SHA256SUMS` before it renders the formula.
- `SHA256SUMS` of a release lists `install.sh` and `install.ps1` of its tag.

- `install.sh` pins the signer of the attestation (this repository's release workflow) and gives each `gh` call 30 seconds, then says only the checksum was checked. A release older than 0.9.0 has no attestation (`gh` answers HTTP 404): `install.sh --version v0.8.3`, and an update from it, go on with the checksum alone; 0.9.0 and later still refuse. The running BenchBar is quit only after the signature checks passed.

### Windows installer

- `install.ps1` removes Windows' "downloaded from the internet" mark only when `gh attestation verify` accepts the zip. Without `gh` signed in, or when the check fails, the mark stays, the installer says so, and Windows asks once before it starts each program. A checksum from the same release was no reason to drop it.
- When the newest release has no Windows zip yet, `install.ps1` names the release it passed over and the one it installs instead, every time. It used to say so only with `-Version`.
- The release checksums file of the Windows zips has a line for `install.ps1` of the tag, and is attested with the zips.

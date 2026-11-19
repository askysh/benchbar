### Command line

- `benchbar uninstall-service --all` now offers to remove benchbar's block from `/etc/hosts` when you run it in a terminal (sudo, with a backup). With `--yes` or without a terminal it prints the command and never edits the file.
- On an Intel Mac, Homebrew's folders are looked up in `/usr/local` when `brew` is not on `PATH`, not only in `/opt/homebrew`, and the Intel warning in `install` says what that means.
- The one line installer skips the app, with a warning, on macOS 13 and older, where it would not open, and installs the CLI. A fish user gets the `fish_add_path` line to run, and a bash user on a Mac the line for `~/.bash_profile`.

### Docs

- The install guide has a supported platforms table (Intel Macs are written for but not verified, macOS 14 for the app, shells), and the Uninstall section lists what stays behind: the hosts block, apt packages, uv and fnm, and the app's login item. A check on a real Intel Mac is dropped from this release and stays on the roadmap.

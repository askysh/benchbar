### benchbar.exe

- `benchbar.exe` can run from a Microsoft Store (MSIX) package, the form the Store signs and installs with no security dialog. Nothing is published to the Store in 0.9.0, and nothing changes for an install from the one line installer. In a package `benchbar.exe` keeps its files in the package's own data folder (it reads an old `config.json` once), `benchbar` comes from the app execution alias, `path install` changes nothing, keepalive runs the alias so it survives updates, and `doctor` says when a second install from the one line installer is on the same PC.
- New: `benchbar.exe keepalive start` starts the keepalive task again when its run has ended, for example after an update. It never creates a task.
- `setup check --json` and `report-windows --json` have `packaged` and `data_dir`.

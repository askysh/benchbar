### Install

- On macOS, `install` no longer starts Homebrew's own Redis service, so `doctor` stops warning about Redis on port 6379 on a fresh install. Each bench runs its own Redis (#293).
- benchbar reads `brew services list` with colour off, so Homebrew's colour codes no longer hide a running MariaDB (#293).

### Docs

- AGENTS.md says that v16-lts is supported on Linux too (#293).

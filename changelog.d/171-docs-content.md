### Docs

- New [What's new](docs/whats-new.md) page for users: one section per release from 0.8.0, and the 0.9.0 upgrade notes (the bench listens on 127.0.0.1, unknown options are errors, `pull` neutralizes the copy, run `benchbar repair` once after you update).
- New [First run problems](docs/first-run-problems.md) page: the symptom, the cause, what 0.9.0 changed and the workaround for 0.8.x, for `uv` missing on a Mac, the MariaDB warning on Linux, no systemd user bus, a failed install step that exited with 0, and a dev server open to the network. The quick start has one block per system (macOS, Linux, Windows) with what you need, the install command and the site address, and Linux has one install recipe.
- New [Privacy](docs/privacy.md) page: what a page view and the three events send, how to opt out (a content blocker first, Do Not Track), and that the programs send no usage data. The docs site no longer sends the query string of a page.
- The Mac app (About pane, Help menu), the Windows tray's About window and the GitHub release notes link to the [What's new](docs/whats-new.md) page, not to `CHANGELOG.md`.
- Titles, descriptions and the social image say "macOS, Linux and Windows (WSL)", not macOS only. The README no longer repeats the release history, and the ROADMAP lists what 0.9.0 delivers and plans, and what it dropped: a Microsoft Store submission, a dedicated VM runner and a check on a real Intel Mac.
- SECURITY.md says what a report can break in sharing, Labs, Open as and the MCP tools that change things, and lists the guest identity in the Keychain.
- `docs/images/manifest.tsv` lists every image with the page that uses it, what makes it and its status.

### Docs

- The documentation site has a "Report a problem with this page" link in the footer. It opens a new "Docs problem" issue form with the page address filled in.
- Troubleshooting has a Known issues section for bugs a test pass found and a release has not fixed yet.
- The roadmap says plainly that Windows binaries stay unsigned (SignPath declined on 2026-11-13), lists what 0.9.0 dropped (the Microsoft Store submission, a runner VM, a check on a real Intel Mac) and gives each planned item its issue number.

### For contributors

- A squash merge title is a plain imperative sentence ending in the pull request number, with no AI trailers (CONTRIBUTING.md, AGENTS.md).
- The bug form asks for the platform (macOS, Linux or Windows beta), and `.claude/TASKS-*.md` working notes are ignored by git.
- docs/releasing.md says what a second person needs to cut a release and where a bug found by a test pass is written down.

# Roadmap

Where BenchBar goes. Versions below 1.0 may change the JSON API and the
runner format. 1.0 freezes both. Dates are not promised. Ideas are welcome
as issues.

## Released

This page does not repeat what shipped. Each release is described in
[What's new](https://benchbar.akashmishra.com/whats-new/) for users and in
the [CHANGELOG](CHANGELOG.md) for contributors. The
[Features](https://benchbar.akashmishra.com/features/) page lists every
feature with the version it came in.

## 0.9.0

0.9.0 is the release of the codebase review of 2026-11-18: every finding
fixed, plus the agent plan that was waiting for it. The list of issues is
the [0.9.0 milestone](https://github.com/askysh/benchbar/milestone/1).

**Delivered on `next-release`** (it ships with 0.9.0):

- The bench web server and socketio listen on 127.0.0.1, and `benchbar
  listen all` switches back.
- `benchbar pull` neutralizes the copy: integrations off, stored secrets
  cleared, `--keep-secrets` to keep them.
- Agents never see the MariaDB root password, a login link or a generated
  Administrator password.
- A fresh Mac without `uv` installs, and a rerun after a failed `bench init`
  recovers.
- Site backups are never pruned silently, and a backup is checked before a
  restore.
- `doctor` takes about 3 seconds, and `path`, `status` and `commands`
  start faster.
- The Mac app asks before it quits during a run, stops a whole process
  group on cancel, polls less, and has VoiceOver labels and snapshot tests.
- The Windows tray has a Labs page and `benchbar://` links.
- Linux has crash notifications, `v16-lts` and team profiles.
- Release keys live in a protected environment, CI is tiered, and the
  docs have a features page, a generated CLI reference and a what's new
  page.

**Planned in the milestone, not merged yet:**

- Unknown options are errors, install reports a failed step as a failure,
  and the Linux user bus is handled.
- MCP safety (labels on every path, plan and apply apart, an audit log) and
  more MCP tools.
- Agent contracts: a result envelope for every command, `benchbar wait`,
  operation handles for long jobs, `benchbar run` for bench commands, site
  snapshots and rollback, pinned and scratch benches with `bench gc`,
  leases, and `benchbar history --json`.
- Parity: restore, pull and lock in the Mac app, and the same actions in the
  Windows tray.
- Rooms on Linux with an nftables LAN guard.
- Verified downloads (attestations) and a Windows MSIX package.

**Dropped from 0.9.0**, because each needs hardware or a third party:

- Submitting BenchBar for Windows to the Microsoft Store.
- A dedicated virtual machine as a CI runner.
- A check of the CLI on a real Intel Mac.

Whatever code those findings name is still fixed.

## Later

**Management in its own target.** Team profiles, bench discovery and
port setup move out of the menu bar app into a separate management
target that runs only while it is open. The reason is scope: the menu
bar app should start, stop and show benches. Not energy: 0.6.1 brought
the app to under 0.1 percent of a core at rest with these in it.

**Agents, next.** The MCP tasks primitive (2025-11-25) as the home of
operation handles. Two measurements come first as well: a comparative
benchmark of native versus container benches (idle memory, build time,
file watch latency, startup) before the README keeps its performance
wording, and a four week pilot with about ten developers across three
teams.

**Windows past the beta.** Signed programs have no route in 0.9.0:
SignPath Foundation declined the project on 2026-11-13, and the
Microsoft Store submission (the MSIX package, PR 124) is dropped from
this release. The package code is landing in parts and CI builds it, but
nobody submits it. Until a signed route exists, Smart App Control users
run the command line inside WSL.

**1.0.** A stable JSON API and runner format, an official Homebrew cask,
full doctor coverage for v15 and v16. Vouch
([github.com/mitchellh/vouch](https://github.com/mitchellh/vouch)) when
drive-by PRs appear. Not before.

## Ideas

Not scheduled, kept because they came up more than once.

- Shortcuts actions, a Raycast extension, desktop widgets (the URL scheme
  shipped in 0.5.8).
- A local mail catcher for development email.
- Run one scheduler event now from the app.
- Worker restart when Python files change, opt in.
- More speed sources for the runner: job queue depth, requests per second.
- A runner gallery in the docs.
- Log rotation on a size limit without a manual `repair`.
- More failure path tests for bench creation and app installation.
- `benchbar wipe`, the uninstall recipe behind an explicit confirmation,
  never touching MariaDB data without a backup.

## Not planned

- **Docker or VMs.** A bench runs natively: Python, Node, MariaDB and
  Redis from Homebrew, the processes under launchd. File watching,
  `bench build` and debugging are faster than through a VM, there is no
  Docker Desktop license or memory overhead, and the setup matches what
  most Frappe developers run on Linux.
- **The Mac App Store.** App Store apps run in the App Sandbox, and a
  sandboxed app cannot run the CLI, start launchd agents or read a bench
  in your home folder. BenchBar ships as a signed, notarized download and
  a Homebrew cask instead.
- **Production deployment.** BenchBar is for development benches.

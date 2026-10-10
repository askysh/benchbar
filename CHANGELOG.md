# Changelog

All notable changes to this project are documented here.

## Unreleased

### Added

- Linux, Windows through WSL first: the same `benchbar` runs on Ubuntu
  24.04 (Debian based systems with apt), chosen at startup. Only the
  v15-lts profile so far; v16 on Linux comes later.
- `benchbar install` on Linux runs `00-linux-system-deps.sh`: MariaDB and
  Redis from apt, Python from uv, Node from fnm, the pinned wkhtmltopdf
  .deb (checksum verified, installed through apt), and
  `libnss-myhostname` so `*.localhost` resolves inside the machine. One
  sudo prompt up front, none on a second run. A fresh apt MariaDB gets a
  root password through `sudo mariadb`; the password lives in a 0600 file
  in the state folder (`benchbar mariadb-password --yes` prints it).
- Each bench runs as its own `systemd --user` unit with the same runner,
  crash guard, stop flag and status as on the Mac; `loginctl
  enable-linger` brings a running bench back after a reboot. `up`, `down`,
  `restart`, `status --json`, `doctor --json`, `repair`, `adopt`, `site
  add`, `site backup`, `logs`, the `bench*` helpers (in `~/.bashrc`) and
  `benchbar mcp` work on Linux.
- The default site on Linux is `linuxdev.localhost`; benchbar never edits
  `/etc/hosts` there. Doctor checks that the site name resolves instead,
  and leaves out the checks that only exist on a Mac.

### Fixed

- The shellcheck step of the test suite could never fail: it printed
  "shellcheck: ok" whatever shellcheck found.
- A NOPASSWD sudo rule next to a password rule no longer makes the install
  ask for a password it does not need.

## 0.7.3 - 2026-10-04

A fix pass from a full review: benchbar stops only what it can prove is a
bench's own, fails closed on every write, moves v15-lts to `node@22` before
Homebrew disables `node@20` on 2026-10-28, installs cleanly on a fresh
Homebrew MariaDB and next to other benches, and hardens the MCP server.
Run `benchbar repair` once after updating: the runner and the helper block
are rewritten.

### Fixed

- The runner's pre-start cleanup stops only listeners whose working
  folder is this bench; another bench's Redis or web server and any
  other program on the same ports are left alone. When such a process
  still holds a port, the runner pauses with the new stop reason
  `port_conflict` instead of starting honcho into ports it cannot bind
  (run `benchbar doctor`).
- `benchbar down` no longer signals a process whose working folder lsof
  cannot read; doctor's orphans check names such a process and says why
  it is not stopped, and `ports plan` counts it as a conflict, as `up`
  already did.
- `benchbar up` on a bench whose only live process is a leftover Redis
  (a site add cut short) no longer reports "already running": it starts
  the bench, and the runner clears that Redis first.
- `benchbar adopt`, `repair` and `service` on a bench running under
  `bench start` or `benchfg` leave its processes alone: the agent loads
  stopped and benchup takes over once that session ends.
- `benchbar site drop` never drops a bench's only site, also when
  `SITE_NAME` or `--site` names another site, and treats the site in
  `currentsite.txt` as the default too.
- The repair plan says when a MariaDB step restarts the server shared by
  every bench, and the restart names the running benches first.
- The MCP tools that change a bench (`benchbar_up`, `benchbar_down`,
  `benchbar_restart`, `benchbar_app_add`) refuse a folder that is not in
  `benchbar_list`.
- `benchbar fg` takes the CLI lock while it stops the background bench,
  so it cannot cut a running site add short, and refuses to start when
  the stop fails.
- A fresh Homebrew MariaDB (10.4 and newer) gives root a socket login and
  no password; `benchbar install` read that as "root already has a
  password" and stopped with exit 2. It now secures root through the
  macOS user's socket account, as the Homebrew install leaves it, and
  continues. A server that accepts neither login still stops and asks.
- Cancelling `benchbar install` at "Proceed?" (or running it without a
  terminal and without `--yes`) ends the run with exit 1 and "Cancelled.
  No bench or site was created"; it no longer reported the phase as done
  and loaded a launchd agent for a bench that was never created.
- `site add`, `site drop` and the install stop with "MariaDB is not
  running" when it is not, instead of blaming the root password.
- A stale `MARIADB_ROOT_PASSWORD` in the environment no longer makes the
  site step fail when the Keychain holds the working password: it is
  verified first and the Keychain is tried next, as phase 00 already did.
- `OFFLINE=1` and `BENCHBAR_OFFLINE=1` reach both phase scripts; before,
  they reset it and ran the remote branch checks anyway.
- `benchbar install` asks for sudo up front only for steps that will run:
  no prompt for the wkhtmltopdf package when Rosetta is missing and
  nothing can agree to install it, or when the package would be skipped.
- The message after a stopped install says what phase 00 did ("System
  dependencies were set up as far as possible; no bench or site was
  created") instead of "Nothing else changed".
- A command inside the run that fails with code 2 now ends the run with
  1, so exit 2 keeps meaning that phase 00 or 01 stopped for a manual
  step (most often the MariaDB root password).
- A launchd agent that is on launchd's disabled list (after `launchctl
  disable` or an old `launchctl remove`) is enabled before the bootstrap
  is retried, instead of failing three times.
- A bench whose Frappe no profile knows (develop, v17, v14) with no stored
  profile no longer falls back to `v15-lts` silently: doctor's and
  repair's header say the profile is only the default, the env checks say
  so and warn instead of offering a rebuild, and `repair` refuses
  to rebuild the env with a guessed Python. `benchbar install --profile
  NAME` sets the profile.
- `bench version` failures are classified before any fix is offered: a
  missing or broken `bench` command gets `uv tool install frappe-bench`
  (or the pipx equivalent), an app that does not import is named with
  `bench setup requirements --python`, and only a failure inside the env
  itself (frappe or a library that does not import) still leads to an env
  rebuild. None of the classified cases moves the env aside.
- `benchbar repair` refuses to rebuild the env while the bench is running
  (its processes run from that env) and says to stop it first.
- The installer checks that `bench` runs (`bench --version`) before using
  it, names the reinstall command for its owner when it does not, and
  warns when it is older than the profile's known minimum (`bench_min` in
  `config/release-profiles.tsv`).
- Long and timed commands (bench init, pip, yarn, git, brew) run in their
  own process group, and a timeout, a Ctrl+C or a TERM to benchbar stops
  the whole group before the run ends and the lock is released; before,
  only the top process was signalled and the rest kept writing into the
  bench. The MCP server does the same for a tool call that runs out of
  time, so a setup Redis never outlives it.
- A long command that stops to read the terminal it does not have (a
  password prompt inside `bench get-app` or `brew`) is ended with a clear
  message instead of waiting for ever behind the spinner.
- The run lock reclaims a stale lock by renaming it away, so several runs
  that find one at once leave exactly one holder, and a lock whose pid is
  not written yet is left alone for 5 seconds instead of being stolen.
- Every mutating run also takes the bench's own lock
  (`<bench>/.benchbar.lock`), so a Homebrew CLI, the app's CLI and a git
  checkout working on one bench exclude each other.
- `benchbar up` and `restart` release the locks once the agent is kicked,
  before the wait for the site, so other benches' commands are not refused
  for 45 seconds.
- Writers of a state file build the new file under a private temp name and
  a per file lock, so a status poll and a repair no longer lose each
  other's keys.
- `app focus` without an app name (the listing) takes no lock;
  `self-update` and `register` take it and write a run log.
- Log files and backup folders carry the run's pid in their name
  (`<date>-<time>-<pid>`), so two runs in the same second never share one.
- Every write helper fails closed: a backup, temp file, awk or rename
  that fails leaves the target untouched and the step is reported as
  failed, not done. A read only folder or a full disk no longer shows a
  green repair.
- The shell rc block is written into the real file behind a symlinked
  `~/.zshrc` (the link stays a link, the file keeps its mode), every stage
  is checked so a failed rewrite leaves the file byte-identical, and
  `$ZDOTDIR/.zshrc` is used when ZDOTDIR is set; the one line installer
  does the same for its PATH block.
- `benchbar repair` under `--yes` or without a terminal no longer reports
  the "stop Homebrew redis" question as done: a question nobody can
  answer is left out of the plan and listed as optional, so a second
  repair says `unchanged`. A declined hosts entry is `skipped`, and its
  fix adds the line inside the benchbar block.
- Large logs are rotated by copy and truncate, so the bench keeps writing
  to the live file (a rename took the writers along and left the live
  file empty), and at most three `.old` copies are kept.
- An interrupted `bench new-site` is remembered (a marker in the bench's
  `logs/.benchbar`); the next run names the incomplete site and how to
  move it aside instead of taking it for created.
- `benchbar lock apply` fails when a fresh clone cannot reach its pinned
  commit (it reported done), leaves that clone out of the build, and
  skips an app whose detached HEAD holds commits no branch has instead
  of orphaning them.
- `site drop` moves the default site only after `drop-site` succeeded; a
  failed drop leaves the default where it was.
- The runner treats honcho ending with code 0 without a stop request as a
  crash (a bench process ended, for example redis on a stray TERM), so
  launchd restarts it under the crash guard instead of leaving the bench
  silently down; and its crash guard fails closed when the start history
  or the stop flag cannot be written.
- The legacy agent migration and `uninstall-service` keep the plist when
  launchd does not let go of the job, and report a move that failed.
- A bench folder that cannot be written (read only) stops a run at once
  with "Could not create the lock ... (read only?)", instead of five
  retries that blamed another benchbar run.
- `benchbar logs --process worker` (and `file: worker` in the MCP
  `benchbar_logs_tail`) always returned no lines: `Procfile.lean` sends the worker to
  `logs/worker.log`, not to `bench.log`. It now reads that file
  (`--previous` with it is refused: there is no previous worker log).
- `--json` output removes a terminal color code as a whole; before, the
  escaping dropped only its ESC byte and left `[31m` in log lines and
  messages.
- An MCP action whose follow up status failed or hung lost the action's
  result; the result now comes back with `after_error`. Invalid UTF-8 on
  stdin no longer ends the server.
- The one line installer's state (default bench, port claims, per bench
  settings in `~/.local/share/benchbar/.benchbar`) now moves to
  `~/.local/state/benchbar` even when BenchBar.app made its
  `bin/benchbar` link there before the first CLI run; before, the new
  folder counted as moved and the old state was left behind. The move is
  serialized with an atomic guard, so first runs started at once (the
  app's polls) leave one state folder, a guard left by a killed run is
  reclaimed, and a run cut short at any step leaves a layout the next
  run completes (doctor's Second CLI check says so meanwhile).
- The helper block (`benchup` and friends) written by the app's CLI names
  Homebrew's or the installer's `benchbar` when one hands off to it, and
  the app's link only when nothing else is installed: the link goes with
  the app, that copy keeps running on its own.
- Doctor's Second CLI check under the app's CLI reports a second state
  folder in `~/.local/share/benchbar` next to the user state (never a
  delete: the Trash is offered) and a Homebrew or installer copy newer
  than the app's CLI, with the app update as the fix.
- `benchbar where` shows the version of the copy that handed off
  (`handoff_from_version` in the JSON) and the folder behind the state
  path when it is a link (`state_dir_real`, `state LINK -> REAL`).
- `install.sh --uninstall` keeps the checkout when
  `~/.local/state/benchbar` is a link into it (the state on another
  volume), and says to move the state first.
- Docs: `status`, `list` and `doctor --json` are read only except for the
  one time move of the state folder, which renames and links.
- `benchbar install` of a second bench while another bench or program
  holds the default ports picks the next free port block (or the one
  `--port-offset` names) and writes it before phase 01 starts the bench's
  Redis; it stopped with "Port 11000 ... is held by another process".
- A fresh v15 install puts `setuptools<70` into the new env, as repair
  does, so the first `benchbar doctor` no longer warns about
  `pkg_resources`.
- Doctor's stop flag check names the process that holds the bench's ports
  after a `port_conflict` pause, or says the ports are free now; it
  pointed at the orphans check, which only lists the bench's own
  processes.

### Changed

- The runner (template v7) and the helper block (v2) changed; `benchbar
  doctor` marks existing ones outdated once and `benchbar repair`
  re-renders them.
- `repair` says when a check still fails after the run and has no action of its own (a disabled formula, a missing tool); `doctor` exits 1 while it does.
- The default profile `v15-lts` installs `node@22` instead of `node@20`,
  which Homebrew disables on 2026-10-28 (Frappe v15 needs Node 18 or
  newer). A bench set up with `node@20` keeps working; `benchbar doctor`
  flags its shell block, agent, Node and the missing formula, and `benchbar repair` installs
  `node@22`, puts yarn under it and re-renders both PATHs. `node@20` is
  not removed.
- `benchbar install` does its two `sudo` steps (the wkhtmltopdf package,
  the `/etc/hosts` line) first and drops the credential with `sudo -k`
  before Homebrew, pip, npm, yarn or `bench get-app` run; it still asks
  once, up front. `00-mac-system-deps.sh` run on its own drops it right
  after the package step.
- The wkhtmltopdf package is copied into a root owned folder under `/tmp`,
  hashed there as root and installed from that copy, so the file that was
  verified is the file that is installed. `--dry-run` prints those steps.
- `MARIADB_ROOT_PASSWORD` and `ADMIN_PASSWORD` from the environment reach
  only `benchbar` and the two phase scripts; no other child process (brew,
  pip, npm, yarn, bench) sees them.
- `--yes`, `--make-default` and an approved port plan are flags only: a
  `FL_ASSUME_YES`, `FL_MAKE_DEFAULT` or `FL_PORT_PLAN_APPROVED` left in
  the environment no longer answers a question. `benchbar
  mariadb-password` without a terminal says that `--yes` is needed instead
  of printing the password.
- The Keychain item for the MariaDB root password is written through
  `security -i` (the password is never a command line argument) and names
  `/usr/bin/security` as its one trusted application. SECURITY.md says what
  that means and how to make every read ask.
- `benchbar report` also masks secrets that have no key in front of them:
  `user:password@` inside URLs (redis, git with a token), JWTs, GitHub,
  Slack, OpenAI and AWS token shapes, and email addresses (`<email>`);
  `pwd` and `passwd` keys and Python keyword arguments (`password='...'`)
  count as credential keys. `REDACTIONS.txt` lists each kind.
- `benchbar logs --json` redacts the lines with the report's rules and
  caps `-n` at 2000 lines, saying so with `"truncated_to":2000`.
  `benchbar_logs_tail` over MCP redacts the same way and refuses `lines`
  outside 1 to 2000. `benchbar logs` without `--json` is still the file as
  it is.
- A git URL with a token in it no longer reaches the run log, the "Last
  command failed" line, a failed command's last 40 lines or the echo of
  an env-provided answer: the `user:token@` part is written as `***@`.
- `adopt`, `install`, `service`, `repair`, `up`, `restart`, `autostart`,
  `ports apply`, `site add` and `site default` refuse a bench path (and a default site name) with a double quote,
  backslash, `$`, backtick, `<`, `>`, `&` or a control character before
  writing anything, and say which character is in the way; spaces and
  apostrophes stay fine. `doctor` stays read only and reports it as the new
  `bench_path` check. Template values are also escaped for bash and XML as
  a second guard.
- The `/etc/hosts` rewrite (a line inside benchbar's block, or removing
  one on `site drop`) happens on the root side: awk as root writes
  `/etc/hosts.benchbar.new` through `sudo tee`, the result is checked
  (every line an address and names, exactly one line more or fewer) and
  moved into place; anything else leaves the file untouched. A site folder
  whose name is not a valid site name is skipped with a warning and never
  reaches sudo.
- The state store (`state.env`, the per bench files) decodes its values
  without `eval`: a hand edited `KEY=$(...)` line is read as text, runs
  nothing and expands no glob.
- The MCP server runs every tool call on its own thread, so a status
  answers while an app add runs; actions run one at a time; a
  `notifications/cancelled` stops the running CLI and its process group
  (a cancel during the status that follows an action still returns the
  action's result, with `after_error`).
  Arguments are checked against the schema and a bad value is a tool
  error that names the rule. Log lines, git output, `hooks.py`, profile
  files and action output come back with a first line that labels them
  as data from the bench, not instructions, with terminal colors removed
  and a 200 kB cap (`BENCHBAR_MCP_MAX_BYTES`). `tools/list` and
  `tools/call` before `initialize` are refused (`-32002`). Each tool
  says whether it is read only, destructive, idempotent or reads the
  network, and the app add token is described as what it is: proof that
  the bench has not changed since the plan.
- `benchbar mcp` runs on `/usr/bin/python3 -I` when the Command Line
  Tools are installed, else `python3` from `PATH`, and refuses anything
  older than 3.9 with the versions it found; a GUI client's `PATH` no
  longer picks the interpreter.

### Added

- `benchbar doctor --json` says where the profile came from
  (`profile_source`), and the app's Health page says when the profile is
  only the default for a bench no profile matches.
- BenchBar.app knows the `port_conflict` stop reason: "Paused: a port is in
  use" with a link to Health, instead of "Paused after repeated crashes".
- New doctor check `env_setuptools`: on Frappe v15 the env must import
  `pkg_resources` (setuptools 70 and later dropped it); `repair` installs
  `setuptools<70` into the env, and an env rebuild on v15 does the same.
- New doctor check "Formula lifecycle": a WARN when Homebrew disables one
  of the profile's Python, Node or MariaDB formulae within 90 days, a
  FAIL once it has or once brew no longer knows the formula.
  `scripts/check-profile-formulae.sh` runs the same
  check over every profile and stops a release in `release-local.sh`.
- `benchbar install --offline` skips the remote checks of both phase
  scripts.
- `benchbar mcp` has a read only `benchbar_app_list` tool (`app list
  --json --no-sites`), and `benchbar_logs_tail` takes `file`: `bench`,
  `worker` (`logs/worker.log`), `worker_error` or `previous`.
- `benchbar site list --json` carries each site's `db_name` and the
  MariaDB `db_port` (never the password).

## 0.7.2 - 2026-10-02

The BenchBar window has one main action per page and one layout for
every sheet. Nothing was removed and the CLI is unchanged.

### Changed

- The BenchBar window is calmer: each page has one main action, actions
  used less often moved into a ⋯ menu (none were removed), and every
  sheet has the same layout, button order and keys (Return confirms, Esc
  cancels). Removing a custom runner now asks first.
- Docs: refreshed for 0.7.1 and 0.7.2.

## 0.7.1 - 2026-10-02

BenchBar.app carries its own copy of the CLI, and updating the app
updates both. Homebrew and the one line installer stay; their `benchbar`
hands off to the app's when the app is installed.

### Changed

- The app has the `benchbar` CLI inside it, the same version as the app,
  and runs it. At launch, an app in `/Applications` or `~/Applications`
  links `~/.local/state/benchbar/bin/benchbar` to it, and Homebrew's and
  the one line installer's `benchbar` hand off to that link: every
  `benchbar` on the Mac is the app's version, and an app updated by
  Sparkle no longer leaves an older CLI behind. A git checkout never
  hands off, and `BENCHBAR_NO_HANDOFF=1` runs a copy as it is. Without
  the app (or with it in the Trash) each copy runs itself, as before.
- Update Now asks Sparkle, which replaces the app and its CLI where they
  are, the cask's app included; nothing runs in Terminal and BenchBar
  does not quit for it. `brew upgrade` still updates the cask's app when
  Sparkle has not, and leaves it alone when Sparkle has. Copy Command
  offers `brew upgrade askysh/tap/benchbar-app` for the cask's app. A
  build without Sparkle opens the release page.
- `brew upgrade askysh/tap/benchbar-app` replaces `brew upgrade --cask
  --greedy ...` everywhere: naming the cask is enough.
- `benchbar where` shows the new install kind `app`, the app the CLI is
  part of and the CLI it was handed off from (`handoff_from` in the
  JSON). `benchbar self-update` from the app's CLI runs `brew upgrade
  askysh/tap/benchbar-app` for the cask's app and otherwise points at
  Check for Updates.
- Doctor's "Second CLI" check knows the app's CLI: copies that hand off
  to it are fine, and one too old to hand off is named with the command
  that updates it. A helper block that names Homebrew's or the
  installer's `benchbar` stays as it is when that copy hands off.

### Fixed

- A compiled `mcp.py` (`__pycache__`) was committed by mistake and
  shipped in the Homebrew tarball.

## 0.7.0 - 2026-10-02

BenchBar installs with Homebrew: `brew install askysh/tap/benchbar
askysh/tap/benchbar-app` puts the CLI and the menu bar app on the Mac,
`brew upgrade askysh/tap/benchbar` updates the CLI and the app updates
itself. The CLI no longer keeps its state in the folder it is installed
in, every path it records stays valid across `brew upgrade` and `brew
cleanup`, and the CLI, the app, the one line installer and doctor know a
Homebrew install when they see one. `benchbar repair` moves a one line
install over to Homebrew. The one line installer stays as the
alternative.

### Changed

- The CLI's state (the remembered benches, per bench settings, run logs,
  file backups and the lock) moves out of the install folder for the one
  line installer, to `~/.local/state/benchbar`, the same path for the
  terminal, BenchBar.app and MCP clients whatever `XDG_STATE_HOME` says.
  The first run moves `~/.local/share/benchbar/.benchbar` there in one
  step and leaves a symlink, so an older copy of the CLI keeps the same
  benches; a later run makes that symlink again if it is gone. While
  another run holds that folder's lock, the move waits for a later run.
  When the two folders are on different volumes nothing is copied: the
  state stays and the new path leads to it. A git checkout keeps its
  `.benchbar` folder.
- A new CLI version alone no longer makes doctor report every bench's
  runner as outdated. The runner keeps the version that wrote it in
  `state.json`. Runners written by 0.6.1 are outdated once: `benchbar
  repair` or `benchbar service` rewrites them.
- `benchbar report` names how the CLI was installed and its state folder.
- With Homebrew's benchbar installed, the `~/.local/bin` links are
  optional: doctor's "benchbar on PATH" passes without them and `benchbar
  repair` makes none. Under Homebrew a link that leads elsewhere (the one
  line installer's copy, a Cellar folder) comes before brew's on PATH:
  repair points it at the Homebrew CLI and keeps the old link in its
  backups. A link to Homebrew's benchbar now counts as current for every
  copy of the CLI, so another copy's repair no longer points it back.
- Doctor fails "Shell helpers" when the benchbar the helper block runs is
  gone (a Cellar folder after `brew cleanup`, a checkout moved to the
  Trash): every helper would fail. `benchbar repair` rewrites the block.
- `install.sh --uninstall` says where the logs, backups and remembered
  benches are now and keeps that folder. With Homebrew's benchbar
  installed but not yet run, it first moves the checkout's state to
  `~/.local/state/benchbar` instead of deleting it with the checkout.
- Doctor's "Second CLI" no longer suggests the Trash for the one line
  installer's folder while that folder still holds the state, and for a
  git checkout it no longer says Homebrew's CLI takes over, since that
  CLI never reads the checkout's state. Under Homebrew, `benchbar repair`
  leaves a `~/.local/bin` link or helper block that runs such a checkout.
- `benchbar uninstall-service --all` removes the helper block even when
  every agent belongs to a folder that is no bench any more.
- BenchBar.app looks for Homebrew's benchbar first: `/opt/homebrew/bin`,
  then `/usr/local/bin` when that is Homebrew's benchbar too, then
  `~/.local/bin`. A path chosen in Settings still comes first. A chosen
  path inside a Cellar folder is kept as `<prefix>/opt/benchbar/bin/benchbar`,
  and one that is gone (after `brew cleanup`, or a moved checkout) falls
  back to Automatic instead of an error.
- The app's Update Now and Copy Command follow how BenchBar was
  installed. Homebrew's CLI is updated with `brew upgrade
  askysh/tap/benchbar`. An app from the `benchbar-app` cask is never
  replaced by the one line installer: Sparkle updates it in a build that
  has Sparkle, otherwise `brew upgrade --cask --greedy
  askysh/tap/benchbar-app` runs; the installer's CLI next to it is
  updated with `--no-app`. When Sparkle has the app, BenchBar stays open
  and Sparkle offers the new version.
- Where the app finds no CLI, it says to install one with `brew install
  askysh/tap/benchbar`, with the one line installer as the alternative,
  and has a button that copies the brew command.

### Added

- benchbar recognizes a Homebrew install (`<prefix>/opt/benchbar` or
  `<prefix>/Cellar/benchbar/<version>`) and keeps its state in
  `~/.local/state/benchbar`. The shell helpers, the `~/.local/bin` links,
  doctor's fix commands, the report and the MCP server then name
  `<prefix>/opt/benchbar/bin/benchbar`, which survives `brew upgrade` and
  `brew cleanup`, never a versioned Cellar path.
- `benchbar self-update` on a Homebrew install runs `brew upgrade
  askysh/tap/benchbar` after asking, never the one line installer; the
  app updates itself or comes from the cask, and a note says which. The
  JSON keeps its fields, with `install: "homebrew"`.
- `benchbar where [--json]`: how the CLI was installed (`homebrew`,
  `managed`, `checkout`, `other`), the path it records for itself, its
  state folder and the BenchBar app.
- `benchbar uninstall-service --all`: the background service of every
  bench that has a benchbar agent, after one question. Run it before
  `brew uninstall benchbar`, which cannot stop the agents.
- Two doctor warnings without a repair action: "Second CLI" when the one
  line installer's CLI and Homebrew's are both on the Mac, and
  "BenchBar.app copies" when `/Applications` and `~/Applications` both
  have the app. Nothing is deleted for you; the fix line says what to
  move to the Trash.
- The one line installer leaves to Homebrew what Homebrew installed: with
  the `benchbar` formula it skips the CLI, with the `benchbar-app` cask
  the app, and prints the brew command instead; when nothing is left it
  exits 0. An older app's Update Now fetches the newest installer, so it
  gets this too and never puts a second copy next to brew's.
- The About pane says when the command line tool is two or more minor
  versions older than the app, with the command that updates it (`brew
  upgrade askysh/tap/benchbar` for Homebrew's, `benchbar self-update`
  otherwise) and a Copy button. One minor version behind is normal while
  Homebrew catches up with a release, so it shows nothing.

- Every release has `benchbar-cli-<version>.tar.gz`, the CLI the
  Homebrew formula installs, listed in `SHA256SUMS`. Publishing a release
  updates `askysh/homebrew-tap`: the `benchbar` formula always, the
  `benchbar-app` cask for a signed release, after both were installed and
  tested. Install with `brew install askysh/tap/benchbar
  askysh/tap/benchbar-app`.

### Fixed

- The one line installer no longer fails on a clean checkout that is on
  a detached HEAD: it switches back to main, then pulls. A checkout with
  uncommitted changes still stops with the same message.

## 0.6.1 - 2026-10-01

The first signed and notarized release: the app, the zip and the DMG are
signed with a Developer ID, notarized by Apple and stapled, so the DMG
opens without the Privacy & Security trip, and the app updates itself
with Sparkle from this release on.

Cost at rest. macOS flagged BenchBar for significant energy: it ran
`benchbar status --json` for every bench every 30 seconds (every 5 once
a bench Overview had been shown), and each call started about 212
programs. Ten minutes at rest on an M4, window closed, one bench
running and one stopped, BenchBar plus the processes it starts:

| | BenchBar | its children | total |
|---|---|---|---|
| 0.6.0 | 0.12 % | 6.05 % | 6.16 % |
| 0.6.1 | 0.06 % | 0.04 % | 0.10 % |

### Changed

- `benchbar status --json` starts 5 programs instead of 212 (0.03 s of
  CPU instead of 0.86), `list --json` 4 instead of 119, with the same
  JSON. No brew, pipx or template renders, one `launchctl print`, and
  the default site is pinged once, only while the bench runs.
- `status` and `list` leave `sites[].ping_code` null; `status --ping`
  asks every site once. `site list --json` still pings each site.
- The app polls on events, not on a clock: it reads the bench's
  `logs/.benchbar` files and asks the CLI on launch, wake, after an
  action, when the popover or window opens, and in a safety check every
  5 minutes. A bench whose runner predates the heartbeat is asked once
  a minute.
- The CPU charts and the runner's speed share one sampler and stop
  while idle, in Low Power Mode, or with the menu bar hidden. The
  stopped and unknown poses play three loops, then hold still; running
  is capped at 30 frames per second.
- Doctor and app list results are kept per bench while the window is
  open; Refresh and every action ask again.
- CLI queries run at utility quality of service.

### Added

- The runner writes a heartbeat (`logs/.benchbar/heartbeat`) every 30
  seconds while the bench runs, and doctor has a "Runner heartbeat"
  check: `benchbar service` writes the new runner, `benchbar restart`
  starts it.
- The app logs every CLI call and every change of polling mode at info
  level, subsystem `com.akashmishra.benchbar`.

### Fixed

- The 5 second poll of a bench Overview kept running after the window
  was closed, until the app quit.
- Changing the poll interval cancelled a status call in flight, which
  showed a "timed out" banner.
- Leaving the Health or Apps page no longer stops a doctor or app list
  call midway.
- Resolve & Start now starts the bench like the Start button: the
  state, the site ping and the refresh follow.
- The log view no longer writes its model while drawing, and reads new
  lines in one batch.

## 0.6.0 - 2026-09-29

### Added

- Update Now: the app checks GitHub for a newer release once a day (on
  launch and wake; turn it off in General with Check for updates
  automatically) and offers Update to X in the popover and the menu bar
  menu, and a banner in the window. Update Now opens Terminal with the
  one line installer, quits BenchBar while it is replaced and opens it
  again; Copy Command and Release Notes are next to it. A benchbar that
  is a git checkout of your own gets `--app-only` and a `git pull` hint.
- `benchbar self-update`: the same update from the CLI, after asking
  (`--check`, `--json`, `--dry-run`). It never touches a bench and never
  runs `bench update`.
- Release notes start with an Update section and the command, for
  anyone on 0.5.x who opens the release page from Check for Updates.
- App, Team Profiles: Import (a `.toml` file, an https link, or a file
  dropped on the page) and Subscribe (a team's git repository of
  profiles), each reviewed before anything is written. Every row says
  where the profile comes from, shows "Outdated" when its subscription is
  behind and warns when another file with the same name hides it.
- App: a profile's ⋯ menu has Export (the branch per app, which apps to
  share, blocked when a kept app requires a dropped one, then Copy Import
  Link), Update (the diff first), Check Access, Show in Finder and Remove
  (asks first, moves the file aside).
- `benchbar://profile/import?url=` and `benchbar://profile/subscribe?url=`
  open Team Profiles with the sheet filled in; nothing happens until you
  click.
- Dependency freshness: doctor warns (`dependency_behind`) when an app
  that one of your focus apps needs, directly or through another app, is
  behind its remote branch, for example "exponent_custom_v1 (needed by
  exponent_ecr) is 30 commits / 12 days behind upstream/develop", with
  `benchbar app update NAME` as the fix. A focus app itself never gets
  the warning, and the other apps get one summary line (`apps_behind`).
  Focus apps are inferred (local changes, another branch than the
  profile's, a commit of yours in the last 14 days) and can be pinned
  with `benchbar app focus NAME`, `benchbar app unfocus NAME` and
  `benchbar app focus NAME --auto`; `benchbar app focus` lists them.
  Doctor stays read only: it reads the remotes as git last fetched them
  and says how old that is, and `benchbar doctor --fetch` (or `app focus
  --fetch`) fetches the dependencies first.
- The Apps page shows which apps are focus apps and why, how far a
  dependency is behind, a Check Remotes button that fetches the
  dependencies, and a menu to set each app to Auto, Focus or
  Ignore.
- Share team profiles. `benchbar profile export NAME` writes a copy for
  teammates: SSH aliases resolved to real hosts, each repo's default
  branch, and per app its access (`public`, `private`, `personal`) and
  the apps it requires, after a review you confirm (`--branch APP=BR`,
  `--drop APP`, `--plan`).
- `benchbar profile import FILE|URL` adds a profile someone sent (https
  only, 64 KB at most, GitHub file and gist pages fetched raw), shows the
  diff when the name exists, and checks which repos you can read.
- `benchbar profile subscribe GIT_URL` clones a team's config repo; its
  profiles join the lookup path after your own. `profile update NAME|--all`
  fetches again, shows the diff and asks; `profile remove NAME` moves an
  import or a subscription aside.
- `benchbar profile check NAME` asks git, with your own credentials,
  whether every repo of a profile can be read.
- `install --profile` leaves out the apps whose repos cannot be read,
  and every app that requires one, and lists them.
- Doctor warns with `profile_outdated` when the bench's team profile
  comes from a subscription that is behind, as of the last fetch
  (`doctor --fetch` checks the remote first).
- MCP read tools `benchbar_profile_list` and `benchbar_profile_check`.
- Team profile schema 2: `source`, `exported_from`, and per app `access`
  and `requires`. Schema 1 files keep working.
- `benchbar app add NAME|URL --dry-run --json`: the plan of an app add
  with an approval token, read only: the repo and branch, whether git can
  read it, the sites, the required apps from `hooks.py` (read from a
  shallow clone in a temp folder) and whether each resolves, and the
  steps. `--apply TOKEN --yes` runs exactly that plan, required apps
  included, without a question, and refuses a token the bench no longer
  matches.
- `benchbar mcp`: `benchbar_app_add_plan` and `benchbar_app_add`, so a
  coding agent can add an app from a pasted git URL after showing you the
  plan. Repairs and bench installs are still not tools.

### Changed

- `install.sh --yes` on a Mac that already has the CLI is an update: it
  no longer adopts a bench it finds or starts the Homebrew installer.
- `profile list --json`: `source` has two new values, `imported` and
  `subscribed`. New fields `source_url` (the URL an import or
  subscription came from, or null), `subscription`, `shadowed_by` and
  `schema`.
- `benchbar down` stops a listener on the bench's ports only when its
  folder is inside the bench; one whose folder cannot be read is left
  alone.
- Plans are bound to what they showed: an `app add` token covers the
  commit of every repo it clones, and `profile import` and `profile
  update` plans carry a `digest` that `--expect` checks (export too). The
  app passes it, so a profile that changes after Review is refused, not
  applied.
- Update Now and `benchbar self-update` install the release they
  offered: the installer comes from that release's tag with
  `--version`, not from `main`.
- A profile import or update review also covers the local file it
  replaces: an edit made after the review makes it stale.

### Fixed

- `app add --branch TAG` no longer reports a failure after a good
  install: git checks a tag out detached, so the check is the tag's
  commit, and planning the app again is not refused.
- A team profile that lists the same app twice is refused with a clear
  error; the app's Export sheet crashed on it.
- `app add` plans follow the requirements of a required app that is
  already in the bench, so an app it needs that is missing is planned too.
- Dependency freshness read `required_apps` only when an app's folder
  and package had the same name, so a folder like `apps/Raven` lost its
  dependencies. A `doctor --fetch` where some fetches failed also
  marked the answer as fresh; now it keeps the last full fetch time.
- `benchbar scan ~` and Find Benches skipped every folder named `dev`,
  so benches in `~/dev` were not found; only the system `/dev` is skipped
  now.
- `benchbar down` stopped every process listening on the bench's ports,
  also another bench's or an unrelated server's; it now stops only
  listeners that run inside the bench folder.
- Troubleshooting, Wiping a bench: what is lost comes before any
  command, and the databases are dropped while the bench folder still
  names them.
- App: Create from Bench accepts profile names with `_`, as the CLI does.

## 0.5.8 - 2026-09-29

Quick wins, and port blocks across benches. Links for Raycast and
Shortcuts drive a bench without the menu bar, each bench's page charts
its CPU and memory and says whether it matches its lockfile, and a site
can be backed up or dropped (with a backup first and its name typed
again) from the CLI and the app. VS Code or Cursor, a console and the
site's database are one click away, and `doctor --fix-hints` gives agents
just the commands. Setup plans port blocks for several benches at once
and refuses a start that would take another bench's ports. The installer
no longer ends silently without a terminal, and an emptied bench's agent
can be removed.

### Added

- `benchbar://` links for Raycast, Shortcuts and scripts: `up`, `down`,
  `restart`, `open`, `logs`, `window`, `doctor`, `console`, `db` and
  `editor`, with `bench=` (a name or a path) and `site=`. Links only
  start, stop and open things; any other route is ignored and logged. See
  the URL scheme reference page.
- `benchbar doctor --fix-hints`: only the fix commands of failing and
  warning checks, one per line, for coding agents and scripts. The exit
  code is doctor's.
- `benchbar console` and `benchbar db` (both take `--site`): bench's
  Python console and the site's MariaDB shell with the site's own user.
  In the app, Open in VS Code or Cursor (chosen in Settings), Console and
  Database on the bench page and in each site's menu, and the
  `benchbar://console`, `db` and `editor` links.
- `benchbar site backup NAME [--with-files]`, `site backups NAME` and
  `site drop NAME --confirm-site NAME`: bench's own backup, a list of a
  site's backups, and dropping a site with a backup first. Drop refuses
  without the site name typed again, and the default site needs
  `--new-default`; it removes the site's hosts line with one `sudo`
  prompt. In the app, the Sites tab backs up a site and drops it behind a
  sheet with the plan and a typed confirmation.
- The Overview tab of a bench with a lockfile shows "In sync" or "N
  differences" with the list, from `benchbar lock check --json`, on open
  and with Check Again.
- CPU and memory per bench: the Overview tab charts the last ten minutes
  while the bench runs, and the popover shows the current values. Measured
  with the same process tree walk as the runner speed, in memory only.
- Batch setup preview with stable port allocations, Automatic/Fixed modes, and
  explicit Resolve & Start. Current allocations reserve ports while stopped; stale automatic reservations
  are ignored after an external configuration change.
- `ports setup` previews ports and service changes, then asks before applying.
  `ports plan --json` and token-based `ports apply` support integrations;
  `ports check` and `ports mode` expose checks and policy. Stale previews are
  rejected before applying changes.

### Changed

- Keep the menu-bar popover compact with a bench picker, native setup actions,
  contextual site actions, and a health summary. The popover is only as tall as
  its content, lists sites that need a hosts line before the rest in natural
  name order, keeps the `site hosts` command one Copy away, and shows the first
  checks that need attention with Copy Fix, Repair and Check Again. Full
  diagnostics and expandable Terminal instructions live in the management window.
- Start, restart, and foreground start refuse running owners and unrelated
  listeners before changing process state. CLI users can confirm a stopped
  bench overlap to run one bench at a time; the app offers Resolve & Start.
  Starting an already-running bench remains a successful no-op.

### Fixed

- `benchbar install` without a terminal (run by a coding agent, or piped)
  no longer ends silently: questions with a default take the default and
  say so, and a password it cannot ask for stops with a message and the
  fix (`ADMIN_PASSWORD='...' benchbar install`, or run it in a terminal).
- `benchbar uninstall-service --bench-dir PATH` removes the agent of a
  bench folder that was emptied or deleted, instead of refusing with "No
  bench at PATH". Such an agent restarted every 20 seconds, exited with
  code 127 and grew the log. Doctor has a new check, `dead_agents`, that
  warns about any loaded benchbar agent whose runner script is missing.
- `benchbar install --port-offset N --dry-run` for a new bench shows the
  ports it will get (web 8000+N): no port clash with the benches on 8000,
  and the "Open" address uses the right port.
- The service pass of `benchbar install` checks the MariaDB the install
  chose (a running server inside the profile's range, for example
  mariadb@10.11 for v16) instead of failing on the profile's default
  formula when the bench has no saved state yet, as in a dry run.
- `benchbar install` ends with one Summary table, of its three steps; the
  service pass no longer prints a second one of its own actions.

## 0.5.7 - 2026-09-27

BenchBar finds benches that live outside the usual places. Scan Folder
searches a folder you choose, Find Benches lists what it found with full
paths, and Add Selected remembers them. Setting up the service stays a
separate step that shows the adopt plan first and refuses a running
bench. Nothing is started or changed by a scan.

### Added

- Scan Folder in the menu bar and Find Benches in the app: recursively find
  existing benches, select paths to remember, and preview management setup.
- Read-only `benchbar scan PATH --json` and persistent `benchbar register PATH ...`
  commands, with duplicate detection and warnings for unreadable folders.

### Fixed

- Same-named benches receive distinct service labels when needed, and port
  reservations recognize those labels by their working-directory ownership.
- Folder discovery preserves `/` when resolving a filesystem-root selection.
- The scan stops six folders deep, skips macOS system and media folders
  (Library, Applications, Pictures, Music, Movies, Volumes, System) and
  warns about folders that macOS privacy settings block.
- Service labels no longer rebuild the list of known benches on every
  lookup, so `list` stays fast with many remembered benches.

## 0.5.6 - 2026-09-26

Doctor knows the cleanup tool that actually deletes benches. Mole's
`mo purge` removes `env/`, `node_modules` and `dist` from projects under
`~/dev`; doctor now warns about it until the bench is in Mole's
whitelist, finds CleanMyMac when Setapp installed it, and stops flagging
the installer's own PATH block.

### Added

- Doctor check `mole`: warns when Mole is installed (as `mole`, or as a
  `mo` that is Mole's script) and the bench is not in
  `~/.config/mole/whitelist`, and passes once a plain path there is the
  bench or a folder above it, the rule Mole itself uses. When the file
  does not exist yet, the fix says to save it once with
  `mo clean --whitelist`, since a whitelist file replaces Mole's built in
  entries.

### Fixed

- The `cleanmymac` check also looks in the `Setapp` folder inside
  `/Applications` and `~/Applications`, where the Setapp copy lives.
- Doctor no longer lists the installer's `benchbar-path` block in
  `~/.zshrc` as an old block to delete by hand; removing it would take
  `benchbar` off PATH.
- `install.sh` and `scripts/macos-install-local.sh` touch BenchBar.app
  after copying it, so Finder shows the new icon after an upgrade.

## 0.5.5 - 2026-09-26

The project skin: BenchBar gets a manual, a front door and a way to
reach you. The documentation moves to its own site,
benchbar.akashmishra.com, built from `docs/` with search and a page per
command; the README becomes a short front door; the repository gets the
files a project people contribute to needs; and the app gets an About
pane with an update check, a Help menu and Report a Bug.

### App

- **About pane**: the app's version and build, the command line tool's
  version and path (from `benchbar --version`), links to the docs, the
  release notes and the source, the license line and the trademark note.
- **Check for Updates** in the About pane and the app menu: one request
  to GitHub's latest release, only when you click, with "up to date" or
  "0.6.0 available" and a button to the release page. Nothing is
  downloaded.
- **Help menu**: BenchBar Documentation (⌘?), Keyboard Shortcuts, Release
  Notes and Report a Bug. The status item's right click menu has About
  and Documentation.
- **Report a Bug**: a sheet explains what the zip holds (no secrets, no
  personal paths, no names), runs `benchbar report --json`, shows the zip
  in Finder and opens a new issue with the macOS and BenchBar versions
  filled in.
- With no bench yet, the popover points at the Install guide, and its
  hint says `benchbar adopt <path>` for a bench you already have.
- About BenchBar in the menus opens the About pane instead of the bare
  standard panel.

### Command line

- `benchbar docs [TOPIC]` opens the documentation site or a topic's page
  (install, quick-start, app, sites, apps, doctor, teams, agents, mcp,
  cli, json, runners, troubleshooting, config ...); `--print` prints the
  URL; `benchbar docs --help` lists the topics.
- `benchbar --help` ends with the docs URL.
- `benchbar doctor` prints a `see:` line with the check's section of the
  doctor guide under every `[FAIL]` (after its `fix:` line). The
  `[OK]`, `[WARN]`, `[FAIL]` and `fix:` lines and `--json` are unchanged.
- `benchbar --version` adds the installed BenchBar app's version on a
  second line; the first line is unchanged.
- `benchbar report --json` prints `{"schema_version":1,"cli_version":..,"zip":PATH,"redactions":N}`
  for the app and scripts (docs/json-schema.md).

### Repo

- `CONTRIBUTING.md`: the tests, bash 3.2 and shellcheck, idempotency,
  what a pull request needs (small, CHANGELOG, DECISIONS, tested on) and
  the AI policy. README's Contributing section now points to it.
- `CODE_OF_CONDUCT.md` (Contributor Covenant 3.0) and `SECURITY.md`
  (private vulnerability reports, what counts, latest release supported).
- Issue forms for bugs (macOS, version, install method, profile, the
  `benchbar report` zip, doctor output) and features, blank issues off
  with a link to Discussions Q&A, a pull request template with an AI
  disclosure line, `CODEOWNERS`, Dependabot for Actions and Swift, and a
  commented out `FUNDING.yml`.
- `docs/images/social-preview.png` and `docs/images/og-image.png`, drawn
  by `scripts/social-preview.swift` from the icon, the light popover and
  the runner frames.
- ROADMAP: Vouch under 1.0, once drive-by pull requests appear.

- The Code of Conduct and the security policy give
  mail@akashmishra.com for people who cannot use GitHub.

### Docs

- **A docs site** at <https://benchbar.akashmishra.com>: Astro Starlight
  in `site/`, built with Bun from the markdown in `docs/`, with search,
  dark mode that follows the system, an edit link and the last updated
  date on every page. Start (Introduction, Install, Quick start, The menu
  bar app), Guides (Benches and sites, Apps, Doctor and repair, Teams,
  Coding agents and MCP), a CLI reference with one page per command group
  (flags, exit codes, an example each), Configuration, and the existing
  JSON schema, Runners, Troubleshooting, Decisions, Releasing and Testing
  pages. `ROADMAP.md` and `CONTRIBUTING.md` stay at the repo root and
  appear as `/roadmap/` and `/contributing/`.
- Every paragraph of the old README now lives in `docs/`, rewritten into
  those pages.
- `docs/guides/doctor-and-repair.md` has a `### <check_id>` heading for
  every doctor check, with what it checks and its fix, so
  `/guides/doctor-and-repair/#<check_id>` links land on the right check.
- Every markdown file in `docs/` has `title` and `description`
  frontmatter; the duplicate `# ` headings are gone.
- `.github/workflows/docs.yml` builds the site and checks its links on
  every pull request, and deploys it to GitHub Pages on a push to `main`
  that changed the docs. `tests/test-docs.sh` checks that every doctor
  check id has its heading, that every flag in the CLI reference exists in
  `benchbar --help`, and that every page has its frontmatter.
- CI skips the CLI and app jobs when a change touches only `docs/` or
  `site/`.

- The command reference documents `benchbar docs`, `--version` and
  `report --json`; troubleshooting says how to turn the scheduler on.

### Readme

- README rewritten as the front door: logo and popover in light and dark,
  why, install, quick start, eight features and links into the new
  documentation site, about 800 words instead of 3,200. Everything it no
  longer says lives in the docs.

## 0.5.0 - 2026-09-26

BenchBar grows from a start and stop button into the place you run your
benches from: a window with every bench's sites, apps and health, Repair
from the app, a log window, apps from any GitHub repository (private
ones too), team profiles and a lockfile for the whole team, `benchbar
pull` for a production copy, and `benchbar mcp` for coding agents. A new
app icon, and the window uses the macOS 27 tab style and Liquid Glass
buttons (older macOS versions get the classic look).

### Added: the app

- **The BenchBar window** replaces the sparse Settings window: General,
  Menu Bar, Team Profiles and About, then a page per bench with Overview
  (actions, ports, the scheduler), Sites (add a site with its
  Administrator password, make one the default, the hosts fix), Apps (add
  from the registry or any GitHub URL, public or private, install on a
  site, update after a changelog preview) and Health (doctor, and Repair
  with the plan first and a live step list). The popover links into it
  (⌘M) and offers Repair when doctor found something repairable.
- A new app icon: the menu bar runner, a park bench on the run, drawn
  for Icon Composer (`macos/BenchBar/Resources/AppIcon.icon`,
  `scripts/app-icon.py`).

- A log window per bench (⌘L): follows `logs/bench.log` with smart
  scroll, search with a match count and next and previous (⌘G, ⇧⌘G), a
  filter per honcho process, errors and tracebacks in red, the previous
  log, clear, select and copy, and Open in Terminal. It survives the
  runner's log rotation and keeps at most 5000 lines.

### Added: the command line

- `benchbar mcp`: a Model Context Protocol server on stdio (stdlib only
  Python) with `benchbar_list`, `benchbar_status`, `benchbar_doctor`,
  `benchbar_logs_tail`, `benchbar_site_list`, `benchbar_up`,
  `benchbar_down` and `benchbar_restart`, each backed by the CLI's JSON.
- `benchbar logs --json` with `-nN` and `--process NAME`.
- `benchbar repair --json` streams a plan, a step event per action and a
  done event with the exit code; `--dry-run --json` prints only the plan.

- App commands. `benchbar app list [--json] [--no-sites]` shows every
  app with its branch, commit, local changes, shallow clone, version,
  the `apps.tsv` branch and the sites that have it (read with
  `bench list-apps`, cached per bench). `app add NAME|URL` gets an app
  from `config/apps.tsv` or any git URL (GitHub over HTTPS, SSH, or an
  SSH host alias from `~/.ssh/config`), with `--branch`, `--name`, and
  `--site S` or `--all-sites`: it checks access first with a git that
  never prompts, so a missing key or token fails in a second with a fix
  line, clones with `bench get-app --skip-assets` (never `--overwrite`
  or `--resolve-deps`), clones the `required_apps` of `hooks.py` after
  a second plan, installs on the sites, builds once and restarts a
  running bench. A half finished clone moves to the backups. `app
  install NAME --site S` installs an app the bench has. `app update
  NAME` fetches, shows the changelog, backs up every site that has the
  app, fast forwards, runs requirements, migrate and build; it refuses
  a dirty tree, a detached HEAD or a diverged branch, and on a failure
  prints (never runs) the way back. `app update --dry-run --json` is the
  plan for the app.
- Doctor checks `apps_txt` (an `apps.txt` line without its folder
  fails, a git app missing from `apps.txt` warns) and
  `app_branch_policy` (an app off its `apps.tsv` branch warns). Both
  read only local files and git; `repair` has no action for them.
- Team profiles: an organisation's bench recipe in a TOML file outside
  BenchBar, in `~/.config/benchbar/profiles/NAME.toml` or a folder on
  `BENCHBAR_PROFILE_PATH` (a clone of the team's config repo). It names
  a built in `base` for Python, Node and MariaDB, an optional
  `frappe_branch`, a `bundle` or `[[apps]]` with repo, branch and an
  optional commit, and optional `site` and `scheduler`. `benchbar
  install --profile NAME` uses it, and the bench keeps following it.
  `benchbar profile list [--json]`, `profile show NAME` and `profile
  create NAME --from-bench PATH [--dir DIR]` (reads a bench, never
  writes a credential or a commit). A team profile may not shadow a
  built in one.
- The team lockfile `benchbar.toml`: every app's repo, branch and
  commit in `apps.txt` order, and each site with its apps, in the same
  strict TOML subset. `benchbar lock write` writes it from the bench
  (refuses local changes or a detached HEAD unless `--allow-dirty`,
  `--no-commits` for branches only, shows the diff, backs up the old
  file), `lock check [--json]` reports drift (13 kinds, from a missing
  app to a site without an app) with no network or database, and `lock
  apply` clones missing apps, switches clean apps to the locked branch
  and fast forwards to pinned commits, then runs requirements and
  build. It never touches a site, never resets local work (ahead,
  diverged and dirty apps are skipped), and prints the site steps to run
  by hand. `--lock PATH` (remembered per bench) or `BENCHBAR_LOCK`
  points at a file kept in the team's app. Doctor gains `lock_parse`
  and `lock_drift`; `list --json` gains `benches[].lock_file`.
- Access checks before cloning (phase 01 and `app add`) run git with
  `GIT_TERMINAL_PROMPT=0` and SSH in batch mode, so a private repo fails
  at once instead of waiting on a prompt.

### Added: pull

- `benchbar pull HOST:SITE --as NAME` copies a production site over SSH
  into a new local site. It uses the latest backup that already exists on
  the server, so a plain pull writes nothing there; `--new-backup` runs
  `bench backup` first, after the production site name is typed (or
  given with `--confirm-site`), because that also deletes older backups
  on the server. The download resumes (`rsync --partial`, `scp` when the
  server has no rsync) into `<bench>/.benchbar/pulls/`, mode 0700.
- The copy keeps its stored passwords: the production `encryption_key` is
  written into the new site config through stdin and never shown or
  logged, and a probe counts the encrypted rows that decrypt. Encrypted
  backups are decrypted locally with `gpg --passphrase-fd 0`.
- Before the restore, pull compares the production apps with the bench
  and stops with the `bench get-app` commands when one is missing
  (`--skip-app APP` restores without it and says what that leaves
  behind), and stops when production frappe is newer than the bench.
- After the restore: `mute_emails`, `pause_scheduler` and
  `disable-scheduler` (unless `--keep-scheduler`), `host_name`, the
  removal of skipped apps, `bench migrate` when the apps differ,
  `clear-cache`, an optional Administrator password (`ADMIN_PASSWORD` or
  a prompt, on stdin), the hosts line, and a verify pass.
- `--replace` restores over an existing local site after a
  `bench backup --with-files` of it; `--from-dir DIR` restores a backup
  set downloaded by hand (Frappe Cloud); `--dry-run` connects read only
  and prints the plan; `--json` streams `plan`, `gate`, `progress`,
  `step` and `done` events (docs/json-schema.md).

### Changed

- The window's settings panes are laid out like System Settings: a
  header per pane, Startup, Notifications, Command line tool and
  Keyboard shortcuts on General, a runner preview on Menu Bar. The
  sidebar's benches have a context menu (start, stop, restart, open,
  show, copy path).
- `app add URL` for an app in `config/apps.tsv` follows its branch there
  when the repository has it, instead of the repository's default
  branch, so doctor does not warn about an app it just added. Raven's
  registry entry points at `github.com/frappe/raven`.
- `bench new-site` gets the MariaDB root and Administrator passwords on
  stdin, never in its arguments.
- CI runs the CLI tests in three parallel macOS shards (about 4 minutes
  per pull request, from about 13); the Linux job is gone.

### Fixed

- `app update` refuses to run when a site's app list cannot be read, so
  it never skips a site's backup or migrate.
- `pull` into a running bench pauses the bench's scheduler until the
  copy has its own `pause_scheduler` and `mute_emails`.
- A git repository or branch from a team profile or lockfile can no
  longer be read as a git option (`--` everywhere, values starting with
  `-` refused).
- The window no longer jumps wider when you open General, and a
  change's result shows only on the page it belongs to.

## 0.4.0 - 2026-09-26

Frappe v16 is a first class profile, and more than one bench runs on the
same Mac: each with its own ports, sites, settings and scheduler choice,
side by side in the menu bar. Verified on a real Mac with a v15 and a v16
bench running at once (docs/DECISIONS.md, "the v16 bench on a real Mac").

### Added

- **Frappe v16, supported.** The `v16-lts` profile (Python 3.14, Node 24)
  installs and runs end to end. `pkgconf` and `mariadb-connector-c` are
  system dependencies of every profile and on `PKG_CONFIG_PATH` (v16
  pins `mysqlclient`, which builds against them); a CI job runs the v16
  profile under mocks.
- **One MariaDB for every bench.** A bench uses the MariaDB server
  already running on 3306 when the profile accepts its version (v16
  accepts 10.6 to 11.8), so a v16 bench next to a v15 bench shares
  `mariadb@10.11` instead of installing `mariadb@11.8`.
- **Several benches side by side.** Every bench keeps its own profile,
  site, autostart, scheduler, honcho and ports in
  `.benchbar/benches/<name>-<hash>.env`; settings from before 0.4 still
  count for the default bench and move there on the next `service`,
  `adopt` or `install`. A bench without a stored profile gets it from its
  frappe version. A second bench no longer becomes the default by being
  set up; `--make-default` does that.
- **Port blocks.** A new bench that clashes with an established one moves
  to the next free block (web `8000 + n`, socketio `9000 + n`, Redis
  `11000 + n` and `13000 + n`), written with `bench set-config -g` and
  `bench setup redis` as part of the plan; `--port-offset N` picks one.
  The default bench never moves on its own.
- **Sites.** `benchbar site list`, `site add NAME` (with the Keychain
  MariaDB password, the hosts line, and apps from `apps/`),
  `site default NAME` and `site hosts`.
- **The scheduler, opt in per bench:** `benchbar service --with-schedule`
  and `--without-schedule`; `repair` keeps the choice.
- **Doctor checks from the community threads**, each with its fix:
  `full_disk_access`, `toolchain_node`, `toolchain_yarn`,
  `toolchain_pkgconfig` (the tools as the bench's launchd PATH sees them,
  so nvm's node shows up as missing), `mariadb_version` (the profile's
  range), `honcho_setuptools` (with a repair that touches only honcho's
  venv), `fork_safety`, `orphans` (stale processes on the bench's ports)
  and `scheduler`.
- **BenchBar.app with several benches:** a bench list with state, uptime
  and Start, Stop and Restart per row; the runner shows the worst state
  across all benches, with an "n of m up" count; the selected bench lists
  its sites with Open buttons, the default marked, and the `site hosts`
  fix when a hosts line is missing; a scheduler switch per bench in
  Settings.
- JSON (still `schema_version: 1`): `sites[]` in `list` and `status`,
  `scheduler` in `status`, `redis_socketio` in `ports`.
- `bench` itself is installed with `uv tool install frappe-bench` when uv
  is on PATH; pipx stays the fallback and existing pipx installs are left
  alone. Doctor names the owner.

### Changed

- **Benches never touch each other's processes.** `down`, `status` and
  the runner match honcho and socketio by their working folder: both run
  with the same relative command line in every bench, and before 0.4
  starting or stopping one bench also stopped the other's. The runner
  template is v3; run `benchbar repair` on every bench once.
- The shell block's PATH lines follow the default bench's profile, so a
  v16 bench never changes the Python and Node of your shell; phase 00
  writes the block only when there is none.
- The doctor check `wkhtmltopdf` is now `pdf_engine`: wkhtmltopdf on
  every profile (still v16's default engine) and, on v16, the Chromium
  used by Print Formats set to `chrome`, with `bench setup-chrome` as
  the fix.
- `bench init` runs with `--no-backups`: a dev bench needs no backup
  cron, and the crontab write is what fails without Full Disk Access.
- Site setup runs the bench's own Redis while it creates the site and
  installs apps (frappe v16 needs it; a new bench has none running yet),
  and stops only what it started.
- v16 sites are created with `--mariadb-user-host-login-scope=%`; v16
  calls `--no-mariadb-socket` deprecated.
- The port clash check also reports a bench that is only configured with
  the same ports, with the `--port-offset` that fixes it.
- ROADMAP.md: 0.5 is one bigger release (repair from the app, a log
  viewer, `benchbar mcp`, app installs from any GitHub repo, team
  profiles, a team lockfile and pulling a production site); the public
  launch moves to 0.6.

### Fixed

- `doctor --json` with a failing check printed a `[FAIL] Last command
  failed` line after the JSON, so the app could not read the report.
- The Python formula check read `brew leaves`, which hides a formula
  other formulae depend on (python@3.14 under pipx and uv); it now reads
  "installed on request".
- A run that ended on verify warnings no longer adds a misleading
  `[FAIL] Last command failed` line naming a command that succeeded.

## 0.3.1 - 2026-09-24

### Fixed

- `benchbar doctor` no longer reads the MariaDB root password from the
  Keychain: the live `character_set_server` query added in 0.3.0 is gone.
  Doctor is read only and the app runs it on a timer, so it must never
  touch the Keychain. The `!includedir` check stays; a missing `my.cnf`
  counts as a missing includedir.
- Phase 01 exits 2, the documented "root password unknown" code, when a
  fresh site needs the MariaDB root password and no source has it, and
  `benchbar install` reports that as a pending manual step.
- wkhtmltopdf detection prefers the official package binary in
  `/usr/local/bin` when it is the patched build, and warns (fix:
  `brew uninstall wkhtmltopdf`) when an unpatched Homebrew build earlier
  on PATH would shadow it.

## 0.3.0 - 2026-09-24

The project is now **BenchBar**: the `benchbar` command line tool, plus a
native menu bar app. Built for Frappe and ERPNext on macOS; not
affiliated with Frappe Technologies.

### Added

- **One line installer**, `install.sh`: checks macOS, the Command Line
  Tools and Homebrew (offering their installers), clones the CLI into
  `~/.local/share/benchbar` with links in `~/.local/bin` and a PATH block
  in `~/.zshrc`, installs the BenchBar app from the latest GitHub release
  (zip checked against the release's `SHA256SUMS`, unpacked with `ditto`,
  so no Gatekeeper prompt), then offers `benchbar adopt` for a bench it
  finds or `benchbar install`. Flags `--yes`, `--dry-run`, `--no-app`,
  `--app-only`, `--version vX.Y.Z`, `--uninstall`. Re-runs say
  `unchanged`.
- **The manual install steps are gone.** Phase 00 sets the MariaDB root
  password itself (generated, or `MARIADB_ROOT_PASSWORD`), applies the
  secure installation steps in SQL, and keeps the password in the macOS
  Keychain (`benchbar-mariadb`); every later step reads it from there and
  passes it through `MYSQL_PWD`. The utf8mb4 drop-in is a doctor check and
  repair action. The patched Qt wkhtmltopdf is downloaded from the pinned
  official package (`config/wkhtmltopdf.tsv`, sha256 checked) and
  installed with `installer`; on Apple Silicon Rosetta 2 is offered first
  because the package is an Intel binary, and skipping it only costs
  PDFs. The `/etc/hosts` line sits inside `# >>> benchbar >>>` markers,
  with a backup first. One `sudo` prompt covers a whole run.
- `benchbar adopt PATH`: registers an existing bench (Procfile.lean,
  runner, launchd agent, helpers, hosts line) after showing the plan and
  asking. Never runs `migrate`, `build` or `update`.
- `benchbar report [--print]`: a redacted diagnostics zip on the Desktop
  with doctor and status JSON, versions, the agent, `Procfile.lean`,
  `state.json`, log tails and the key names of the site configs. Secrets
  are masked by key name, paths and names are replaced by placeholders,
  and `REDACTIONS.txt` lists what was replaced.
- `benchbar mariadb-password`: prints the Keychain password after a
  confirmation.
- Doctor checks `MariaDB utf8mb4` and `wkhtmltopdf`, with repair actions.
- CI (`.github/workflows/ci.yml`) on pull requests and pushes to main:
  shellcheck and the CLI tests on macOS (`/bin/bash` 3.2) and Linux, an
  unsigned app build and the Swift tests, and `scripts/release-local.sh`
  whose zip, dmg and `SHA256SUMS` are uploaded as a workflow artifact.
- Releases (`.github/workflows/release.yml`): a `v*` tag drafts a GitHub
  release with the CHANGELOG section as notes. Without Developer ID
  secrets the app is ad hoc signed (`scripts/release-local.sh`); with
  them it is signed, notarized and stapled, with the Sparkle appcast and
  the Homebrew cask (`docs/releasing.md`).
- `docs/testing.md`, a three step guide for testers, and
  `docs/DECISIONS.md`.
- **BenchBar.app** (`macos/`, macOS 14+, Apple Silicon), built from the
  command line with `scripts/macos-build.sh` and installed with
  `scripts/macos-install-local.sh`:
  - an animated menu bar runner per state (sleeping, walking, running,
    stumbling, alert, question), one Core Animation keyframe animation,
    tinted for light, dark and the transparent menu bar;
  - running speed from the CPU use of the bench's process tree (libproc,
    every 2 seconds, smoothed), behind a `SpeedSource` protocol;
  - Reduce Motion support, and pausing on sleep, screen sleep, lock and
    user switching;
  - a popover with state, uptime, Start, Stop, Restart, open site, logs
    (Terminal) and folder, a read only doctor, a bench picker, repair
    hints and keyboard shortcuts;
  - a Settings window: runner picker with live preview, speed toggle,
    launch at login (`SMAppService`), notifications, CLI path;
  - notifications on crash, crash guard pause and recovery;
  - two original built in runners (a bench and a coffee cup) and custom
    runners: a folder with `manifest.json` and PNG frames, imported from
    a folder or zip with strict validation (`docs/runners.md`,
    `examples/runners/blob`).
- Versioned JSON API (`schema_version: 1`): `benchbar list --json`,
  `status --json`, `doctor --json`, and `<bench>/logs/.benchbar/state.json`
  written atomically by the runner on every transition
  (`docs/json-schema.md`).
- `stop_reason: "broken"` for a bench that cannot start until `repair`.
- Release plumbing, documented and not yet live (no Apple Developer
  account): Developer ID signing, notarization, DMG, Sparkle 2 behind a
  build flag, a Homebrew cask template and a guarded GitHub Actions
  workflow (`docs/releasing.md`).

### Changed

- `00-mac-system-deps.sh` exits 2 only when MariaDB already has a root
  password that neither the environment nor the Keychain knows; it takes
  `--yes`. `01-install-bench-and-site.sh` reads the root password from
  the Keychain and no longer passes it on the `mariadb` command line.
- The test suite runs on Linux as well as macOS (GNU stat and sed, a
  `uname` mock), so a Linux machine gives quick feedback.
- The CLI is `benchbar`; `frappe-mac` stays as a link to it.
- Agents are `com.benchbar.<bench>` and carry
  `AssociatedBundleIdentifiers` so Login Items shows them under BenchBar.
  `benchbar repair` migrates `com.frappe-mac.<bench>` agents (only for
  this bench), restarting the bench if it was running. Old plists move to
  `~/Library/LaunchAgents-disabled/<timestamp>/`.
- `up`, `down` and `restart` on a bench that still has its old agent now
  say so and point at `benchbar repair`, instead of "not installed".
- The runner runs honcho as a child, forwards SIGTERM and records the
  final state; a SIGTERM without a stop flag is a clean stop. Its
  osascript crash notification stays as a fallback and is skipped while
  BenchBar runs.
- `status --json`: `state` is now the contract value (stopped, starting,
  running, crashed, paused); launchd's word moved to `agent_state`.
- The repository is now github.com/askysh/benchbar (the old URLs
  redirect). README, AGENTS.md, the docs, the cask and the Sparkle feed use
  it.
- Names from before 0.3.0 move over once, on the next run or `repair`:
  the checkout's `.frappe-local/` becomes `.benchbar/`,
  `frappe-mac-run.sh` in the bench becomes `benchbar-run.sh` (the old file
  goes to the backups once no agent uses it), the `# >>> frappe-mac >>>`
  block in the shell rc is replaced in place by `# >>> benchbar >>>`, and
  new files carry a `benchbar-template:` header. Files are not rewritten
  for the header word alone, so MariaDB is not restarted.

### Fixed

- Reading a missing stop flag no longer prints "No such file or
  directory".
- Reloading the agent of a running bench (a repair after a template or
  setting change, `autostart on|off`) could leave it stopped and unloaded:
  `launchctl bootout` returns while the job is still shutting down, the
  immediate `bootstrap` failed, and the `load -w` fallback exits 0 without
  loading anything. The CLI now waits until launchd has let go of the job
  (up to 30 seconds), confirms the load with `launchctl print`, and fails
  the step clearly instead of reporting success.

## 0.2.0 - 2026-09-23

### Added

- `frappe-mac`, a single entrypoint (also linked into `~/.local/bin`) with `install`, `service`, `doctor`,
  `repair`, `up`, `down`, `restart`, `status`, `logs`, `fg`, `watch`,
  `autostart on|off`, `uninstall-service` and `path`. Global flags
  `--bench-dir`, `--site`, `--profile`, `--bundle`, `--dry-run`, `--yes`,
  `--json`, `--plain`.
- Background service: one launchd agent per bench
  (`com.frappe-mac.<bench>`) runs honcho with a lean Procfile (no watch,
  no schedule) through a generated runner script. The runner clears stale
  processes of this bench, refuses to start while a stop flag exists, and
  pauses auto-restart after 3 starts in 10 minutes with a macOS
  notification. The agent bakes `PATH`,
  `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` and `NO_PROXY=*`, uses
  `KeepAlive SuccessfulExit=false` and `ThrottleInterval 20`.
- honcho resolution in order: `PATH`, the pipx venv of `frappe-bench`,
  `env/bin/honcho`, then install with `uv pip` (or pip) as a last resort.
  The absolute path is stored.
- Shell helpers `benchup`, `benchdown`, `benchrestart`, `benchstatus`,
  `benchlogs`, `benchfg`, `benchwatch`, `benchdoctor`, `benchcd` in one
  marker block (`# >>> frappe-mac >>>`) that also carries the profile
  exports. Blocks are replaced in place only when both markers exist
  exactly, otherwise appended with a warning. The rc file is backed up
  first.
- `doctor`: read-only checks with `[OK]`, `[WARN]`, `[FAIL]` and the exact
  fix command, plus `--json`. Covers Homebrew formulae, the profile Python
  and `brew leaves`, `env/bin/python`, `bench version`, socket.io, the
  dist files referenced by `assets.json`, honcho, the generated files and
  their version headers, the agent state and last exit code, the stop
  flag, the shell block and old helper blocks, legacy per-process agents
  with their exit codes, MariaDB bind address, redis on 6379, site ping,
  `/etc/hosts`, log sizes, CleanMyMac, and port clashes between benches.
- `repair`: runs only the flagged fixes in dependency order (Python
  formula, env rebuild, honcho, node requirements, build, cache clearing,
  MariaDB bind, legacy agent migration, generated files, hosts entry, log
  rotation, redis prompt), with a backup or move-aside before every
  change and a verify pass afterwards.
- Template versioning: runner, plist, `Procfile.lean`, shell block and
  MariaDB drop-ins carry a `frappe-mac-template: <name> vN <hash>` header
  and are rewritten only when the rendered content changed. Previous
  copies go to `.frappe-local/backups/<timestamp>/`.
- Legacy agent migration: older per-process or hand-made agents are
  booted out and moved to `~/Library/LaunchAgents-disabled/<name>-<timestamp>/`.
- MariaDB `bind-address = 127.0.0.1` drop-in in
  `$(brew --prefix)/etc/my.cnf.d/` with the `!includedir` line ensured in
  `my.cnf`.
- TUI: tput colors with `NO_COLOR` and non-TTY fallbacks, a header box,
  a numbered step list with live status and timings, spinners with a
  rolling tail for long commands (last 40 lines and the log path on
  failure), a plan summary with confirmation, a summary table and a
  "Next steps" box. Full logs in `.frappe-local/logs/<timestamp>.log`.
- A lock directory (`.frappe-local/lock`) so two runs cannot overlap.
- `02-background-service.sh` as the phase wrapper for `frappe-mac service`.
- Mocked tests for launchctl, brew, lsof, pkill, pgrep, curl, osascript,
  bench, honcho, uv, pipx and sudo, covering install run twice, legacy
  migration, every doctor detection, the crash guard, scoped stop,
  dry-run, marker blocks and the phase scripts. shellcheck runs on every
  script.
- `AGENTS.md` with guidance for AI coding agents.

### Changed

- `00-mac-system-deps.sh` now writes the shell block and the utf8mb4
  MariaDB drop-in itself (with backups) instead of printing them as
  manual steps, installs formulae behind a spinner, and exits with code 2
  while manual steps remain.
- `01-install-bench-and-site.sh` refuses to move a bench that has apps or
  sites aside and points to `frappe-mac repair` instead, asks for the two
  passwords only when the site must be created, resolves the bench
  directory to an absolute path (default `~/frappe-bench`), records the
  bench and site in `.frappe-local/state.env`, and runs `get-app`,
  `new-site` and `install-app` behind a spinner.
- Status lines print `[OK]`, `[WARN]`, `[FAIL]` in brackets.
- README rewritten around `frappe-mac install` and the daily helpers.

### Fixed

- The `/etc/hosts` check matched only lines with two spaces after the
  address; it now matches any whitespace.

## Unreleased (before 0.2.0)

### Added

- Added preflight checks for running as a normal user, available disk space, and internet access.
- Added a timeout guard around `bench init`.
- Added handling for background commands that stop while waiting for terminal input.
- Added safe reuse guidance when an existing MariaDB/MySQL service is detected on port `3306`.
- Added README status badges.
- Added a roadmap file.

### Changed

- Rewrote README as a phased beginner walkthrough. Advanced flags moved after the happy path.
- Refreshed roadmap: the WSL/Windows path now lives in [askysh/frappe_wsl_dev_server](https://github.com/askysh/frappe_wsl_dev_server).

## 0.1.0 - 2026-04-25

### Added

- Initial public macOS Frappe/ERPNext local installer.
- Added profile-driven system dependency setup.
- Added bench and site setup with public app bundles.
- Added local shell tests with mocked `bench` and `git` behavior.

#!/usr/bin/env bash
#
# usage.sh: the text of `benchbar --help`, `benchbar help` and `benchbar` alone, as `use` records
# (CORE-18, issue 151). The lines are the ones that were written by hand in the entry point, one
# record per line, and tests/test-help-golden.sh holds them byte for byte:
#   use~KEY~TEXT
# KEY is the command ("install", "site add") the line belongs to, or - for a heading, a blank
# line or an option. TEXT is the line as printed, leading spaces included. A ~ in it is written
# {tilde}, the version {version} and the documentation address {docs}.
# usage() (commands.sh) sources this file when the help prints. It is a file of its own, and not a
# variable of commands.sh, because reading 22 KB more of heredoc there cost every start 10 ms.

# fl_usage_table: the records
fl_usage_table() {
  cat <<'TABLE'
use~-~benchbar {version}: local Frappe/ERPNext bench on macOS and Linux, in the background.
use~-~
use~-~Usage: benchbar <command> [options]
use~-~
use~-~Setup
use~install~  install             Run phase 00 (system deps), 01 (bench and site) and the
use~install~                      background service. Safe to re-run: only changes what changed.
use~install~                      --json (with --yes or --dry-run): JSON lines for the BenchBar app.
use~install~                      --frappe-commit SHA, --erpnext-commit SHA: pin the clones (or frappe_commit
use~install~                      and erpnext_commit in a team profile); a commit the clone does not reach
use~install~                      stops the install before anything is built.
use~adopt~  adopt PATH         Register an existing bench: Procfile.lean, runner, agent, helpers.
use~adopt~                      Shows the plan and asks; never runs migrate, build or update.
use~adopt~                      --json (with --yes or --dry-run): JSON lines, as install.
use~service~  service             Install or refresh only the background service (phase 02).
use~doctor~  doctor              Read-only health report. Exit 1 when something FAILs.
use~doctor~                      --fix-hints: only the fix commands of FAIL and WARN checks, one per line.
use~doctor~                      --prerequisites: what this Mac needs before an install, no bench needed
use~doctor~                      (--json; --bench-dir names the folder a new bench would go to).
use~doctor~                      --fetch: git fetch the branches of the apps your focus apps need first
use~doctor~                      (without it doctor never touches the network).
use~doctor~                      --ack CHECK / --unack CHECK: silence one warning until its message
use~doctor~                      changes, or undo that. --quick: skip the slow checks and say which.
use~ports setup~  ports setup -- PATH ...
use~ports setup~                      Preview management/port changes, confirm once, then apply (--dry-run: preview only)
use~ports plan~  ports plan -- PATH ...
use~ports plan~                      Show the same read-only preview (--json: machine-readable plan and token)
use~ports check~  ports check         Check conflicts for --bench-dir PATH (--json)
use~ports mode~  ports mode automatic|fixed
use~ports mode~                      Keep automatic or fixed ports for --bench-dir PATH
use~ports apply~  ports apply TOKEN --yes -- PATH ...
use~ports apply~                      Apply a previously reviewed JSON plan; refuse stale approvals
use~report~  report              Redacted diagnostics zip on the Desktop for bug reports (--print: to the terminal,
use~report~                      --json: {"zip": path, "redactions": n} for the app and scripts).
use~repair~  repair              Apply only the fixes doctor flagged, in dependency order.
use~uninstall-service~  uninstall-service   Remove the agent, runner, Procfile.lean and shell helpers.
use~uninstall-service~                      --all: every bench with a benchbar agent, after one question (before
use~uninstall-service~                      brew uninstall benchbar: brew cannot stop the agents itself).
use~self-update~  self-update         Update the benchbar CLI and the BenchBar app with the one line installer,
use~self-update~                      after asking (--check: this version against the latest, --json, --dry-run).
use~self-update~                      A Homebrew install runs brew upgrade askysh/tap/benchbar instead.
use~self-update~                      Never touches a bench; never runs bench update.
use~where~  where               How this CLI was installed (homebrew, managed, checkout, other), the path
use~where~                      it records for itself, its state folder and the BenchBar app (--json).
use~-~
use~-~Daily
use~up~  up                  Start the bench in the background (benchup).
use~up~                      --services-only: only its Redis, for a restore or a migrate (down stops it).
use~down~  down                Stop it and keep it stopped across reboots (benchdown).
use~restart~  restart             Restart it, for example after changing Python code.
use~status~  status              State, pid, stop reason, site ping, Redis (benchstatus). --json adds
use~status~                      redis and sites[].served (does the running bench serve the site).
use~stats~  stats               CPU and memory of the running bench's own processes, and the figure the
use~stats~                      app's runner speed comes from (--json; resources is null when stopped).
use~wait~  wait                Block until the bench is ready (site answers, socketio, Redis, a worker, code
use~wait~                      not changed since the start); --for PART for one part, --timeout SECS, --json.
use~list~  list                Every bench benchbar knows about.
use~scan~  scan PATH           Find benches recursively in a folder (read only; --json).
use~register~  register PATH ...   Remember selected benches without changing their services.
use~logs~  logs                Tail logs/bench.log. Flags: --worker, --worker-error, --previous, -n50, --no-follow,
use~logs~                      --process web|socketio|schedule|worker (worker reads logs/worker.log; with --json:
use~logs~                      the lines as JSON, --since TIME or --since-restart for the newer ones only)
use~fg~  fg                  Stop the service and run honcho in the foreground.
use~watch~  watch               Run bench watch for asset rebuilds.
use~autostart~  autostart on|off    Whether the bench may come back after login.
use~listen~  listen local|all    Where the web server and socketio listen: 127.0.0.1 (default) or every interface.
use~path~  path                Print the bench directory (used by benchcd).
use~site list~  site list           The bench's sites; the default one is what benchup waits for.
use~site add~  site add NAME       bench new-site (MariaDB password from the Keychain, a file on Linux), the hosts line, and
use~site add~                      --bundle NAME or --apps "a b" from apps/. The default stays.
use~site default~  site default NAME   Make NAME the default site (bench use, runner, benchup, the app).
use~site hosts~  site hosts          Add a 127.0.0.1 line for every site to /etc/hosts (sudo, once).
use~site backup~  site backup NAME    bench --site NAME backup (--with-files for the uploads too; --json).
use~site backups~  site backups NAME   The site's backups, newest first: time, size, with files (--json).
use~site snapshot~  site snapshot NAME [--label TEXT]
use~site snapshot~                      Save the state of a site (database, files, site_config) in a folder frappe's
use~site snapshot~                      backup pruning never touches.
use~site snapshots~  site snapshots NAME The snapshots, newest first, and whether the bench's apps still match.
use~site rollback~  site rollback NAME --to SNAPSHOT
use~site rollback~                      Put a snapshot back (a reviewed plan; the current state is snapshotted first).
use~site move~  site move NAME --to-bench PATH
use~site move~                      Move a site to another registered bench (a reviewed plan: backup, restore
use~site move~                      there, migrate, check, then the drop here; the backups stay).
use~site restore~  site restore NAME   Restore a backup set (--from STAMP or the database file's PATH, --from-site S)
use~site restore~                      into a site: it is backed up first, or --new creates it. --no-migrate,
use~site restore~                      --before-migrate SCRIPT, --with-files. --neutralise switches the restored
use~site restore~                      site's integrations off and clears its stored secrets (for a set that is
use~site restore~                      not this bench's own; an agent must pass it). --dry-run --json prints the plan with
use~site restore~                      its token; --apply TOKEN --yes [--json] runs exactly that plan.
use~site drop~  site drop NAME      bench drop-site: a backup with files first, the folder moved to
use~site drop~                      archived/sites, the hosts line removed. Needs --confirm-site NAME;
use~site drop~                      the default site also needs --new-default OTHER (--dry-run, --json).
use~console~  console             bench --site SITE console: a Python shell with frappe (--site S).
use~db~  db                  bench --site SITE mariadb: the site's database with its own user (--site S).
use~open~  open                Open the site in the browser (--site S, --path /app/...). --as USER signs in
use~open~                      as that user, no password; needs developer_mode and a person to run
use~open~                      "site open-as on" for the site. --print-url prints the link instead.
use~users~  users               Enabled users of a site for open --as (--site S, --search TEXT, --limit N).
use~share setup~  share setup         Make a hardened copy of a site (share.localhost) and the host identity for
use~share setup~                      sharing it on your network. Needs a person at a terminal and --acknowledge-data:
use~share setup~                      the copy holds the site's real data, and the MariaDB root password (Keychain,
use~share setup~                      MARIADB_ROOT_PASSWORD or typed). --users A,B, --name LABEL, --from STAMP|latest,
use~share setup~                      --backup-now, --refresh, --regenerate-identity, --dry-run, --json.
use~share users~  share users         Who can take a seat in a shared copy, and which roles each would lose there.
use~share preflight~  share preflight     The checks that say whether this Mac is safe to share the copy: the pf block
use~share preflight~                      probed from the LAN address, the share web process, the firewall, the copy and
use~share preflight~                      its seats. --static or --critical for half, --quiet, --json; exit 1 on a fail.
use~share join~  share join [ADDR]   Join somebody's room as a guest: with ADDR (the host's IPv4 address) it asks
use~share join~                      for the room code, without one for the invite link. Neither is ever an
use~share join~                      argument. It shows the host key first, waits for a seat, and opens the room on
use~share join~                      a localhost address. share joined lists the rooms, share leave gives the seat
use~share join~                      back, share forget also deletes this computer's key for that host.
use~lan-guard install~  lan-guard install   The pf anchor (macOS) or nftables table (Linux) that keeps the bench ports off
use~lan-guard install~                      the LAN, and the daemon or systemd unit that loads it at boot (sudo, once; a
use~lan-guard install~                      person at a terminal). status (--json), remove, and allow-node (macOS only:
use~lan-guard install~                      lets the share gateway's node through the macOS firewall).
use~mariadb-password~  mariadb-password    Print the MariaDB root password (Keychain; a 0600 file on Linux; asks first).
use~mariadb-password~                      A person's command: refused for agents, mcp and without a terminal.
use~mcp~  mcp                 Model Context Protocol server on stdio for coding agents
use~mcp~                      (claude mcp add benchbar -- benchbar mcp). Read tools, up, down, restart,
use~mcp~                      changes from a reviewed plan. --calls [N] prints the audit log.
use~op status~  op status [OP_ID]   The long runs. Every command that changes things has an op_id (in its JSON
use~op status~                      lines too); status shows one (or the ten newest) with its step and last
use~op status~                      progress, list shows the recent ones, wait OP_ID [--timeout SECS] waits for
use~op status~                      one to end. A run that died without a done line is interrupted.
use~history~  history             What ran on this machine, newest first: the command line (secrets as ***), who
use~history~                      started it (a terminal, the app, the tray, an agent through MCP, a script), the
use~history~                      bench, the times, the exit and what it changed. --bench PATH, --since 7d,
use~history~                      --limit N, --json.
use~docs~  docs [TOPIC]        Open the documentation, or one topic's page (benchbar docs --help lists
use~docs~                      them: install, doctor, apps, mcp, json ...); --print prints the URL.
use~-~
use~-~Apps
use~app list~  app list            Every app: branch, commit, local changes, the sites that have it
use~app list~                      (--json; --no-sites reads the last site lists instead of asking bench).
use~app add~  app add NAME|URL    bench get-app from config/apps.tsv or any git URL (GitHub, SSH, a
use~app add~                      host alias), after checking access; --branch B, --name N, --commit SHA
use~app add~                      (pin the clone to a commit), and --site S or --all-sites to install it.
use~app add~                      Several apps in one plan: app add A --commit SHA B --install-on s1,s2
use~app add~                      (--branch, --name, --commit and --install-on belong to the app before
use~app add~                      them). Never replaces an app.
use~app add~                      --dry-run --json: the plan with its token (required apps read from
use~app add~                      hooks.py); --apply TOKEN --yes runs exactly that plan, no questions.
use~app install~  app install NAME    Install an app of the bench on a site (--site S). --dry-run --json: the
use~app install~                      plan with its token; --apply TOKEN --yes runs exactly that plan.
use~app update~  app update NAME     Fast forward one app with a changelog first, back up the sites
use~app update~                      that have it, then requirements, migrate and build (--skip-backup).
use~app update~                      A run that stopped half way is finished by the next one (only the steps
use~app update~                      left); --discard-pending drops that record and stops (nothing runs).
use~app update~                      --dry-run --json: the plan with its token; --apply TOKEN --yes runs it.
use~app focus~  app focus [NAME]    Focus apps (the ones you work on: local changes, another branch, a
use~app focus~                      commit of yours in 14 days): doctor warns when an app they need falls
use~app focus~                      behind. No NAME lists them (--list, --json, --fetch); NAME pins it as
use~app focus~                      focus, --auto infers again.
use~app unfocus~  app unfocus NAME    Pin NAME as not a focus app.
use~-~
use~-~Team lockfile (benchbar.toml: each app's repo, branch and commit, and the sites)
use~lock write~  lock write          Write it from this bench (asks, shows the diff, backs up the old one);
use~lock write~                      --lock PATH (remembered), --no-commits, --allow-dirty.
use~lock check~  lock check          Compare the bench with it: read only, no network, no database.
use~lock check~                      Exit 1 on any difference (--json).
use~lock apply~  lock apply          Clone missing apps, switch branches, fast forward to pinned commits,
use~lock apply~                      then requirements and build. Never touches a site or local work.
use~lock apply~                      --dry-run --json: the plan with its token; --apply TOKEN --yes runs it.
use~-~
use~-~Team profiles
use~profile list~  profile list        Built in and team profiles, with where each comes from (--json).
use~profile show~  profile show NAME   What a profile installs: base, Python, Node, MariaDB, apps.
use~profile create~  profile create NAME --from-bench PATH [--dir DIR]
use~profile create~                      Write a team profile from a bench (read only: app repos and
use~profile create~                      branches, the base from its frappe version). install --profile NAME
use~profile create~                      then builds the same bench on another Mac.
use~profile export~  profile export NAME [--out FILE] [--branch APP=BR]... [--drop APP]... [--plan]
use~profile export~                      A copy to share: SSH aliases resolved, each repo's default branch,
use~profile export~                      access (public, private, personal) and requires per app.
use~profile import~  profile import FILE|URL [--as NAME] [--plan]
use~profile import~                      Add a profile someone sent (https only, 64 KB at most); checks
use~profile import~                      which repos you can read. A GitHub page URL is fetched raw.
use~profile subscribe~  profile subscribe GIT_URL [--plan]
use~profile subscribe~                      Clone a team's config repo; its profiles join the lookup path.
use~profile update~  profile update NAME|--all [--plan]
use~profile update~                      Fetch an import or subscription again, show the diff, ask.
use~profile remove~  profile remove NAME Move an import or a whole subscription aside.
use~profile check~  profile check NAME  Can git read every repo with your credentials? (--json)
use~-~
use~-~Experiments (off until a person turns one on)
use~labs~  labs [list]         The experiments and whether each is on (--json).
use~labs on~  labs on NAME        Turn one on, in a terminal, after its warning. Never from an agent.
use~labs off~  labs off NAME       Turn one off and undo what it started. labs status NAME: exit 1 when off.
use~-~
use~-~Leases (a bench or a site held for a while, so nothing restarts, migrates, drops or restores it meanwhile)
use~lease take~  lease take          --bench PATH or --site NAME, --for MINUTES (default 30, at most 480), --note TEXT;
use~lease take~                      prints the lease id (--json). Set BENCHBAR_CALLER to a name for the holder;
use~lease take~                      an agent run without one cannot take a lease.
use~lease renew~  lease renew ID      Push the end back (--for MINUTES).   lease release ID  Let go of it.
use~lease list~  lease list          The active leases (--bench PATH, --json). A lease id is shown to its holder
use~lease list~                      only. Pass --lease ID to a command that changes
use~lease list~                      what a lease covers; --break-lease is for a person at a terminal only.
use~-~
use~-~Defaults that changed
use~notices~  notices             The notices an update left (a new default and its way back), --json.
use~notices~                      --dismiss ID or --all hides them (also in the BenchBar app).
use~-~
use~-~Production copy
use~pull~  pull HOST:SITE      Copy a production site over SSH into a NEW local site: the latest
use~pull~                      backup on the server (nothing written there), the encryption key,
use~pull~                      email muted, the scheduler paused and the copy neutralised
use~pull~                      (integrations off, stored secrets cleared). HOST is from {tilde}/.ssh/config.
use~pull~    --as NAME         Local site name (default: SITE.local)
use~pull~    --from-dir DIR    A backup set downloaded by hand (Frappe Cloud), no SSH
use~pull~    --remote-bench D  The bench folder on the server (default {tilde}/frappe-bench)
use~pull~    --new-backup      Run bench backup on the server first (it also deletes older
use~pull~                      backups there); asks for the site name, or --confirm-site SITE
use~pull~    --replace         Restore over an existing local site, after backing it up
use~pull~    --skip-app APP    Restore without APP (its tables stay behind as orphans)
use~pull~    --no-files        Database only; --keep-scheduler, --keep-staging
use~pull~    --keep-secrets    Leave the copy as production had it. By default it is neutralised:
use~pull~                      outbound integrations off, stored secrets cleared, tokens and
use~pull~                      queued mail dropped (the Administrator login is kept).
use~pull~                      A person's decision: refused for agents and benchbar mcp
use~pull~    --no-migrate      Stop after the restore, before bench migrate
use~pull~    --before-migrate S  Run the executable SCRIPT after the restore, before migrate (with
use~pull~                      BENCHBAR_SITE, BENCHBAR_BENCH, BENCHBAR_DB_NAME; no secret in its
use~pull~                      environment); a failing script stops the run
use~pull~                      The local site is created when it does not exist.
use~-~
use~-~Options
use~-~  --bench-dir DIR     Bench to act on (default: remembered, or auto-detected)
use~-~  --site NAME         Site name (default: remembered, or from the bench)
use~-~  --profile NAME      Release profile for install/repair (default: v15-lts), or a team
use~-~                      profile ({tilde}/.config/benchbar/profiles/NAME.toml, BENCHBAR_PROFILE_PATH)
use~-~  --bundle NAME       App bundle for install (minimal, common, extended)
use~-~  --scratch, --ttl DAYS
use~-~                      install: the bench expires after DAYS (default 7); benchbar bench gc removes it
use~-~  --make-default      install, adopt, service: make this the default bench even when
use~-~                      another one is already the default
use~-~  --repair-bench      install: move a bench folder that is incomplete aside and start over (never
use~-~                      one that holds a site; --dry-run shows the move)
use~-~  --allow-windows-fs  install, adopt (WSL): accept a bench on the Windows file system
use~-~                      (/mnt/c, drvfs, 9p), which is slow and breaks file watching
use~-~  --allow-unsupported-distro
use~-~                      install (Linux): try a system other than Ubuntu 24.04, which is the one
use~-~                      the install is tested on and supports (at your own risk)
use~-~  --with-schedule     service: add the scheduler to Procfile.lean (per bench, kept by repair)
use~-~  --without-schedule  service: remove it again (the default)
use~-~  --port-offset N     install, adopt, service: use port block N (web 8000+N, socketio 9000+N,
use~-~                      redis 11000+N and 13000+N). Default: keep the ports, or the next
use~-~                      free block when another bench already uses them
use~-~  --dry-run           Print the full plan, change nothing
use~-~  --offline           install: skip the remote branch checks (also OFFLINE=1 or BENCHBAR_OFFLINE=1)
use~-~  -y, --yes           Do not ask; secrets must come from the environment
use~-~  --json              Versioned JSON for list, status and doctor; JSON lines for pull,
use~-~                      install, adopt, repair, up, down, restart, service, site add,
use~-~                      app update and ports apply (docs/json-schema.md)
use~-~  --lease ID          A lease you hold (benchbar lease take): the command may change what it covers
use~-~  --break-lease       A person at a terminal goes ahead although a lease covers the command
use~-~  --jsonl             JSON lines (plan, step, done) from any command that changes things
use~-~  --for-agent         --jsonl or --json, no questions (BENCHBAR_NONINTERACTIVE=1), no colors
use~-~  --background        install, repair, pull, app add, app update, site add, site backup, site restore,
use~-~                      site snapshot, site rollback:
use~-~                      start the run detached and print its op_id at once (needs --yes; no questions)
use~-~  benchbar COMMAND --help prints that command's flags and needs; benchbar commands --json lists them all
use~-~  --plain             No colors or spinners (also: NO_COLOR=1, or a non-TTY)
use~-~  -h, --help          This help
use~-~  --version           Print the version (and the BenchBar app's, when it is installed)
use~-~
use~-~Environment:
use~-~  BENCHBAR_SUDO=gui   root steps (wkhtmltopdf, /etc/hosts) ask in a macOS password dialog, not sudo
use~-~  BENCHBAR_SUDO=env   Linux: sudo steps use the password in BENCHBAR_SUDO_PASSWORD, no terminal needed
use~-~  BENCHBAR_CALLER     Who started the run, for benchbar history: terminal, app, tray, mcp, agent or
use~-~                      script (set by the app, the tray and benchbar mcp; --for-agent says agent)
use~-~  BENCH_INIT_TIMEOUT_SECONDS   install: how long bench init may run (default 2700, 0 for no limit)
use~-~  BENCHBAR_LENIENT_FLAGS=1     an unknown option is a warning, not an error (exit 64), as before 0.9.0
use~-~
use~-~Shell helpers (written to your shell rc by install or repair):
use~-~  benchup benchdown benchrestart benchstatus benchlogs benchfg benchwatch benchdoctor benchcd
use~-~
use~-~Documentation: {docs}
TABLE
}

# fl_usage_text: the global help from the records
fl_usage_text() {
  fl_usage_table | sed -e 's/^use~[^~]*~//' -e 's/{tilde}/~/g' -e "s|{version}|${FL_VERSION}|" -e "s|{docs}|$(fl_docs_url /)|"
}

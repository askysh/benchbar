---
title: "Doctor checks: the bench"
description: "The doctor checks of the bench group: the env, the toolchain, assets, apps, the lockfile and profile, logs and kept backups. What each looks at and its fix."
---

Part of the [doctor checks](../doctor-checks.md). `benchbar doctor` prints the id of a check, and each id below is a heading you can link to. How to read the report is in [Doctor and repair](../../guides/doctor-and-repair.md).

## Bench checks

### env_python

`env/bin/python` exists, runs, and is the Python version the profile
expects.

Fix: stop the bench first (`benchdown`), then `benchbar repair` rebuilds
the env; the old one is moved to `env.broken.<timestamp>`. Repair
refuses to rebuild the env while the bench runs. When no profile matches the bench's Frappe (a
`develop` or v17 bench with no stored profile: doctor's header then says
`profile v15-lts (default: no profile matches this bench)`), the Python
to rebuild with is unknown, so a version mismatch is only a warning, no
rebuild is offered, and the fix is `benchbar install --profile NAME`.

### env_setuptools

On Frappe v15, `env/bin/python` imports `pkg_resources`: bench and honcho
need it, setuptools 70 and later dropped it, and an env made with Python
3.12 or newer has no setuptools at all. Skipped on other versions.

Fix: `benchbar repair` installs `setuptools<70` into the env (an env
rebuild on v15 does the same).

### bench_version

`bench version` works in the bench folder. The message also says whether
pipx or uv owns `bench`. A failure is classified first: a missing `bench`
command, or one whose own venv is broken (exit 126 or 127), is the CLI's
problem and gets `uv tool install frappe-bench==5.31.1` or the pipx equivalent (`pipx install frappe-bench==5.31.1`);
an app in `sites/apps.txt` that does not import is named, with `bench
setup requirements --python` as the fix. Neither moves the env aside.

Fix: `benchbar repair` rebuilds the env only when frappe itself does not
import and the profile is this bench's (stored or detected).

### toolchain_node

The `node` the bench's processes see (launchd's `PATH`, not your shell's)
has the major version the profile expects. nvm's node is only on your
shell's `PATH`, so the bench does not see it.

Fix: `brew install <node formula>`; the bench's `PATH` puts it first.
When the profile's formula is not installed (a profile that moved to a
newer Node), `benchbar repair` runs the install (`node_install`); the old
formula is never removed.

### toolchain_yarn

`yarn` is on the bench's `PATH`. `bench build` needs it.

Fix: `npm install -g yarn@1.22.22` with the bench's npm; `benchbar repair` runs
it (`yarn_install`), since yarn is global to one node formula.

### toolchain_uv

`uv` is installed (on your `PATH`, in Homebrew's `bin` or in
`~/.local/bin`). frappe-bench 5.31 and later make the bench env with
`uv venv` and install into it with `uv pip install`, whoever installed
the `bench` command itself. A Mac set up before 0.9.0 with a pipx bench
may have none: an env rebuild, `benchbar app add` and `benchbar app
update` then stop before they change anything and name this fix.

Fix: `brew install uv`; `benchbar repair` runs it (`uv_install`), before
it rebuilds an env. On Linux the fix is the system dependencies script
(`00-linux-system-deps.sh`), which installs the pinned `uv`; repair has
no action for it there.

### mariadb_version

A MariaDB server listens on 3306 and its version is in the range the
profile accepts: 10.6 to 10.11 for v15, 10.6 to 11.8 for v16. Outside the
range is a warning, as it is in Frappe.

Fix: `brew services start <mariadb formula>` when nothing listens;
`brew install <mariadb formula>` for a version outside the range.

### toolchain_pkgconfig

`pkg-config` is on the bench's `PATH` and finds `mariadb-connector-c`.
`mysqlclient` for frappe v16 needs both.

Fix: `brew install pkgconf mariadb-connector-c`.

### socketio

`apps/frappe/node_modules/socket.io` exists. Without it socketio fails
with "Cannot find module 'socket.io'".

Fix: `benchbar repair` runs `bench setup requirements --node`.

### assets

`sites/assets/assets.json` exists and every dist file it references is
there. Missing files make the site load without styling.

Fix: `benchbar repair` runs `bench build`.

### apps_txt

Every app in `sites/apps.txt` has a folder in `apps/`, and every git app
in `apps/` is listed. A listed app without a folder fails, because every
bench command then fails to import it. An unlisted git app is a warning:
usually a `get-app` that did not finish.

Fix: `benchbar app add <app>` for a missing app. For an unlisted one, move
the folder aside, then `benchbar app add <its git URL>`. Repair has no
action here: changing code is your call.

### app_branch_policy

Each git app is on the branch `config/apps.tsv` names for the profile.

Fix: `git fetch` and `git checkout` the policy branch in the app, only if
you meant to follow the policy. Repair has no action here.

### app_update_pending

One warning for each `benchbar app update` that stopped after it had
started changing things (a failed backup, requirements, migrate, build or
restart). The row names the step it stopped at, why, and how many steps
are left. Nothing is wrong with the bench's files: the update is simply
not finished, and an app that is already at its new commit would otherwise
look up to date while its migrate never ran.

Fix: run `benchbar app update <app>` again. It runs the steps that did
not finish and nothing else, then removes the record. `--discard-pending`
drops the record and stops: no step and no update runs, so run the update
again afterwards if you still want it. An unreadable (cut short) record is
kept, nothing runs from it, and doctor says so. Doctor reads the record only, no
git and no bench. Repair has no action here.

### app_add_pending

The same for the planned `benchbar app add` (`--dry-run --json`, then
`--apply`): a build, an install or a restart that did not finish. A failed
build also skips the install, so the app is not installed on a site whose
assets were never built.

Fix: `benchbar app add <app>` again. The next plan lists the steps that
are left, with the reason, and applying it runs them. Repair has no action
here.

### dependency_behind

One warning for each app a focus app needs (its `required_apps` in
`hooks.py`, followed through other apps) that is behind its remote
branch, for example `exponent_custom_v1 (needed by exponent_ecr) is 30
commits / 12 days behind upstream/develop`. Commits and days follow the
remote branch itself (git's first parent line): the commits it got after
yours, and the age of the first of them. What a merge brought in from
other branches or older history does not count, so a release merged in
is one commit. A focus app itself never gets this warning: you pull the
app you work on yourself. See
[focus apps](../../guides/apps.md#focus-apps-and-their-dependencies).

Doctor stays read only and never fetches on its own: the numbers come
from the remote branches as git last fetched them, your own `git fetch`
included. When benchbar has not fetched them in the last day, the row
says so ("as of a fetch 3 days ago") and the OK line says to run
`benchbar doctor --fetch`. That fetches the focus apps' dependencies
first, with a 20 second timeout each and never a password prompt; only
`.git` changes. It never runs with `OFFLINE=1` or `--dry-run`. An app
never fetched is reported as unknown, and a fetch that fails is no
failure either.

Fix: `benchbar app update <app>`, which shows the changelog, backs up
the sites that have the app, fast forwards it and migrates. A dependency
with local changes gets `git status` first. Never `bench update`.

### apps_behind

One line about every other app: neither a focus app nor needed by one.
It reads the remote branches as they were last fetched (even `doctor
--fetch` does not fetch these) and is always OK.

### lock_parse

The bench's `benchbar.toml` lockfile, when one is set, exists and parses.
See [the team lockfile](../../guides/teams.md#the-team-lockfile).

Fix: correct the file by hand, or write it again with `benchbar lock
write`. A lockfile path that does not exist yet: `benchbar lock write
--lock <path>`.

### lock_drift

The bench matches its lockfile: the same apps, repos, branches and
pinned commits. Drift is a warning.

Fix: `benchbar lock apply` (`benchbar lock check` lists the differences).

### profile_outdated

The bench's team profile comes from a subscription whose clone is behind
its remote, as of the clone's last fetch. Doctor itself never fetches;
`benchbar doctor --fetch` fetches the subscription first (not with
`BENCHBAR_OFFLINE=1`), and the message says when the last fetch is
older than a day. See
[Sharing a profile](../../guides/teams.md#sharing-a-profile).

Fix: `benchbar profile update NAME` (shows the changes and asks).

### logs

`bench.log`, `worker.log` and `worker.error.log` are under 50 MB each.

A running bench keeps them small on its own: its runner cuts a log over
20 MB to its last lines (see
[Troubleshooting](../../troubleshooting.md)). The check still warns for a
bench that was stopped with a large log, or one started by an older
runner.

Fix: `benchbar repair` copies each large log to `<name>.old.<stamp>` and
empties the live file in place, so the bench's processes keep writing to
the file they have open. At most three copies are kept.

### kept_backups

A site's older backups that a run of bench's backup did not put back.
Before bench takes a backup (`site backup`, the backup first of `site
restore`, `site drop`, `pull --replace`, `app update`), benchbar holds a
second name for each file of the site's backup folder in the state
folder, because bench deletes backups older than 23 hours. When benchbar
is killed before it puts them back, or a file could not go back (the
folder is read only, or the site was dropped and no archive was found),
that copy may be the only one. benchbar never prunes such a folder. The
row names the site, the number of files and the folder.

Fix: `benchbar repair` puts the files back into the site's backup
folder (the archived folder of a dropped site). So does the next backup
of any site, which says so in `changed[]`. A file whose name is taken by
a different file is left where it is and named in a warning.

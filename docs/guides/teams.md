---
title: "Teams: profiles, lockfile and pull"
description: "Give every developer the same bench: team profiles as the recipe, the benchbar.toml lockfile as the exact state, and benchbar pull for a local copy of production."
---

Three tools keep a team's benches alike. A team profile is the recipe for
a new bench. The lockfile pins the exact commits every bench should run.
`benchbar pull` brings a copy of a production site into a local one.

## Team profiles

A team profile is your organisation's bench recipe: a small TOML file
that names a built in base profile and your apps with their repos and
branches. It lives outside BenchBar, in
`~/.config/benchbar/profiles/NAME.toml` or in a clone of your team's
config repo listed in `BENCHBAR_PROFILE_PATH`.

```toml
# ~/.config/benchbar/profiles/acme.toml
base = "v15-lts"                  # Python, Node and MariaDB come from here
site = "acme.localhost"
scheduler = false

[[apps]]
name = "erpnext"
repo = "https://github.com/frappe/erpnext"
branch = "version-15"

[[apps]]
name = "acme"
repo = "git@github.com:acme/acme.git"
branch = "main"
```

```bash
benchbar profile create acme --from-bench ~/frappe-bench   # write one from a bench you have
benchbar profile list                                     # built in and team profiles
benchbar profile show acme
benchbar install --profile acme                           # a new Mac, the same bench
```

The file is a strict subset of TOML (strings, booleans, integers and
one line lists; no escapes, no inline tables), and a repo URL with a
user name or token is refused, since the file is meant to be committed.
Every key is listed in [Configuration](../reference/configuration.md#team-profile-files).

A built in profile of the same name wins. The BenchBar window's Team
Profiles page lists them too.

## The team lockfile

A team profile is the recipe; `benchbar.toml` is the exact state, so
every developer's bench runs the same commits. Keep it in your main
custom app and commit it there:

```bash
benchbar lock write --lock apps/acme/benchbar.toml   # once; the path is remembered
benchbar lock check                                  # read only, exit 1 on any difference
benchbar lock apply --dry-run                        # what a teammate's bench would change
benchbar lock apply
```

`lock apply` clones missing apps, switches clean apps to the locked
branch and fast forwards to pinned commits, then runs requirements and
build. It never touches a site (it prints the `site add`, `app install`
and migrate steps instead) and never overwrites local work: an app with
local changes or commits of its own is skipped with a warning. Doctor
reports drift as a warning ([`lock_drift`](doctor-and-repair.md#lock_drift)).

The file pins each app's repo, branch and, optionally, commit, in the
order of `sites/apps.txt`, plus the sites and the apps each one has:

```toml
schema = 1
[bench]
profile = "v15-lts"
frappe_bench = "5.31.0"
[[app]]
name = "erpnext"
repo = "https://github.com/frappe/erpnext"
branch = "version-15"
commit = "b5f784612d5b7969b72848dda5b22f10d3a8f764"
[[site]]
name = "acme.localhost"
default = true
apps = ["erpnext", "acme"]
```

benchbar finds the file from `--lock PATH`, then `BENCHBAR_LOCK`, then the
path remembered for the bench, then `<bench>/benchbar.toml`. A bench is
rarely a git repo itself, which is why the file usually lives in your
custom app.

## A copy of production

```bash
benchbar pull prod:erp.example.com --as erpcopy --dry-run   # read only, prints the plan
benchbar pull prod:erp.example.com --as erpcopy             # asks before it restores
benchbar pull --from-dir ~/Downloads/erp-backup --as erpcopy   # a Frappe Cloud download
```

`prod` is a Host from `~/.ssh/config`. Pull takes the latest backup that
already exists on the server, so nothing is written there (`--new-backup`
runs `bench backup` first, which also deletes older backups on the server,
so it asks you to type the site name). The download resumes when the link
drops. The copy always goes into a new local site (`--replace` backs an
existing one up first), gets the production `encryption_key` so stored
passwords still decrypt, has email muted and the scheduler paused before it
ever starts, and runs `bench migrate` when your apps are newer. When the
bench lacks an app production has, pull stops and prints the
`bench get-app` command; `--skip-app APP` restores without it. Encrypted
backups are decrypted locally with `gpg` (`brew install gnupg`).

The encryption key and the passwords never appear on a command line, in
the output or in the log. The download is kept in
`<bench>/.benchbar/pulls/` after a failed run, so the next run resumes;
a successful run removes it unless you pass `--keep-staging`.

Every flag is in the [pull reference](../reference/cli/pull.md). When
passwords do not decrypt after a restore by hand, see
[Troubleshooting](../troubleshooting.md).

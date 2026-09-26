---
title: "lock"
description: "benchbar lock write, check and apply: the benchbar.toml team lockfile with each app's repo, branch and commit, and the sites."
---

`benchbar.toml`, the team lockfile: each app's repo, branch and commit,
and the sites. The guide is [Teams](../../guides/teams.md#the-team-lockfile).
Every command takes `--lock PATH`; without it benchbar uses
`BENCHBAR_LOCK`, then the path remembered for the bench, then
`<bench>/benchbar.toml`.

## lock write

```
benchbar lock write [--lock PATH] [--no-commits] [--allow-dirty]
```

Writes the lockfile from this bench. It asks, shows the diff, and backs
up the old file.

| Flag | What it does |
|---|---|
| `--lock PATH` | Where to write it; the path is remembered for the bench |
| `--no-commits` | Pin branches only, no commits |
| `--allow-dirty` | Write it even when an app has local changes |

Exit codes: 0 written or unchanged; 1 declined or refused.

```bash
benchbar lock write --lock apps/acme/benchbar.toml
```

## lock check

```
benchbar lock check [--lock PATH] [--json]
```

Compares the bench with the lockfile. Read only: no network, no
database.

| Flag | What it does |
|---|---|
| `--json` | The differences as JSON ([schema](../../json-schema.md#benchbar-lock-check---json)) |

Exit codes: 0 the bench matches; 1 any difference, or no readable
lockfile.

```bash
benchbar lock check --json
```

## lock apply

```
benchbar lock apply [--lock PATH] [--dry-run] [--yes]
```

Clones missing apps, switches clean apps to the locked branch, fast
forwards to pinned commits, then runs requirements and build. It never
touches a site (it prints the `site add`, `app install` and migrate steps
instead) and never overwrites local work: an app with local changes or
commits of its own is skipped with a warning.

| Flag | What it does |
|---|---|
| `--dry-run` | Print what would change |
| `-y`, `--yes` | Apply without asking |

Exit codes: 0 applied or nothing to do; 1 a step failed.

```bash
benchbar lock apply --dry-run
```

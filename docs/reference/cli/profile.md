---
title: "profile"
description: "benchbar profile list, show, create, export, import, subscribe, update, remove and check: built in and team profiles, and sharing them."
---

Release profiles and team profiles. The guide is
[Teams](../../guides/teams.md#team-profiles), the file format is in
[Configuration](../configuration.md#team-profile-files).

## profile list

```
benchbar profile list [--json]
```

Built in and team profiles, with where each comes from.

| Flag | What it does |
|---|---|
| `--json` | The list as JSON ([schema](../../json-schema.md#benchbar-profile-list---json)) |

Exit codes: 0.

```bash
benchbar profile list
```

## profile show

```
benchbar profile show NAME
```

What a profile installs: base, Python, Node, MariaDB, apps.

Exit codes: 0; 1 when there is no such profile or its file does not
parse.

```bash
benchbar profile show acme
```

## profile create

```
benchbar profile create NAME --from-bench PATH [--dir DIR]
```

Writes a team profile from a bench. It only reads the bench: the app
repos and branches, and the base from its frappe version. `benchbar
install --profile NAME` then builds the same bench on another Mac.

| Flag | What it does |
|---|---|
| `--from-bench PATH` | The bench to read |
| `--dir DIR` | Write `NAME.toml` into DIR instead of `~/.config/benchbar/profiles` |

Exit codes: 0; 1 when the name is not valid, the path is not a bench, or
a repo URL carries credentials.

```bash
benchbar profile create acme --from-bench ~/frappe-bench   # your bench's folder
```

## profile export

```
benchbar profile export NAME [--out FILE] [--branch APP=BR]... [--drop APP]... [--plan]
```

Writes a copy of a team profile to share. Each repo URL loses its user
info and its SSH alias (`ssh -G` gives the real host name, so
`git@github-work:acme/x.git` becomes `git@github.com:acme/x.git`). Each
app follows its repo's default branch, except an app of the built in
registry on its release branch (erpnext on `version-15`), which keeps it.
Each app gets `access` (`public`, `private`, `personal` or `unknown`) and
`requires` (from the bench's `hooks.py` when the profile does not say).
The review lists app, access, the branch before and after, and requires;
then the file is shown and written after you confirm. The file is
schema 2.

| Flag | What it does |
|---|---|
| `--out FILE` | Where to write (default `./NAME.toml`) |
| `--branch APP=BR` | Export APP on BR instead of its default branch; repeatable |
| `--drop APP` | Leave APP out; repeatable. Refused when a kept app requires it |
| `--plan` | Print the review only, write nothing (`--json`: [schema](../../json-schema.md#benchbar-profile-export-name---plan---json)) |

Exit codes: 0; 1 when the profile does not exist, a drop is refused or
you do not confirm.

```bash
benchbar profile export acme --out ~/acme.toml --bench-dir ~/frappe-bench
```

## profile import

```
benchbar profile import FILE|URL [--as NAME] [--plan]
```

Adds a profile someone sent to `~/.config/benchbar/profiles/NAME.toml`,
with `source` set so `profile update` can fetch it again. URLs must be
https; a GitHub file page or a gist page is fetched raw. The file may be
64 KB at most and must parse before anything is written. A built in name
is refused; an existing file is diffed and replaced only after you
confirm. Then every repo is checked with your credentials.

| Flag | What it does |
|---|---|
| `--as NAME` | The profile name (default: the file name without `.toml`) |
| `--plan` | Show the profile, the diff and the check, write nothing |

Exit codes: 0; 1 when the source cannot be read or does not parse, or you
do not confirm.

```bash
benchbar profile import https://github.com/acme/bench-config/blob/main/acme.toml
```

## profile subscribe

```
benchbar profile subscribe GIT_URL [--plan]
```

Clones a team's config repo into `~/.config/benchbar/sources/OWNER-REPO/`
and adds it to `~/.config/benchbar/sources.list`. Its profiles are the
`*.toml` files in its `profiles/` folder, or at its root when it has
none; nothing else in it is read or run. Subscriptions come after your
own folder and before `BENCHBAR_PROFILE_PATH` on the lookup path.

| Flag | What it does |
|---|---|
| `--plan` | Clone to a temporary folder, list the profiles, keep nothing |

Exit codes: 0; 1 when git cannot clone it, it holds no valid profile, or
you do not confirm.

## profile update

```
benchbar profile update NAME|--all [--plan]
```

Fetches an imported profile's source, or a subscription, again and shows
what changed. An import is replaced after you confirm (with a backup); a
subscription is fast forwarded after you confirm. Nothing updates on its
own. NAME may be a profile or a subscription folder name.

| Flag | What it does |
|---|---|
| `--all` | Every import and every subscription |
| `--plan` | Fetch and show the changes, apply nothing |

Exit codes: 0; 1 when NAME was not imported or subscribed, or a change
was not applied.

## profile remove

```
benchbar profile remove NAME
```

Moves an imported file, or a whole subscription (every profile in it),
to `~/.config/benchbar/removed/<timestamp>/`. Your own files and
`BENCHBAR_PROFILE_PATH` folders are never touched.

Exit codes: 0; 1 when NAME is your own file or you do not confirm.

## profile check

```
benchbar profile check NAME [--json]
```

Asks git whether each repo and branch of a team profile can be read with
your own keys and tokens (no prompt, 10 seconds per repo, 5 seconds to
connect). The repos are asked side by side, 8 at a time, and a repo that
two apps share is asked once. A timed out git is stopped with the ssh it
started. A repo that answered yes is kept for 5 minutes (so `check` and
`install --profile NAME` right after it do not both ask the same repo); a
no or a timeout is always asked again. `install` still asks the network for
every app before it plans or changes anything, so a branch deleted within
those 5 minutes stops it before its plan, with `Branch/tag ... not found`.
Lists the apps `install --profile NAME` would leave out: the unreachable
ones and every app that requires one.

Exit codes: 0 whatever the answer; 1 when there is no such profile.

```bash
benchbar profile check acme
```

## Flags, needs and environment

These tables come from the code (`benchbar commands --json`); the sections above explain them.

<!-- generated:cli-commands profile -->
<!-- Generated by scripts/docs-reference.py from the code. Edit the code, then run: python3 -I scripts/docs-reference.py --write -->

| Command | Terminal | `sudo` | Network | Changes things | JSON |
|---|---|---|---|---|---|
| `benchbar profile list\|show\|create\|export\|import\|subscribe\|update\|remove\|check ...` | no | no | no | no | none |
| `benchbar profile list [--json]` | no | no | no | no | document |
| `benchbar profile show NAME` | no | no | no | no | none |
| `benchbar profile create NAME --from-bench PATH [--dir DIR]` | no | no | no | yes | none |
| `benchbar profile export NAME [--out FILE] [--plan] [--json]` | no | no | yes | yes | document |
| `benchbar profile import FILE\|URL [--as NAME] [--plan] [--json]` | yes | no | yes | yes | document |
| `benchbar profile subscribe GIT_URL [--plan\|--yes] [--json]` | yes | no | yes | yes | document |
| `benchbar profile update NAME\|--all [--plan] [--json]` | yes | no | yes | yes | document |
| `benchbar profile remove NAME [--yes] [--json]` | yes | no | no | yes | document |
| `benchbar profile check NAME [--json]` | no | no | yes | no | document |

Terminal: may ask a question on a terminal. `sudo`: may run `sudo`. Network: may reach the network.
JSON: `document` is one JSON line, `stream` is JSON lines ending in a `done` line.

| Command | Flag | Value | What it does |
|---|---|---|---|
| `profile export` | `--out` | `FILE` | Where to write (default ./NAME.toml). |
| `profile export` | `--branch` | `APP=BR` | Export APP on BR instead of its default branch; repeatable. |
| `profile export` | `--drop` | `APP` | Leave APP out of the copy; repeatable. Refused when a kept app requires it. |
| `profile export` | `--plan` |  | Print the review only, write nothing. |
<!-- /generated:cli-commands -->

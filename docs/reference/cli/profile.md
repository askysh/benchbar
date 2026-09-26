---
title: "profile"
description: "benchbar profile list, show and create: built in release profiles and team profiles, and writing a team profile from a bench you have."
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
benchbar profile create acme --from-bench ~/frappe-bench
```

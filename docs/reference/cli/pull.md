---
title: "pull"
description: "benchbar pull copies a production site over SSH, or a downloaded backup, into a new local site with email muted and the scheduler paused. Flags, exit codes and examples."
---

```
benchbar pull HOST:SITE [--as NAME] [flags]
benchbar pull --from-dir DIR --as NAME [flags]
```

Copies a production site over SSH into a NEW local site: the latest
backup on the server (nothing is written there), the encryption key,
email muted and the scheduler paused. HOST is a Host from
`~/.ssh/config`. The guide is
[Teams](../../guides/teams.md#a-copy-of-production).

Every run is check, plan, apply, verify: the checks read the server and
the bench, the plan shows the backup, its size and the apps, and the
restore asks first. `--dry-run` stops after the plan.

| Flag | What it does |
|---|---|
| `--as NAME` | Local site name (default: `SITE.local`) |
| `--from-dir DIR` | A backup set downloaded by hand (Frappe Cloud), no SSH |
| `--remote-bench D` | The bench folder on the server (default `~/frappe-bench`) |
| `--new-backup` | Run `bench backup` on the server first (it also deletes older backups there); asks for the site name |
| `--confirm-site SITE` | With `--new-backup`: the site name, instead of typing it |
| `--replace` | Restore over an existing local site, after backing it up |
| `--skip-app APP` | Restore without APP (its tables stay behind as orphans); repeat for more apps |
| `--no-files` | Database only |
| `--no-migrate` | Stop after the restore and the dev safety, before `bench migrate` |
| `--before-migrate SCRIPT` | Run the executable SCRIPT after the restore, before migrate, in the bench folder, with `BENCHBAR_SITE`, `BENCHBAR_BENCH` and `BENCHBAR_DB_NAME`; variables named like a secret are removed from its environment, and a failing script stops the run |
| `--keep-scheduler` | Leave the scheduler as production has it |
| `--keep-staging` | Keep the downloaded backup in `<bench>/.benchbar/pulls/` after a successful run |
| `--dry-run` | Print the plan, change nothing |
| `-y`, `--yes` | Do not ask |
| `--json` | JSON lines while it runs ([schema](../../json-schema.md#benchbar-pull---json)) |

The local site is created (`bench new-site`) when it does not exist, as
a step of the plan. A target the restore cannot go into stops the check,
`--dry-run` included, instead of failing at its first step: a folder in
`sites/` without a `site_config.json` (move it aside), a `new-site` that
did not finish, MariaDB not running, or no MariaDB root password.

When the bench lacks an app production has, pull stops and prints the
`bench get-app` command. Encrypted backups are decrypted locally with
`gpg` (`brew install gnupg`).

Exit codes: 0 the copy is ready; 1 a check or step failed, or you
declined; 2 the MariaDB root password is unknown (pass
`MARIADB_ROOT_PASSWORD`).

```bash
benchbar pull prod:erp.example.com --as erpcopy --dry-run
```

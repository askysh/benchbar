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
| `--keep-scheduler` | Leave the scheduler as production has it |
| `--keep-staging` | Keep the downloaded backup in `<bench>/.benchbar/pulls/` after a successful run |
| `--dry-run` | Print the plan, change nothing |
| `-y`, `--yes` | Do not ask |
| `--json` | JSON lines while it runs ([schema](../../json-schema.md#benchbar-pull---json)) |

When the bench lacks an app production has, pull stops and prints the
`bench get-app` command. Encrypted backups are decrypted locally with
`gpg` (`brew install gnupg`).

Exit codes: 0 the copy is ready; 1 a check or step failed, or you
declined; 2 the MariaDB root password is unknown (pass
`MARIADB_ROOT_PASSWORD`).

```bash
benchbar pull prod:erp.example.com --as erpcopy --dry-run
```

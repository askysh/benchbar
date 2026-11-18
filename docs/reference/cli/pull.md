---
title: "pull"
description: "benchbar pull copies a production site over SSH, or a downloaded backup, into a new local site with email muted, the scheduler paused, outbound integrations off and stored secrets cleared. Flags, exit codes and examples."
---

```
benchbar pull HOST:SITE [--as NAME] [flags]
benchbar pull --from-dir DIR --as NAME [flags]
```

Copies a production site over SSH into a NEW local site: the latest
backup on the server (nothing is written there), the encryption key,
email muted and the scheduler paused. Since 0.9 the copy is also
neutralised: outbound integrations are off and stored secrets are
cleared, unless you pass `--keep-secrets`. HOST is a Host from
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
| `--keep-secrets` | Do not neutralise the copy: integrations, webhooks and stored passwords stay as production had them (the 0.8 behaviour). The copy still has email muted and the scheduler paused |
| `--keep-staging` | Keep the downloaded backup in `<bench>/.benchbar/pulls/` after a successful run |
| `--dry-run` | Print the plan, change nothing |
| `-y`, `--yes` | Do not ask |
| `--json` | JSON lines while it runs ([schema](../../json-schema.md#benchbar-pull---json)) |

## What the copy loses

By default a step after the restore (before `bench migrate`) runs one
routine on the copy, the same one that prepares the room copy of
[`benchbar share`](share.md). It changes the copy only, through the
bench's own Python, never through `mariadb`:

| What | Change |
|---|---|
| Every stored password (the `__Auth` table: all `Password` fields, such as SMTP, IMAP, LDAP, S3, payment, OAuth client and webhook secrets, and the passwords of users) | deleted, except the Administrator login |
| Email Account | outgoing and incoming off |
| Email Queue | mail that was not sent yet is dropped |
| Auto Email Report, Notification, Webhook, Social Login Key, Auto Repeat | switched off |
| Webhook Request Log, Integration Request | emptied |
| Slack Webhook URL, SMS gateway URL and parameters, OAuth Client secret, API keys and open password reset keys of users | blanked |
| OAuth Bearer Token, OAuth Authorization Code, Token Cache (the Connected App tokens) | emptied |
| Google Calendar, Contacts, Drive, Settings and indexing | off, plain keys blanked |
| Dropbox and S3 Backup Settings, LDAP Settings, Push Notification Settings, Plaid Settings | off, plain keys blanked |
| Razorpay, Stripe, PayPal, Braintree, M-Pesa and Paytm settings | plain key ids blanked |
| Scheduled Job Type | jobs that send mail, read a mailbox, upload backups or call an outside service are stopped |
| Server Script | scripts that make HTTP requests are disabled |

The line `neutralised SITE: ...` in the output, and `neutralised` in the
`done` line of `--json`, say how many rows each part changed. Not
touched: customer data (names, emails, phones, addresses, documents). A
doctype of an app the bench does not have is skipped, and the settings
of an app benchbar does not know (a WhatsApp or SMS app, for example)
keep their plain fields: switch those off yourself.

Because every other user's password is cleared, log in as
Administrator with the password you set (`ADMIN_PASSWORD` or the
prompt) and set the others from the User form. To undo a job stop, open
Scheduled Job Type and clear Stopped. To get production's integrations
and passwords back, pull again with `--keep-secrets` (and `--replace`):
the cleared rows are not recoverable from the copy.

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

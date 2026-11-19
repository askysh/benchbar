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

For an agent or an app the plan has a token: `benchbar pull ... --dry-run
--json` prints it on the `plan` line, and `benchbar pull ... --apply TOKEN
--yes --json` (the same arguments) runs that plan without a question. The
token is a hash of the plan: the backup's name, the apps and their status,
the steps, the site, the bench, the host and whether the copy is
neutralised, and of the flags that change the run (`--no-files`,
`--keep-scheduler`, the content of the `--before-migrate` script). It
leaves out the backup's size and age, which move with the clock. The run
makes the plan again after its checks; when it is not the same, it stops
with "The plan changed since it was shown; nothing was changed" (exit 1)
and changes nothing. `--new-backup` still needs the site name typed or
`--confirm-site`, with a token too. Without `--apply`, a person at a
terminal is asked as before.

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
| `--dry-run` | Print the plan and its token, change nothing |
| `--apply TOKEN` | Run exactly the plan whose token `--dry-run --json` printed (with `--yes`); refused when the plan changed since, for example a newer backup on the server |
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
| Email Account | outgoing and incoming off, API key blanked |
| Email Queue | mail that was not sent yet is dropped |
| Auto Email Report, Notification, Webhook, Social Login Key, Auto Repeat, and (Frappe v16) Automation Flow | switched off |
| Webhook (request URL) and Webhook Header (value) | blanked, not only switched off: a URL or header often holds the key |
| Webhook Request Log, Integration Request | emptied |
| Slack Webhook URL, SMS gateway URL and parameters, OAuth Client secret, API keys and open password reset keys of users | blanked |
| OAuth Bearer Token, OAuth Authorization Code, Token Cache (the Connected App tokens) | emptied |
| Google Calendar, Contacts, Drive, Settings and indexing | off, plain keys blanked |
| Website Settings: Google Analytics id | blanked |
| Dropbox and S3 Backup Settings, LDAP Settings, Push Notification Settings, Plaid Settings | off, plain keys blanked |
| Razorpay, Stripe, PayPal (user name and signature, both plain `Data` fields), Braintree, M-Pesa (consumer key and security credential), Paytm and GoCardless (access token and webhook secret) settings, and the Plaid access token of a Bank | plain keys blanked |
| ERPNext Video Settings (API key) and Currency Exchange Settings (access key, endpoint, url) | blanked |
| Scheduled Job Type | jobs that send mail, read a mailbox, upload backups or call an outside service are stopped, among them the payments job `razorpay_settings.capture_payment` and the v16 job `frappe.flow.knowledge.ingest.sync_due_sources` |
| Server Script | scripts that make HTTP requests are disabled |

The line `neutralised SITE: ...` in the output, and `neutralised` in the
`done` line of `--json`, say how many rows each part changed. Not
touched: customer data (names, emails, phones, addresses, documents). A
doctype of an app the bench does not have is skipped, and the settings
of an app benchbar does not know (a WhatsApp or SMS app, for example)
keep their plain fields: switch those off yourself.

Because every other user's password is cleared, log in as
Administrator and set the others from the User form. Which password
Administrator has depends on how you ran it: with `ADMIN_PASSWORD` (or
the answer at the prompt) it is the one you set. Without it (`--yes`, no
terminal, or you declined the prompt), production's Administrator
password works on the copy: the restore brought it along and neutralise
keeps that one login. To undo a job stop, open
Scheduled Job Type and clear Stopped. To get production's integrations
and passwords back, pull again with `--keep-secrets` (and `--replace`):
the cleared rows are not recoverable from the copy.

The local site is created (`bench new-site`) when it does not exist, as
a step of the plan. A target the restore cannot go into stops the check,
`--dry-run` included, instead of failing at its first step: a folder in
`sites/` without a `site_config.json` (move it aside), a `new-site` that
did not finish, MariaDB not running, or no MariaDB root password.

When a step fails after the restore and before the copy is neutralised,
the run says so: the copy still holds production's secrets and
integrations. Do not start its scheduler or workers; run the same pull
with `--replace` once the cause is fixed.

When the bench lacks an app production has, pull stops and prints the
`bench get-app` command. Encrypted backups are decrypted locally with
`gpg` (`brew install gnupg`).

Exit codes: 0 the copy is ready; 1 a check or step failed, you declined,
or the plan changed since its token was made; 2 the MariaDB root password
is unknown (pass `MARIADB_ROOT_PASSWORD`). With `--json` and no terminal
that holds for the dry run too: it stops with exit 2 and no plan line
instead of listing the password as a need.

```bash
benchbar pull prod:erp.example.com --as erpcopy --dry-run
```

## Flags, needs and environment

These tables come from the code (`benchbar commands --json`); the sections above explain them.

<!-- generated:cli-commands pull -->
<!-- Generated by scripts/docs-reference.py from the code. Edit the code, then run: python3 -I scripts/docs-reference.py --write -->

| Command | Terminal | `sudo` | Network | Changes things | JSON |
|---|---|---|---|---|---|
| `benchbar pull HOST:SITE [--as NAME] [--from-dir DIR] [--replace] [--dry-run\|--apply TOKEN --yes] [--json]` | yes | no | yes | yes | stream |

Terminal: may ask a question on a terminal. `sudo`: may run `sudo`. Network: may reach the network.
JSON: `document` is one JSON line, `stream` is JSON lines ending in a `done` line.

| Command | Flag | Value | What it does |
|---|---|---|---|
| `pull` | `--as` | `NAME` | Local site name (default SITE.local). |
| `pull` | `--from-dir` | `DIR` | A backup set downloaded by hand, no SSH. |
| `pull` | `--remote-bench` | `DIR` | The bench folder on the server. |
| `pull` | `--new-backup` |  | Run bench backup on the server first. |
| `pull` | `--keep-secrets` |  | Keep the copy's integrations and stored secrets (by default they are switched off and cleared). |
| `pull` | `--replace` |  | Restore over an existing local site, after backing it up. |
| `pull` | `--confirm-site` | `SITE` | With --new-backup: the site name, instead of typing it. |
| `pull` | `--skip-app` | `APP` | Restore without APP (its tables stay behind as orphans); repeat for more apps. |
| `pull` | `--no-files` |  | Database only. |
| `pull` | `--no-migrate` |  | Stop after the restore and the dev safety, before bench migrate. |
| `pull` | `--before-migrate` | `SCRIPT` | An executable run after the restore, before migrate, in the bench folder, with BENCHBAR_SITE, BENCHBAR_BENCH and BENCHBAR_DB_NAME; a failing script stops the run. |
| `pull` | `--keep-scheduler` |  | Leave the scheduler as production has it. |
| `pull` | `--keep-staging` |  | Keep the downloaded backup in the bench's .benchbar/pulls/ after a successful run. |
| `pull` | `--dry-run` |  | Print the plan and its token, change nothing. |
| `pull` | `--apply` | `TOKEN` | Run exactly that plan (with --yes); refused when the plan changed since the token was made. |

| Command | Environment variable | What it does |
|---|---|---|
| `pull` | `MARIADB_ROOT_PASSWORD` | Only when MariaDB has a password benchbar does not know. |
<!-- /generated:cli-commands -->

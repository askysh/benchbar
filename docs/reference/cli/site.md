---
title: "site"
description: "benchbar site list, add, default, hosts, open-as, backup, backups, restore and drop: the sites of a bench, their backups, restoring one, and dropping one safely."
---

The sites of a bench. The guide is
[Benches and sites](../../guides/benches-and-sites.md#sites). Every
command takes the [options for every command](install.md#options-for-every-command).

## site list

```
benchbar site list [--json] [--bench-dir DIR]
```

Every site of the bench; the default one, the site `benchup` waits for,
is marked. `benchbar site` alone does the same. With `--json`: each
site's name, whether it is the default, whether `/etc/hosts` has it, its
ping code, its `db_name` and its `db_port` (never the password)
([schema](../../json-schema.md#sites)).

Exit codes: 0; 1 when no bench is found.

```bash
benchbar site list --json
```

## site add

```
benchbar site add NAME [--bundle NAME | --apps "a b"] [--dry-run] [--yes] [--json]
```

`bench new-site` on the bench's MariaDB with the root password from the
Keychain, the site's `/etc/hosts` line, and optionally apps that are
already in `apps/`. The default site stays as it is. It asks for the new
site's Administrator password, or reads `ADMIN_PASSWORD`.

| Flag | What it does |
|---|---|
| `--bundle NAME` | Install the apps of a bundle (`minimal`, `common`, `extended`) |
| `--apps "a b"` | Install these apps, which must be in `apps/` already |
| `--dry-run` | Print the plan and its token, change nothing in the bench (the first plan creates the plan key, once) |
| `-y`, `--yes` | Do not ask; `ADMIN_PASSWORD` must be set |
| `--json` | JSON lines ending in a `done` with the site and the default site ([the done fields](../../json-schema.md#the-done-fields-08)) |

With `BENCHBAR_NONINTERACTIVE=1` (or `--for-agent`) it asks for nothing.
It first names every missing input in one error: `ADMIN_PASSWORD`,
`MARIADB_ROOT_PASSWORD` when benchbar has none stored, and `--yes`.

Exit codes: 0 the site exists; 1 a step failed or an app is not in
`apps/`, or `ADMIN_PASSWORD` is missing; 2 the MariaDB root password is
unknown (pass `MARIADB_ROOT_PASSWORD`).

```bash
ADMIN_PASSWORD='...' benchbar site add v16two --bundle minimal --yes
```

## site default

```
benchbar site default NAME [--json]
```

Makes NAME the default site: `bench use`, the runner's ping, `benchup` and
the app all follow it. The processes keep running. With `--json` it
prints JSON lines ending in a `done`.

Exit codes: 0; 1 when the site does not exist or `bench use` fails.

```bash
benchbar site default v16two
```

## site hosts

```
benchbar site hosts [--prune] [--dry-run]
```

Adds a `127.0.0.1` line to `/etc/hosts` for every site that has none,
inside benchbar's markers, with one `sudo` prompt.

With `--prune` it removes instead the lines of benchbar's block whose site no
bench benchbar knows has (a site that was dropped, or a bench that was
removed; a bench that was forgotten but whose folder is still there keeps its
lines): one backup, one `sudo` rewrite. A line outside the block, or with
more than one name, is never touched. Without a terminal, or with
`BENCHBAR_SUDO=gui`, it prints the `sed` command to run instead (it keeps a
`.bak` copy of the file). macOS only:
Linux has no hosts block.

Exit codes: 0; 1 when the hosts file could not be written.

```bash
benchbar site hosts
benchbar site hosts --prune --dry-run
```

## site open-as

```
benchbar site open-as on|off|status [NAME] [--yes] [--json]
```

Turns password-less sign in (`benchbar open --as USER`) on or off for a
site, or shows it. NAME defaults to the bench's default site. It is off for
every site until you turn it on, also for a site you add or pull later.
The choice is benchbar's own state for the bench; the site is not changed.

`on` must be run in a terminal by a person. It prints what a sign in does
(the apps' `on_login` and `on_session_creation` hooks run: `last_login`,
an Activity Log entry, a mail to System Managers for Administrator, an
ERPNext Customer or Supplier for a Website User, and Frappe may end that
user's oldest session) and asks first; `--yes` skips the question.
It is refused when `BENCHBAR_NONINTERACTIVE=1` is set, which `--for-agent`
and `benchbar mcp` do, and when there is no terminal on stdin, even with
`--yes` (the BenchBar app turns it on after its own alert). It still records the choice for a site that is not in
`developer_mode` or not the site the web process answers as, and says that
`open --as` will refuse it until that changes. `off` is always allowed; it does not end the sessions already made.
`status --json` prints one document with `open_as_enabled`,
`developer_mode` and `open_as`; `on` and `off` with `--json` print JSON
lines ending in a `done`.

Exit codes: 0; 1 when the site does not exist, `on` is run without a person
at a terminal, or the question is answered no.

```bash
benchbar site open-as on v16dev
benchbar site open-as status --json
```

## site backup

```
benchbar site backup NAME [--with-files] [--json] [--dry-run]
```

Runs bench's own `bench --site NAME backup` and reports the new backup:
the database dump, the site config and, with `--with-files`, the public
and private files. The backup lands where bench always puts it,
`sites/NAME/private/backups/`, inside the bench: copy it elsewhere when
it has to outlive the bench. When the bench is stopped, its Redis is
started for the backup and stopped again.

bench's backup deletes the site's backups older than 23 hours
(`keep_backups_for_hours`). benchbar keeps them: it holds a second name
for every file of the folder under its state folder while bench runs and
puts back what bench deleted. Nothing is pruned, and the site's config is
not changed. On the same volume the second name is a hard link; when the
state folder is on another volume it is a full copy of the folder each
run, and the command stops before bench starts when the free space does
not cover it. A run that is cut short puts the files back as it exits;
after a kill, the next backup puts them back (doctor warns until then:
`kept_backups`, fixed by `benchbar repair`). The same holds for the backup that `site restore`, `site
drop`, `pull --replace` and `app update` take first. See [what is kept
and for how long](../../guides/benches-and-sites.md#backing-up-and-dropping-a-site).

| Flag | What it does |
|---|---|
| `--with-files` | Also back up the uploaded files (public and private) |
| `--json` | Print the new backup as JSON ([schema](../../json-schema.md#site-backups)); the progress goes to stderr |
| `--dry-run` | Print the command, change nothing |

Exit codes: 0 the backup exists; 1 the site does not exist or the backup
failed.

```bash
benchbar site backup macdev --with-files
```

## site backups

```
benchbar site backups NAME [--json]
```

Every backup of the site, newest first: when it was taken, its size,
whether it has the files, and the database file. Read only. The files
that share a timestamp are one backup. A set with a part of zero bytes,
a partial set or one without a database is marked `(incomplete)` (and
`"complete": false` in JSON); `site restore` reads the files themselves
before it changes anything.

Exit codes: 0; 1 when the site does not exist.

```bash
benchbar site backups macdev --json
```

## site restore

```
benchbar site restore TARGET --from STAMP|PATH [--from-site SITE] [--new] [--neutralise] [--no-migrate]
  [--before-migrate SCRIPT] [--with-files] --dry-run [--json] | --apply TOKEN --yes [--json] | --yes
```

Restores a backup set that `site backup` (bench) made into a site of this
bench. TARGET is a site that is there, which is backed up with its files
first, or, with `--new`, a site that is created first (`bench new-site`,
with the MariaDB root password benchbar holds and a generated
Administrator password, or `ADMIN_PASSWORD`; the restore brings the
Administrator password of the backup). The `encryption_key` of the set is
carried into the target, so stored passwords decrypt. After the restore
come the `--before-migrate` script, `bench migrate` and the cache; the
run ends with a check that the site answers `list-apps` and that the
default site is where it was. The default site never moves, and a
restored site is not muted: it is the same site, not a copy of
production.

`--from` is a stamp from `benchbar site backups` (of `--from-site`, else of
TARGET), the path of a set's database file (its other files are found
next to it), or a folder (the newest set in it). Encrypted sets are not
taken: `benchbar pull --from-dir DIR --as NAME` decrypts one.

Run `--dry-run --json` first: it prints the plan, what it touches, the
backup it takes first and a `token`. `--apply TOKEN --yes` then runs exactly
that plan without a question, and refuses it when the sites, the default
site, the hook or the set changed meanwhile
([schema](../../json-schema.md#benchbar-site-restore---json)).
A plain `--yes` from a terminal shows the plan and runs it.

| Flag | What it does |
|---|---|
| `--from STAMP\|PATH` | The backup set |
| `--from-site SITE` | The site a stamp belongs to (needed with `--new`) |
| `--new` | Create TARGET first |
| `--with-files` | Restore the public and private files too (the set must have them) |
| `--neutralise` | After the restore and the key, before migrate: switch the site's outbound integrations off and clear its stored secrets, the list [`pull`](pull.md#what-the-copy-loses) runs (the Administrator login is kept). For a set that is not this bench's own: the plan warns without it, and a run without a person (`--for-agent`, `benchbar mcp`, `BENCHBAR_NONINTERACTIVE=1`) is refused without it |
| `--no-migrate` | Stop after the restore and the key, before `bench migrate` |
| `--before-migrate SCRIPT` | Run the executable SCRIPT after the restore, before migrate, in the bench folder, with `BENCHBAR_SITE`, `BENCHBAR_BENCH` and `BENCHBAR_DB_NAME`. Variables named like a secret are removed from its environment. A failing script stops the run before migrate |
| `--dry-run`, `--json` | The plan, with its token |
| `--apply TOKEN` | Run the reviewed plan (needs `--yes`) |

Exit codes: 0 restored and verified; 1 a refusal or a failed step (the
output names the backup taken first, to put back); 2 the MariaDB root
password is unknown (pass `MARIADB_ROOT_PASSWORD`).

```bash
benchbar site restore acme.localhost --from 20260902_090000 --with-files --dry-run --json
benchbar site restore acme.localhost --from 20260902_090000 --with-files --apply TOKEN --yes
benchbar site restore copy.localhost --from 20260902_090000 --from-site acme.localhost --new --yes
```

## site snapshot

```
benchbar site snapshot NAME [--label TEXT] [--json] [--dry-run]
benchbar site snapshot drop NAME SNAPSHOT|--prune [--keep N] [--force-undo-point] [--yes] [--dry-run]
```

Saves the state of a site before a risky change: `bench --site NAME backup
--with-files` (the database, the public and private files and the site
config), moved at once out of `sites/NAME/private/backups`, which frappe
prunes, into `sites/NAME/snapshots/<time>[-label]/`, next to a
`manifest.json` with the time, the label, the sizes and the apps of the
bench with their commits. Nothing in the site changes, and nothing removes
a snapshot by itself. Before it runs, the free space of the volume is
checked against the site's files plus its largest database dump, and the
command stops when the set would not fit. An encrypted backup is refused
(a restore takes plain sets only). The folder is readable by its owner only.

`site snapshot drop` removes a snapshot, or with `--prune` the ones beyond
the newest 10 (`SNAPSHOT_KEEP` in the bench's state file, or `--keep N`). It
is a person's choice: it asks first and is refused for an agent
(`--for-agent`, `benchbar mcp`, `BENCHBAR_NONINTERACTIVE=1`), though
`--dry-run` shows what would go. It removes the files one by one and then the
folder, and keeps the `before rollback` snapshot of the last rollback: `--prune`
never takes it, and dropping it by name needs `--force-undo-point`.

| Flag | What it does |
|---|---|
| `--label TEXT` | What the snapshot is for (up to 120 characters, no quotes or backslashes); it is part of the folder name |
| `--json` | Print the snapshot as JSON ([schema](../../json-schema.md#site-snapshots)) |
| `--dry-run` | Print what would happen, change nothing |

Exit codes: 0; 1 when the site does not exist, the backup failed or did not
fit, or an agent asked for `drop`.

```bash
benchbar site snapshot acme.localhost --label "before the erpnext update"
benchbar site snapshot drop acme.localhost --prune --dry-run
```

## site snapshots

```
benchbar site snapshots NAME [--keep N] [--json]
```

The snapshots of the site, newest first: the label, the size, the apps with
their commits when it was taken, and whether the bench's apps are still those
(`changed: erpnext` when one moved, was added or removed). It also says what
all the snapshots hold, how much is free on the volume and which snapshots are
beyond the newest N. Read only.

```bash
benchbar site snapshots acme.localhost --json
```

## site rollback

```
benchbar site rollback NAME --to SNAPSHOT|latest [--no-migrate]
  --dry-run --json | --apply TOKEN --yes [--json]
```

Puts a snapshot back into the site. It is [site restore](#site-restore) with
a snapshot as its source: the same plan, token and checks. The first step
takes a snapshot of the current state, labelled `before rollback` (the result
names it, and `--to latest` right after the rollback goes back); then the
snapshot's database and files are restored into the same site. `bench
migrate` runs only when the bench's apps differ from the snapshot's, which
the plan says (a rollback across an app change is allowed and warned);
`--no-migrate` stops before it. `--to` takes the name from `site snapshots`,
its time stamp, or `latest`, which skips a cut short folder.

The default site is a person's to roll back: an agent gets a plan that cannot
be applied. The plan also cannot be applied when the extra snapshot would not
fit in the free space. The MariaDB root password is needed, as for `site
restore`.

```bash
benchbar site rollback acme.localhost --to latest --dry-run --json
benchbar site rollback acme.localhost --to latest --apply TOKEN --yes
```

## site drop

```
benchbar site drop NAME --confirm-site NAME [--new-default OTHER] [--dry-run|--apply TOKEN --yes] [--json]
```

Removes a site for good. Its database and database user are dropped,
and only the backup taken first can bring the data back; the site's
address stops working. Check that it is the site you mean and run with
`--dry-run` first.

It runs `bench drop-site`, which takes a backup with files first, drops
the database and user, and moves the site folder, with that backup, to
`archived/sites/` in the bench (nothing is deleted there). The
MariaDB root password comes from the Keychain and reaches bench on
stdin, never on the command line. Afterwards the site's `127.0.0.1` line
is removed from `/etc/hosts`, with one `sudo` prompt, when it is inside
benchbar's block and no other bench has a site with that name.

benchbar refuses:

- without `--confirm-site` repeating the site name exactly;
- the default site, unless `--new-default OTHER` names the site that
  takes its place (it is made the default first, like `site default`);
- the only site of the bench;
- when the backup fails: bench stops before it drops anything, and the
  site stays.

A hosts line outside benchbar's block is left alone, and so is the line
when there is no terminal to ask for the `sudo` password (the app): the
output says which command removes it by hand.

| Flag | What it does |
|---|---|
| `--confirm-site NAME` | The site name again; nothing is dropped without it |
| `--new-default OTHER` | For the default site: the site that becomes the default |
| `--dry-run` | Print the plan, change nothing (with `--json`: the steps and a `token`) |
| `--apply TOKEN` | Run the plan of a dry run, with `--yes`; refused, before anything changes, when the sites, the default site, the hosts line or the site's database name (`database` in the plan) changed since the plan |
| `--json` | The result as JSON: the backup, the archived folder, the hosts line ([schema](../../json-schema.md#site-backups)) |

Exit codes: 0 the site is dropped; 1 a refusal or a failed step; 2 the
MariaDB root password is unknown (pass `MARIADB_ROOT_PASSWORD`).

```bash
benchbar site drop bbtest.localhost --confirm-site bbtest.localhost --dry-run
benchbar site drop bbtest.localhost --confirm-site bbtest.localhost
benchbar site drop bbtest.localhost --confirm-site bbtest.localhost --dry-run --json   # the plan and its token
benchbar site drop bbtest.localhost --confirm-site bbtest.localhost --apply TOKEN --yes
```

To bring a dropped site back, restore its backup from
`archived/sites/NAME/private/backups/` into a new site with
`bench --site NAME restore PATH --with-public-files ... --with-private-files ...`.
The restore does not bring back the site's `encryption_key`: copy it
from `archived/sites/NAME/site_config.json` into the new site's
`site_config.json`, or its stored passwords do not decrypt (see
[Troubleshooting](../../troubleshooting.md#common-stumbles)).

## Flags, needs and environment

These tables come from the code (`benchbar commands --json`); the sections above explain them.

<!-- generated:cli-commands site -->
<!-- Generated by scripts/docs-reference.py from the code. Edit the code, then run: python3 -I scripts/docs-reference.py --write -->

| Command | Terminal | `sudo` | Network | Changes things | JSON |
|---|---|---|---|---|---|
| `benchbar site list\|add\|default\|hosts\|backup\|backups\|restore\|snapshot\|snapshots\|rollback\|drop\|open-as ...` | no | no | no | no | none |
| `benchbar site list [--json]` | no | no | no | no | document |
| `benchbar site add NAME [--bundle NAME\|--apps "a b"] [--dry-run\|--apply TOKEN] [--yes] [--json]` | yes | yes | no | yes | stream |
| `benchbar site default NAME [--json]` | no | no | no | yes | stream |
| `benchbar site open-as on\|off\|status [NAME] [--json]` | yes | no | no | yes | stream |
| `benchbar site hosts [--prune] [--dry-run]` | yes | yes | no | yes | stream |
| `benchbar site backup NAME [--with-files] [--json]` | no | no | no | yes | document |
| `benchbar site backups NAME [--json]` | no | no | no | no | document |
| `benchbar site restore NAME --from STAMP\|PATH [--from-site S] [--new] [--neutralise] [--no-migrate] [--before-migrate SCRIPT] [--with-files] --dry-run --json, then --apply TOKEN --yes` | no | yes | no | yes | document |
| `benchbar site snapshot NAME [--label TEXT] [--json]` | no | no | no | yes | document |
| `benchbar site snapshot drop NAME SNAPSHOT\|--prune [--keep N] [--force-undo-point] [--yes] [--dry-run] [--json]` | no | no | no | yes | document |
| `benchbar site snapshots NAME [--keep N] [--json]` | no | no | no | no | document |
| `benchbar site rollback NAME --to SNAPSHOT\|latest [--no-migrate] --dry-run --json, then --apply TOKEN --yes` | no | yes | no | yes | document |
| `benchbar site drop NAME --confirm-site NAME [--new-default OTHER] [--dry-run\|--apply TOKEN --yes] [--json]` | no | yes | no | yes | document |

Terminal: may ask a question on a terminal. `sudo`: may run `sudo`. Network: may reach the network.
JSON: `document` is one JSON line, `stream` is JSON lines ending in a `done` line.

| Command | Flag | Value | What it does |
|---|---|---|---|
| `site add` | `--background` |  | Start it detached and print its op_id at once (benchbar op status, op wait follow it). Nothing can be asked: needs --yes and the inputs in the environment, as for an agent. Not with --dry-run. |
| `site add` | `--bundle` | `NAME` | App bundle to install. |
| `site add` | `--apps` | `"a b"` | Apps of apps/ to install. |
| `site add` | `--dry-run` |  | Print the plan and its token, change nothing. |
| `site add` | `--apply` | `TOKEN` | Run exactly that plan (with --yes). |
| `site add` | `--yes` |  | Do not ask. |
| `site open-as` | `--yes` |  | Do not ask before turning on (still refused without a terminal session, BENCHBAR_NONINTERACTIVE=1). |
| `site open-as` | `--json` |  | JSON lines for on and off, one document for status. |
| `site hosts` | `--prune` |  | Remove the stale lines of benchbar's block instead of adding the missing ones (sites of a forgotten bench whose folder is still there count as sites). The printed fallback command keeps a .bak copy. macOS only. |
| `site backup` | `--background` |  | Start it detached and print its op_id at once (benchbar op status, op wait follow it). Nothing can be asked: needs --yes and the inputs in the environment, as for an agent. Not with --dry-run. |
| `site backup` | `--with-files` |  | Include the uploads. |
| `site restore` | `--background` |  | Start it detached and print its op_id at once (benchbar op status, op wait follow it). Nothing can be asked: needs --yes and the inputs in the environment, as for an agent. Not with --dry-run. |
| `site restore` | `--from` | `STAMP\|PATH` | The backup set: its stamp in the target's (or --from-site's) backup folder, or the database file's path. |
| `site restore` | `--from-site` | `S` | Read the stamp from this site's backups. |
| `site restore` | `--new` |  | Create the site (bench new-site) first. |
| `site restore` | `--neutralise` |  | Switch the restored site's integrations off and clear its stored secrets, after the restore and before migrate (the list pull runs; the Administrator login is kept). Needed for a set from outside this bench when no person runs the restore. |
| `site restore` | `--no-migrate` |  | Stop after the restore, before bench migrate. |
| `site restore` | `--before-migrate` | `SCRIPT` | An executable run after the restore, before migrate. |
| `site restore` | `--with-files` |  | Restore the uploads too. |
| `site restore` | `--dry-run` |  | Print the plan and its token. |
| `site restore` | `--apply` | `TOKEN` | Run exactly that plan (with --yes). |
| `site snapshot` | `--background` |  | Start it detached and print its op_id at once (benchbar op status, op wait follow it). Nothing can be asked: needs --yes and the inputs in the environment, as for an agent. Not with --dry-run. |
| `site snapshot` | `--label` | `TEXT` | What the snapshot is for (up to 120 characters, no quotes); it is part of the folder name. |
| `site snapshot` | `--dry-run` |  | Print what would happen, change nothing. |
| `site snapshot drop` | `--prune` |  | Remove the snapshots beyond the newest N (never an undo point of a rollback). |
| `site snapshot drop` | `--keep` | `N` | With --prune: how many to keep (default 10, or SNAPSHOT_KEEP in the bench's state file). |
| `site snapshot drop` | `--force-undo-point` |  | With one named snapshot: also remove an undo point of a rollback (a plain drop refuses it). |
| `site snapshot drop` | `--yes` |  | Do not ask. Refused for an agent: drop is a person's choice. |
| `site snapshot drop` | `--dry-run` |  | Print what would be removed, change nothing. |
| `site snapshots` | `--keep` | `N` | Say which snapshots are beyond the newest N (default 10, or SNAPSHOT_KEEP in the bench's state file). Nothing is removed. |
| `site rollback` | `--background` |  | Start it detached and print its op_id at once (benchbar op status, op wait follow it). Nothing can be asked: needs --yes and the inputs in the environment, as for an agent. Not with --dry-run. |
| `site rollback` | `--to` | `SNAPSHOT` | The snapshot: its name, its stamp, or latest (benchbar site snapshots NAME lists them). |
| `site rollback` | `--no-migrate` |  | Stop after the restore, before bench migrate. |
| `site rollback` | `--dry-run` |  | Print the plan and its token. |
| `site rollback` | `--apply` | `TOKEN` | Run exactly that plan (with --yes). |
| `site drop` | `--confirm-site` | `NAME` | Repeat the site name exactly. |
| `site drop` | `--new-default` | `OTHER` | Required when NAME is the default site. |
| `site drop` | `--dry-run` |  | Print the plan, change nothing. With --json the plan carries a token. |
| `site drop` | `--apply` | `TOKEN` | Run the plan of a dry run; refused when the sites, the default or the hosts line changed since (needs --yes). |

| Command | Environment variable | What it does |
|---|---|---|
| `site add` | `ADMIN_PASSWORD` | The new site's Administrator password. |
| `site add` | `MARIADB_ROOT_PASSWORD` | Only when MariaDB has a password benchbar does not know. |
| `site add` | `BENCHBAR_SUDO` | Linux only: env makes the sudo steps use BENCHBAR_SUDO_PASSWORD, no terminal needed (a wrong one fails at once with error_id sudo_password_wrong, before any change). |
| `site add` | `BENCHBAR_SUDO_PASSWORD` | The sudo password, with BENCHBAR_SUDO=env. Read once at startup and removed from the environment; never in argv, the log or a child. |
| `site restore` | `MARIADB_ROOT_PASSWORD` | Only when MariaDB has a password benchbar does not know. |
| `site rollback` | `MARIADB_ROOT_PASSWORD` | Only when MariaDB has a password benchbar does not know. |
| `site drop` | `MARIADB_ROOT_PASSWORD` | Only when MariaDB has a password benchbar does not know. |
<!-- /generated:cli-commands -->

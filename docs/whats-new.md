---
title: "What's new"
description: "The defaults that changed in BenchBar 0.9.0, how to switch each one back, and what to do right after the update."
---

BenchBar 0.9.0 changes three defaults to the safer choice. Each one has a way
back, an upgrade note here and a notice that shows once after the update: the
first command you type in a terminal prints it, the Mac app shows it as a
banner, and `benchbar notices` lists it again. `benchbar notices --dismiss ID`
or `--all` hides them. A fresh install shows none of them. See
[notices](reference/cli/other.md#notices).

## After the update

Run `benchbar repair` once per bench. It rewrites the service files (the
`Procfile.lean`, the runner and the agent) from the new templates, and it may
restart a running bench itself. If it did not, run `benchbar restart`. Until
then a running bench keeps the old behaviour, and `benchbar doctor` says
`Procfile.lean is outdated`.

## The bench listens on this computer only

The web server and socketio of a bench now listen on 127.0.0.1. Before, they
listened on every interface (Frappe's own default, with the developer debugger
on), so anyone on the same Wi-Fi who knew the site name could reach the dev
server.

- **Switch back:** `benchbar listen all`, then `benchbar restart`.
  `benchbar listen local` undoes it, and `benchbar listen` says which one a
  bench has. The choice is kept per bench.
- **Upgrade note:** reaching a bench by the address of the computer, from a
  phone or another PC, needs `benchbar listen all`. On Windows, a browser still
  opens `http://<site>.localhost:8000`.
- More: [listen](reference/cli/other.md#listen).

## Unknown options are errors

An option a command does not take now stops the run with exit 64 and changes
nothing. Before, it was ignored and the command ran:
`benchbar repair --dry-rn --yes` repaired for real. A flag that needs a value
and has none stops the same way.

- **Switch back:** set `BENCHBAR_LENIENT_FLAGS=1`. An unknown option is then a
  warning on stderr and the command runs, as before. It does not cover a flag
  with a missing value.
- **Upgrade note:** a script of yours that passes options a command never read
  now stops. Remove them, or set the variable for now. `benchbar COMMAND --help`
  lists every flag a command takes.
- More: [JSON API](json-schema.md) for the shape of the refusal under `--json`.

## pull neutralises the copy

`benchbar pull` now neutralises the copy it makes. Integrations are switched
off (email accounts, webhooks, OAuth, payment gateways, scheduled jobs that call
out) and stored passwords are deleted, except the Administrator login.
Customer data is not scrubbed.

- **Switch back:** `benchbar pull --keep-secrets` keeps production's
  integrations and passwords in the copy, as before. Email is still muted and
  the scheduler paused.
- **Upgrade note:** a copy you already pulled keeps what it has until you pull
  again with `--replace`. A script that pulls and then relies on production's
  SMTP, S3 or API credentials must add `--keep-secrets`.
- More: [pull](reference/cli/pull.md).

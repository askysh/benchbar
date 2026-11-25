---
title: "FAQ"
description: "Short answers to common questions: Docker, existing benches, sudo, what uninstall removes, ports, reboots and where the logs are."
---

Each answer links to the page that has the detail.

## Do I need Docker?

No. BenchBar runs a bench natively, with Python, Node, MariaDB and Redis
installed on your machine. See
[BenchBar compared with other ways to run a bench](concepts/alternatives.md).

## Can I use a bench I already have?

Yes. `benchbar adopt PATH` registers it. It writes only the service
files and never runs `migrate`, `build` or `update`. See the
[Quick start](quick-start.md).

## Why does BenchBar ask for sudo?

On macOS, `sudo` is used only for the `/etc/hosts` line of a site and the
patched wkhtmltopdf package. On Linux it is used for apt, the wkhtmltopdf
package and the MariaDB admin step. The command asks once, before it
starts, and says why. See [Install](install.md).

## Does BenchBar delete my benches?

No. `benchbar` never deletes a whole bench. `benchbar site drop` and
`benchbar pull --replace` back up the database first. Uninstalling
removes BenchBar and keeps your benches. See [Uninstall](uninstall.md).

## What happens to my bench after a reboot?

A bench that was running comes back. It restarts after a crash and pauses
with a notification when it keeps crashing. See
[Benches and sites](guides/benches-and-sites.md).

## Port 8000 is busy. What now?

Each bench has its own [port block](concepts/port-blocks.md). `benchbar
ports plan` shows the allocation without changing anything.

## Where are the logs?

`benchbar logs` shows the bench logs. The logs of every `benchbar` run
and its backups are in the [state folder](glossary.md#state-folder),
`~/.local/state/benchbar`. See [Troubleshooting](troubleshooting.md).

## How do I update?

See [Update and migrate](upgrade.md). On Windows, see
[Update](windows.md#update).

## Can a coding agent work on my bench?

Yes, through MCP or the CLI. Repairs and installs stay with you. See
[Coding agents and MCP](guides/agents.md).

## What do the words mean?

See the [Glossary](glossary.md).

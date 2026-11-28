---
title: "BenchBar compared with other ways to run a bench"
description: "What BenchBar adds to plain bench start, and how running natively differs from running a bench in Docker."
---

This page says what is different. It makes no speed claim, because
BenchBar has not measured one.

## Plain `bench start`

`bench start` runs the processes of a bench in the terminal you typed it
in. When you close that terminal, the bench stops. It does not restart
after a crash and it does not come back after a reboot.

BenchBar uses the same bench. It runs it in the background through
launchd on macOS, or `systemd --user` on Linux and in WSL. It restarts a
bench after a crash and pauses it with a notification when it keeps
crashing. It also adds `benchbar doctor`, which names the fix for each
problem, and `benchbar repair`, which applies only those fixes.

You can still run a bench by hand with `bench start` in its folder.
`benchbar adopt` does not change the bench itself.

## Docker

A tool that runs a bench in Docker puts Python, Node, MariaDB and Redis in
containers. BenchBar does not use Docker or a VM. These come from your
machine (Homebrew on a Mac, apt on Linux). File watching, `bench build`
and a debugger run on the host.

Choose by what you need. A container gives you the same environment on
every machine. A native bench gives you the host tools and no layer in
between. BenchBar does not plan to support Docker (see the
[Roadmap](../ROADMAP.md)).

## Related

- [Benches and sites](../guides/benches-and-sites.md)
- [Glossary](../glossary.md)

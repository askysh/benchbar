---
title: "Labs: experiments you turn on"
description: "What a BenchBar Lab is, the two Labs that exist, and how to turn one on or off in the terminal, the Mac app or the Windows window."
---

A Lab is an experiment. It is off until you turn it on. A Lab can change
or go away in a later release. Turning one on is your decision: BenchBar
never turns a Lab on for you, and an agent or a script cannot do it.

While a Lab is off, its commands do not show in `benchbar --help`. Running
one exits with code 2 and says how to turn it on:
`Turn it on: benchbar labs on NAME`.

## The Labs

| Lab | What it does | Since | Platforms | Guide |
| --- | --- | --- | --- | --- |
| `lan-rooms` | Rooms on your Wi-Fi: colleagues use a hardened copy of a site, signed in as a seat you choose. | 0.8.2 | macOS | [Share on your network](share-on-your-network.md) |
| `quick-switch` | A panel on ⌃⌥U that opens a site as any pinned user, from any app. | 0.8.2 | macOS | [Quick Switch](quick-switch.md) |

A Lab lists the platforms it works on. On another platform it shows as
"not on this platform", and turning it on stops with an error.

## Turn a Lab on

- **Terminal:** `benchbar labs on NAME`. The command shows the warning of
  the Lab and asks you to confirm. `--yes` skips the question.
- **Mac app:** **Settings > Labs**. Each Lab has a switch, the warning and
  its version.
- **Windows:** the **Labs** page of the BenchBar window. It lists the Labs
  with a switch and says why a Lab is not available on Windows yet.

## Check and turn a Lab off

```bash
benchbar labs list               # every Lab and whether it is on
benchbar labs status lan-rooms   # exit 0 when on, 1 when off
benchbar labs off lan-rooms      # turn it off
```

`labs off` always works. It stops what the Lab started. A running room
stops with it, and the Quick Switch key is released. If something cannot
be undone, the command says so as a warning, and the Lab is off anyway.

The list of Labs is kept by BenchBar. Your benches and sites do not
change when you turn a Lab on or off.

## Related

- [Features](../features.md): every feature, with the version it came in
- [labs](../reference/cli/labs.md): the command reference

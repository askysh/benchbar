---
title: "labs"
description: "benchbar labs list, on, off and status: experiments that stay off until you turn one on."
---

Labs are experiments. Each one is off until you turn it on, and while it is
off its commands do not show in `benchbar --help` or `benchbar commands
--json`, and running one stops with exit code 2.

## labs

```
benchbar labs [list] [--json]
benchbar labs on NAME [--yes] [--json]
benchbar labs off NAME [--json]
benchbar labs status NAME [--json]
```

`labs` lists every experiment with its state. `labs on` shows the warning of
the experiment and asks first (`--yes` skips the question). Turning one on is
a person's decision, so it stops with exit code 2 when nothing can ask:
`BENCHBAR_NONINTERACTIVE=1`, `--for-agent` and `benchbar mcp` never turn one
on. `labs off` always works. It undoes what the experiment started and turns
it off; a problem while undoing is a warning, and the experiment is off anyway.
`labs status` exits 0 when the experiment is on and 1 when it is off.

A lab lists its platforms (`macos`, `linux`, `windows`). On another platform
`labs` shows it as "(not on this platform)" and `labs on` stops with exit
code 1: "NAME is not available on linux yet".

All of this is benchbar's own state (the `LABS` key). No bench or site changes.
The BenchBar app shows the same list under Settings. `BENCHBAR_LABS=a,b` in
the environment replaces the saved list, for tests and CI.

| Name | What it does | Since | Platforms |
| --- | --- | --- | --- |
| `lan-rooms` | Share with people on the same Wi-Fi. Commands: `share`, `lan-guard`. | 0.9.0 | macOS |
| `quick-switch` | A panel on a global keyboard shortcut to open a site as any pinned user. | 0.9.0 | macOS |

The JSON is in [the JSON reference](../../json-schema.md#benchbar-labs-json).

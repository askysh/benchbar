---
title: "Port blocks"
description: "How each bench gets its own web, socketio and Redis ports, and how benchbar moves a new bench that clashes."
---

Each bench has its own port block: web `8000 + n`, socketio `9000 + n`,
Redis `11000 + n` and `13000 + n`. `bench init` already counts up for
benches in the same folder; `install` and `adopt` also check every bench
benchbar knows and the ports in use, and move a new bench that clashes
with an established one to the next free block, with `bench set-config -g`
and `bench setup redis`. `--port-offset N` picks a block, for example
`benchbar service --port-offset 1 --bench-dir ~/dev/v16-bench`.

The default bench never moves on its own. Doctor's
[`port_clash`](../guides/doctor-and-repair.md#port_clash) check warns when two
benches share ports.

To sort out the ports of several benches at once, preview first, then
apply:

```bash
benchbar ports plan -- ~/frappe-bench ~/dev/v16-bench    # read only
benchbar ports setup -- ~/frappe-bench ~/dev/v16-bench   # the same plan, asks once, then applies
```

Stop the benches first (`benchbar down --bench-dir PATH`): the plan
marks a running bench as blocked, and setup applies nothing while any
bench in it is blocked. The plan lists every bench's ports and the
service files it would rewrite, and setup never starts a bench; run
`benchup` afterwards. `benchbar ports check --bench-dir PATH` shows the
conflicts of one bench. Every command and flag is in the
[ports reference](../reference/cli/ports.md).

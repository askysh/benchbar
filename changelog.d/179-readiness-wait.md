### Command line

- `benchbar status --json` has a `ready` object: whether the bench can serve, with each part (service loaded, processes, site ping 2xx or 3xx, socketio, Redis, a worker, and whether a Python file under `apps/` changed after the bench started). `status --json --deep` asks the worker and code parts too (#179).
- `benchbar wait` blocks until the bench is ready, or until one part is (`--for PART`), and exits 1 with what is missing and the fix when it is not ready in time (`--timeout SECS`). `up` and `restart` use the same site check (#179).

### MCP

- The new read tool `benchbar_wait` waits for a bench to be ready, with progress notifications and a 120 second cap. `benchbar_status` returns the `ready` object, including `stale` when Python code changed since the start (#179).

### Mac app

- The bench pill reads "Ready", "Needs restart (code changed)" or "Running, not ready" from the new `ready` object, and keeps the word when the runner rewrites its state file, until the bench's state or process changes (#179).

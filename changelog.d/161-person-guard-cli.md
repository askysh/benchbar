### Command line

- On a Mac, `benchbar` honors `BENCHBAR_SUDO=gui` and `BENCHBAR_NONINTERACTIVE=0` for the commands only a person runs (`site open-as on`, `open --as --print-url`, `lan-guard`, `share`) only when `BENCHBAR_APP_PID`, the process id the BenchBar app sets, is a running parent of the command and runs a `BenchBar.app` binary. A shell that sets the variables itself is refused, and the message says which part did not hold (#161).
- On Linux and WSL the Windows tray's process is not visible from inside WSL, so those two variables are taken as they are there. AGENTS.md, the agents guide and the app page say plainly that the guard is a safety rail, not a boundary: a process that runs inside the app, or any process on Linux and WSL, is not stopped.

### Docs

- `BENCHBAR_APP_PID` is in the configuration reference, and the agents guide, AGENTS.md and the app page say what the person guard stops and what it does not (#161).

### Command line

- On a Mac, `benchbar` honors `BENCHBAR_SUDO=gui` and `BENCHBAR_NONINTERACTIVE=0` for the commands only a person runs (`site open-as on`, `open --as --print-url`, `lan-guard`, `share`) only when `BENCHBAR_APP_PID`, the process id the BenchBar app sets, is a running parent of the command whose name (the path `ps` prints) is inside a `BenchBar.app`. It is a name check on the parent chain: it stops a shell that only sets the variables, and the message says which part did not hold; it does not stop a process that fakes a parent named like the app (#161).
- `labs on` is refused without a terminal unless the app passes `BENCHBAR_NONINTERACTIVE=0` (checked the same way on a Mac), as the other person only commands are. A plain `benchbar labs on NAME --yes` from an agent's shell now exits 2. The Mac app and the Windows tray are not affected.
- On Linux and WSL the Windows tray's process is not visible from inside WSL, so those two variables are taken as they are there. AGENTS.md, the agents guide and the app page say plainly that the guard is a safety rail, not a boundary: a process that runs inside the app, or any process on Linux and WSL, is not stopped.

### Docs

- `BENCHBAR_APP_PID` is in the configuration reference, and the agents guide, AGENTS.md and the app page say what the person guard stops and what it does not (#161).

### Sharing

- `benchbar share join` joins a colleague's room from a terminal on macOS, Linux and
  Windows (WSL): with the host's address and the room code, or with an invite link.
  It shows the host key before you type the code, waits for your seat and opens the
  room on a localhost address of your own computer (#174).
- `benchbar share joined` lists the rooms this computer joined. `benchbar share leave`
  gives the seat back, and `benchbar share forget` also deletes this computer's key
  for that host.
- The room code and an invite link are never arguments of a command, so they stay out
  of the shell's history. Only a person runs these commands: an agent is refused.
- `benchbar share join --host-key HEX` joins only if the host shows that key, for a
  caller that looked at the room first (`--dry-run --json`, `host_pin`). Another key
  ends the run with exit code 3, before any request.
- `share leave` and `share forget` also work while the `lan-rooms` Lab is off. The room
  code and the invite link are not shown while you type them. The room history of the
  shell masks a code with spaces or dashes.

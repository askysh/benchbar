### Sharing

- `benchbar share joined` also works while the `lan-rooms` Lab is off, as `share leave` and `share forget` do: with two rooms they name it for the room's id (#353).
- `benchbar share leave` no longer says that a room's local address is closed while its forwarder still runs and is only slow to answer, and it never ends a process other than that forwarder.
- A second `benchbar share join` to the same host at the same moment no longer loses this computer's key when the first one fails. A join that cannot stop the forwarder of the room that host had before now says so, in place of showing that room's address.
- A program that opens connections to a room's local address and sends nothing no longer keeps a browser out for 30 seconds.
- A `benchbar share` command that waits for another one now waits until a lock left by a killed command frees itself, in place of saying "Another benchbar share command is at work".

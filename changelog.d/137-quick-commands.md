### Command line

- A bench command that benchbar runs for you (`migrate`, `build`, `get-app`, a backup, a restore step) is noticed within 20 ms of its end. Before, benchbar looked once a second, so every such step took up to a second longer than the command itself.
- Commands that do not read the service files (`down`, `site list`, `app list`, `pull`, `app add` and most others) no longer render them at start: about 0.2 s less per call. `doctor`, `repair`, `service` and `up` render them when they first check or write one, as before.
- A template renders in about a quarter of the time (the 288 lines of the runner: 25 ms instead of 94 ms). The output is the same, byte for byte, so no installed runner or agent is reported as outdated.

### Command line

- `benchbar up` and `benchbar restart` start faster (about a quarter of their time in the test setup): they work out only the Procfile and the listen files they compare, not the runner, the agent and the shell helpers as well (#137).

### Linux and WSL

- `benchbar doctor`, `repair`, `service` and `up` fingerprint the service files with `sha256sum` instead of the Perl script `shasum`: the same fingerprints, about 100 ms less on a full check (#137).

### Install

- The end of an install, adopt or repair no longer pauses for up to 5 seconds while the sudo session closes (#138).

### Command line

- Stopping `benchbar doctor` at the moment it starts a background check now waits for that check too, so it is not left running (#138).

### For contributors

- `tests/run-tests.sh` fails a test that printed an "unbound variable" error even when bash 3.2 exited 0, runs a failed test once more on CI and prints `FLAKY: NAME` with the first failure when it passes, lists the tests that skipped themselves, and fails a test named in `NO_SKIP` that skips (#138).
- A new test, `test-suite-hygiene`, checks that every mock in `tests/mocks/bin` is mode 100755 in git, that ending a sudo session is quick, and the run-tests.sh guards above (#138).
- `test-share-run` waits on a sign of life from the runner instead of a fixed number of seconds, and `test-services-served` takes its ports below the system's ephemeral range (#138).

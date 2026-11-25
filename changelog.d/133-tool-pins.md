### Command line

- `benchbar install` now installs the bench CLI (`frappe-bench` 5.31.1) and yarn (1.22.22) at exact versions instead of the newest. A new frappe-bench release can no longer break every new install at once. `repair` and `doctor` name the same versions in their fix commands. A bench CLI or yarn that is already installed is left alone (#133).

### For contributors

- The two pins are `FL_PIN_FRAPPE_BENCH` and `FL_PIN_YARN` in `lib/frappe-local/ui.sh`. `docs/releasing.md` says how to move them, and `tests/test-tool-pins.sh` fails when a pin is not an exact version, is older than a profile's `bench_min`, or an install line names no version.

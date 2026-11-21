### New defaults

- A bench set up before 0.9.0 now moves to 127.0.0.1 at its next `benchbar up` or `benchbar restart`, without a `benchbar repair` first: both write `Procfile.lean` and its two listen files again when they are older (the old file goes to the backups), and say so in one warning line (in `warnings[]` under `--for-agent`). A bench set to `benchbar listen all` is not rewritten, and neither is a `Procfile.lean` that benchbar did not write. `benchbar up` on a bench that already runs changes nothing and says to run `benchbar restart`.

### Command line

- New doctor check `toolchain_uv`: frappe-bench 5.31 and later need `uv` to make the bench env and to install apps, also when `bench` itself came from pipx. `benchbar repair` installs it with Homebrew (`uv_install`) before it rebuilds an env; on Linux the fix line names the system dependencies script.
- `benchbar repair` no longer moves the bench env aside when the rebuild cannot run: without `uv`, or without the `bench` command, it stops first and the env stays. `benchbar app add` and `benchbar app update` stop before their first step when `uv` is missing, and name the fix.

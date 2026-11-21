### Command line

- The shell helpers (`benchup` and the others) follow your login shell. fish gets them as fish functions in `~/.config/fish/conf.d/benchbar.fish`, where before they went into a `~/.zshrc` that fish never reads. bash on a Mac gets them in the file a login shell reads (`~/.bash_profile`, or `~/.bashrc` when that file loads it). nushell, xonsh, elvish, tcsh and PowerShell get no file, and doctor says to use `benchbar up` and the other long forms. After the update, `benchbar repair` writes the block for your shell; an older block in another file stays.
- A helper file that is read only is no longer replaced: `repair` stops and names the `chmod`. A helper file that is a loop of symlinks is refused, where before the run hung.
- `benchbar --version` says when the CLI inside BenchBar.app answered for Homebrew's or the installer's `benchbar`, and both it and `benchbar where` say when that copy is newer than the app's CLI, with how to update the app. The first line of `--version` is unchanged.
- One version compare for the whole CLI: an app that asks for `frappe >=16.0.0-dev` is no longer refused on a bench that has `16.0.0-dev`.

### Agents and MCP

- `BENCHBAR_LABS` no longer turns an experiment on. It was listed in `commands --json`, so an agent could read how to get past a lab a person left off. It is now read only by benchbar's own tests, and the row is gone from `commands --json`.

### For contributors

- Removed functions nothing called (`fl_step_run`, `fl_capture`, `fl_retry`, `fl_ports_json`, `fl_lab_table`, `fl_steps_counts`, `fl_formula_disable_days`). CONTRIBUTING.md lists the old names (`frappe-mac`, `frappe-local`) that stay on purpose and until when.

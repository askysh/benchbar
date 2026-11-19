### Windows tray

- The tray answers `benchbar://` links: `up`, `down`, `restart`, `open`, `logs`, `window`, `doctor`, `console`, `db`, `editor` and the two profile links. It registers the scheme for your user the first time it starts, and a second start hands the link to the running tray. A link it does not know is ignored and logged by its action only. **Settings > Ask before a link acts** is off by default. Share links show a note, because rooms are not on Windows yet (#174).

### Windows installer

- `install.ps1` registers `benchbar://` for your user, and `-Uninstall` removes it when it points to the installed tray (#174).

### Docs

- The Windows guide and the URL scheme page say that Windows supports `benchbar://` links, and the features table lists it (#174).

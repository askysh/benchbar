### Command line

- `app install` and `app add --site` back the site up before `install-app`, as `app update` does; `--skip-backup` leaves the backup out. A backup that fails stops the install (#153).
- When a step that changes something fails after it started (a clone that is not built, an `install-app`, a `migrate`, a fast forward), `changed[]` of the `done` line names it with a detail that begins with `partial:` (#153).
- `profile import`, `profile subscribe`, `profile update`, `install --profile` and `lock apply` print `install will run code from these repos` with the host and owner of each repo, and a second line for the owners that nothing in the bench uses yet. An update that adds or changes a `repo` line says so. `profile import --plan --json` has `runs_code_from` and `new_owners` (#153).
- `lock apply` marks each repo that is not in the bench yet (`NEW REPO`) in its plan (#153).
- A password in an `ssh://` (or any non https) remote is left out of `profile create` and `lock write`, with a warning (#153).
- A profile or lock `repo` must be `https://`, `ssh://` or `user@host:path`; `ext::`, `http://`, `git://` and local paths are refused, and every benchbar git call turns the `ext::` transport off (#153).
- A profile or lock with a UTF-8 byte order mark now reads. An empty `repo` or `branch`, and a `|` in one, is refused with a message (#153).
- A `commit` in a lock must be 12 to 40 hex characters, not a 7 character prefix (#153).
- A dry run no longer leaves a `benchbar-siteapps.*` file in the temp folder, and a site name with a dot no longer matches another site in the app cache (#153).
- The config tables are read with a separator that keeps an empty cell, and `.gitattributes` pins `*.tsv` and `*.toml` to LF (#153).

### Docs

- The profile header no longer says that nothing from a profile runs: reading one does not, installing one does (#153).

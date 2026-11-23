### Command line

- `app install` and `app update` print a plan token with `--dry-run --json` and run exactly that plan with `--apply TOKEN --yes`, as `app add` does. `lock apply` and `profile remove` got the same plan token.

### Agents and MCP

- New MCP tools: `benchbar_lock_write`, `benchbar_lock_apply_plan` and `benchbar_lock_apply`, `benchbar_pull_plan` and `benchbar_pull` (a neutralised copy of a production site as a new site, never the default site), `benchbar_profile_create`, and `benchbar_profile_remove_plan` and `benchbar_profile_remove`.
- `benchbar_app_install` and `benchbar_app_update` take the CLI's own token; the server no longer derives one. `profile import`, `subscribe`, `update` and `export` stay a person's decisions.

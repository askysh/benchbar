### Agents and MCP

- New MCP tools `benchbar_app_install_plan` and `benchbar_app_install` (install an app that is already in the bench on one site), and `benchbar_app_update_plan` and `benchbar_app_update` (fast forward one app: the plan lists the commits, every site that has the app is backed up first, then it migrates and builds). Each follows the plan, token, apply rule of the other changes: a plan the person sees first, a token this server returned at least 5 seconds ago, and the person's yes when the client can ask.
- `app install` and `app update` print their plans without a token, so the server derives one from the plan, and the apply plans again, after the person's yes and inside the action slot, and refuses when the plan changed (the remote has new commits, a site changed, or an earlier update was left half done). `benchbar_app_update_plan` runs `git fetch`, so it is not marked read only. The install plan has no backup step and the app's install hooks write into the site's database: the tool text points to `benchbar_site_backup`. There is no way to skip the backup of an update over MCP.

### Command line

- `benchbar self-update --check` takes no run lock and writes no run log: a check no longer waits behind a running `up` or `repair`, holds one up for the length of its request to GitHub, or leaves a log file per call. The update itself still takes both.

### Docs

- The docs check that a page names no `benchbar_*` MCP tool the server lacks now reads every page under `docs/` and `AGENTS.md`.

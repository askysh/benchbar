### Command line

- A launchd agent whose runner file is gone (a bench folder emptied or deleted while its agent stayed loaded) is now a failure in `benchbar doctor`, and `benchbar repair` boots it out and moves its plist aside. Before, it only warned while launchd restarted it every 20 seconds. Your own agents, and a `com.benchbar` label that runs a script benchbar did not write, are never touched.
- `benchbar report` and `benchbar logs --json` now mask Cookie and Set-Cookie headers, `--password VALUE`, `-pVALUE` on a mysql or mariadb line, and keys named pass, credential, session or ending in `_pwd`. REDACTIONS.txt says that log tails can hold names or phone numbers from a database error, so read them before you attach the zip.
- Plan tokens of `site add`, `site restore`, `app add`, `ports apply` and `service --apply` are keyed with a secret that stays on your Mac and expire after about an hour (60 to 70 minutes). An old token is refused with "The plan token expired", a plan that changed with the old message. A `--before-migrate` script is checked again right before it runs.
- `benchbar site add assets` and `apps.txt` are refused as site names (they are bench's own entries in `sites/`). A backup path with a comma is read whole. A port block written on one line in `common_site_config.json` is seen. A root owned listener on a bench port is seen on a Mac. A process named like `mariadbd` is no longer found in `vim mariadbd.cnf`.

### Install

- On Apple Silicon, `benchbar install` says before it installs wkhtmltopdf that the package has no Apple Silicon build and runs under Rosetta 2 (no other build exists), and downloads it over https only.

### Mac app

- The launchd agent raises the open file limit to 10240 (launchd's default is 256). `benchbar repair` writes the new agent once after the update, which restarts a running bench.

### Linux and WSL

- The systemd unit sets `LimitNOFILE=65536`. `Nice`, `ProcessType` (Mac) and `MemoryHigh` (Linux) can be set per bench; see the guide.

### Windows

- The Windows report masks the same extra shapes as the CLI: `--password VALUE`, `-pVALUE` and names ending in pass, pwd or credential.

### Docs

- The doctor guide describes the dead agent check, the agents guide the keyed and expiring plan tokens, the sites guide the service limits, and the troubleshooting page says plainly that wkhtmltopdf has no Apple Silicon build.

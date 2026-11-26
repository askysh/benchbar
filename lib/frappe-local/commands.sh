#!/usr/bin/env bash
#
# commands.sh: the one table of every command and subcommand, for
# `benchbar COMMAND --help`, `benchbar site SUB --help` and
# `benchbar commands --json`.
#
# Records are lines with fields separated by `~` (no field holds one):
#   cmd~KEY~USAGE~SUMMARY~TTY~SUDO~NETWORK~MUTATING~JSON
#   flag~KEY~--name~VALUE~HELP
#   env~KEY~NAME~HELP
#   note~KEY~TEXT           (directly after the cmd record of KEY, at most one: what the SUMMARY
#                            leaves out; no flag note, a flag has its own record)
# The global help text is `use` records, in usage.sh.
# KEY is the command ("install") or the command and subcommand ("site add").
# TTY (may ask a question on a terminal), SUDO (may run sudo), NETWORK (may
# reach the network) and MUTATING (changes the machine, a bench or its
# files) are yes or no. JSON is `document` (one JSON line), `stream` (JSON
# lines ending in a done line) or `none`. MUTATING decides what --for-agent
# asks for: a stream for a command that changes things, a document for one
# that reads.
#
# tests/test-agent-contracts.sh fails when a label of a dispatcher has no
# cmd record here.

# The records are plain text here, in a here document that bash only parses (`:`
# ignores it): reading one into a variable with `read -d ''` costs 27 ms on every
# start, on bash 3.2 and on bash 5, because the reader gets it byte by byte.
# fl_cmd_load reads them from this file instead (1 to 2 ms, and no program: status
# and list are polled and `cat` is one), and `commands --json` reads this file
# again, line by line, as it writes. Edit the records here; the lines
# `: <<'TABLE'` and `TABLE` mark where they start and end.
case "${BASH_SOURCE[0]}" in /*) FL_CMD_FILE="${BASH_SOURCE[0]}" ;; *) FL_CMD_FILE="${PWD}/${BASH_SOURCE[0]}" ;; esac
: <<'TABLE'
cmd~install~benchbar install [--profile NAME] [--bundle NAME] [--dry-run|--apply TOKEN] [--yes] [--json]~Install phase 00 (system dependencies), phase 01 (bench and site) and the background service. Safe to run again: it changes only what changed.~yes~yes~yes~yes~stream
flag~install~--background~~Start it detached and print its op_id at once (benchbar op status, op wait follow it). Nothing can be asked: needs --yes and the inputs in the environment, as for an agent. Not with --dry-run.
flag~install~--profile~NAME~Release profile (default v15-lts) or a team profile.
flag~install~--bundle~NAME~App bundle: minimal, common or extended.
flag~install~--port-offset~N~Use port block N (web 8000+N).
flag~install~--make-default~~Make this the default bench even when another one is.
flag~install~--repair-bench~~Move a bench folder that is incomplete aside and start over (never one that holds a site). With --dry-run it shows the move.
flag~install~--allow-windows-fs~~WSL only: accept a bench on the Windows file system (/mnt/c, drvfs, 9p). It is refused by default: slow, no file watching, broken permissions.
flag~install~--scratch~~Mark the new bench scratch: it expires after --ttl days and benchbar bench gc then removes it (never the default bench). Not with --make-default.
flag~install~--ttl~DAYS~With --scratch: days until the bench expires, 1 to 90 (default 7).
flag~install~--allow-unsupported-distro~~Linux only: try a system other than Ubuntu 24.04, the one the install is tested on and supports. Without it the install stops before it installs any package.
flag~install~--offline~~Skip the remote branch checks.
flag~install~--frappe-commit~SHA~Pin the frappe clone to this commit (or FRAPPE_COMMIT, or frappe_commit in a team profile). A commit the clone does not reach stops the install before anything is built.
flag~install~--erpnext-commit~SHA~Pin the erpnext clone to this commit (or erpnext_commit in a team profile). A commit the clone does not reach stops the install before anything is built.
flag~install~--dry-run~~Print the plan, change nothing. With --json the plan line carries its token.
flag~install~--apply~TOKEN~Run exactly that plan (with --yes); refused when the plan changed since the token was made. Without a token the run is as before.
flag~install~--yes~~Do not ask; secrets come from the environment.
flag~install~--secrets-stdin~~Read ADMIN_PASSWORD, MARIADB_ROOT_PASSWORD and BENCHBAR_SUDO_PASSWORD from standard input, not the environment: KEY=VALUE lines, LF only, ended by an empty line (required). For a program that has no terminal; a terminal is refused.
flag~install~--json~~JSON lines for the BenchBar app. Needs --yes or --dry-run: no question can be answered on the stream.
env~install~ADMIN_PASSWORD~The new site's Administrator password.
env~install~MARIADB_ROOT_PASSWORD~Only when MariaDB has a password benchbar does not know.
env~install~BENCH_INIT_TIMEOUT_SECONDS~Seconds bench init may take before it is stopped (default 2700, 0 for no limit). A half built bench left by a stopped init is moved aside by the next install, which starts it again.
env~install~BENCHBAR_SUDO~Linux only: env makes the sudo steps use BENCHBAR_SUDO_PASSWORD, no terminal needed (a wrong one fails at once with error_id sudo_password_wrong, before any change).
env~install~BENCHBAR_SUDO_PASSWORD~The sudo password, with BENCHBAR_SUDO=env. Read once at startup and removed from the environment; never in argv, the log or a child.
cmd~adopt~benchbar adopt PATH [--dry-run] [--yes] [--json]~Register an existing bench: Procfile.lean, runner, agent and helpers. It shows the plan and asks first, and never runs migrate, build or update.~yes~yes~no~yes~stream
flag~adopt~--port-offset~N~Move the bench to port block N.
flag~adopt~--make-default~~Make this the default bench.
flag~adopt~--allow-windows-fs~~WSL only: accept a bench on the Windows file system (/mnt/c, drvfs, 9p), which is refused by default.
flag~adopt~--dry-run~~Print the plan, change nothing.
flag~adopt~--yes~~Do not ask.
flag~adopt~--secrets-stdin~~Read the passwords from standard input, not the environment: KEY=VALUE lines (ADMIN_PASSWORD, MARIADB_ROOT_PASSWORD, BENCHBAR_SUDO_PASSWORD), LF only, ended by an empty line (required). For a program that has no terminal.
flag~adopt~--json~~JSON lines, as install. Needs --yes or --dry-run.
env~adopt~BENCHBAR_SUDO~Linux only: env makes the sudo steps use BENCHBAR_SUDO_PASSWORD, no terminal needed (a wrong one fails at once with error_id sudo_password_wrong, before any change).
env~adopt~BENCHBAR_SUDO_PASSWORD~The sudo password, with BENCHBAR_SUDO=env. Read once at startup and removed from the environment; never in argv, the log or a child.
cmd~service~benchbar service [--with-schedule|--without-schedule] [--port-offset N] [--dry-run|--apply TOKEN --yes] [--json]~Install or refresh only the background service (phase 02).~yes~no~no~yes~stream
flag~service~--with-schedule~~Add the scheduler to Procfile.lean.
flag~service~--without-schedule~~Remove it again.
flag~service~--port-offset~N~Use port block N.
flag~service~--dry-run~~Print the plan and its token, change nothing.
flag~service~--apply~TOKEN~Run exactly that plan (with --yes).
env~service~BENCHBAR_SUDO~Linux only: env makes the sudo steps use BENCHBAR_SUDO_PASSWORD, no terminal needed (a wrong one fails at once with error_id sudo_password_wrong, before any change).
env~service~BENCHBAR_SUDO_PASSWORD~The sudo password, with BENCHBAR_SUDO=env. Read once at startup and removed from the environment; never in argv, the log or a child.
cmd~mariadb-password~benchbar mariadb-password [--yes]~Print the MariaDB root password to a person at a terminal (asks first). Refused under BENCHBAR_NONINTERACTIVE, --for-agent, mcp and without a terminal, whatever --yes says.~yes~no~no~no~none
flag~mariadb-password~--yes~~Do not ask (still refused without a person at a terminal).
cmd~doctor~benchbar doctor [--json] [--fix-hints] [--quick] [--ack CHECK] [--unack CHECK] [--prerequisites] [--fetch]~Read only health report. Exit 1 when something FAILs.~no~no~no~no~document
flag~doctor~--json~~One JSON document.
flag~doctor~--fix-hints~~Only the fix commands, one per line.
flag~doctor~--quick~~Skip the slow checks and say which.
flag~doctor~--ack~CHECK~Silence one named WARN for this bench until its message changes.
flag~doctor~--unack~CHECK~Undo --ack.
flag~doctor~--prerequisites~~What this machine needs before an install; no bench is needed. With --json it prints a document; --bench-dir names the folder a new bench would go to.
flag~doctor~--fetch~~git fetch the branches of the apps your focus apps need first. Without it, doctor never touches the network.
cmd~repair~benchbar repair [--dry-run|--apply TOKEN] [--yes] [--json]~Apply only the fixes doctor flagged, in dependency order.~yes~yes~yes~yes~stream
flag~repair~--background~~Start it detached and print its op_id at once (benchbar op status, op wait follow it). Nothing can be asked: needs --yes and the inputs in the environment, as for an agent. Not with --dry-run.
flag~repair~--dry-run~~Print the plan, change nothing. With --json the plan line carries its token.
flag~repair~--apply~TOKEN~Run exactly that plan (with --yes); refused when the plan changed since the token was made. Without a token the run is as before.
flag~repair~--yes~~Do not ask.
flag~repair~--secrets-stdin~~Read the passwords from standard input, not the environment: KEY=VALUE lines (ADMIN_PASSWORD, MARIADB_ROOT_PASSWORD, BENCHBAR_SUDO_PASSWORD), LF only, ended by an empty line (required). For a program that has no terminal.
env~repair~BENCHBAR_SUDO~Linux only: env makes the sudo steps use BENCHBAR_SUDO_PASSWORD, no terminal needed (a wrong one fails at once with error_id sudo_password_wrong, before any change).
env~repair~BENCHBAR_SUDO_PASSWORD~The sudo password, with BENCHBAR_SUDO=env. Read once at startup and removed from the environment; never in argv, the log or a child.
cmd~status~benchbar status [--json] [--ping] [--deep]~State, pid, stop reason, site ping and Redis of the bench (benchstatus).~no~no~no~no~document
env~status~BENCHBAR_LOAD_ALL~Debugging switch: 1 loads every library, as before the lean start (the output is the same; use it to see whether a problem comes from the lean load).
flag~status~--ping~~Ask every site, not only the default one.
flag~status~--deep~~Also ask the ready parts that start programs: workers (pgrep, lsof) and stale (find: a Python file under apps/ changed after the bench started). Without it ready.workers and ready.stale are null.
flag~status~--json~~One JSON document. It adds redis, sites[].served (does the running bench serve the site) and the ready object (is the bench ready to serve).
cmd~stats~benchbar stats [--json]~CPU, memory and process count of the running bench's own processes (the set down stops, with their children).~no~no~no~no~document
note~stats~It also gives the speed figure that the Mac app derives from the CPU. With --json, resources is null while the bench is stopped. It only reads.
env~stats~FL_STATS_WINDOW~Linux only: seconds between the two CPU samples (default 0.5).
cmd~list~benchbar list [--json]~Every bench benchbar knows about. Never pings a site.~no~no~no~no~document
env~list~BENCHBAR_LOAD_ALL~Debugging switch: 1 loads every library, as before the lean start (the output is the same; use it to see whether a problem comes from the lean load).
cmd~scan~benchbar scan PATH [--json]~Find benches recursively in a folder (read only).~no~no~no~no~document
cmd~register~benchbar register PATH...~Remember selected benches without changing their services.~no~no~no~yes~document
cmd~up~benchbar up [--services-only] [--json]~Start the bench in the background (benchup).~yes~no~no~yes~stream
flag~up~--services-only~~Start only the bench's Redis (for a restore or a migrate); down stops it.
cmd~down~benchbar down [--json]~Stop the bench and keep it stopped across reboots (benchdown).~no~no~no~yes~stream
cmd~restart~benchbar restart [--json]~Restart the bench, for example after changing Python code.~yes~no~no~yes~stream
cmd~wait~benchbar wait [--ready] [--for PART] [--timeout SECS] [--json]~Block until the bench is ready (agent loaded, processes, site ping 2xx or 3xx, socketio, Redis, a worker, no Python file changed since the start), or until one part is.~no~no~no~no~document
note~wait~Exit 0 when ready, 1 when not ready in time, with what is missing and the fix. It only reads and starts nothing.
flag~wait~--ready~~Wait for every part (the default).
flag~wait~--for~PART~Wait for one part only: agent, processes, web, socketio, redis, workers or stale.
flag~wait~--timeout~SECS~Give up after SECS seconds, 0 to 3600 (default 60). 0 checks once.
cmd~logs~benchbar logs [-nN] [--worker|--worker-error|--previous] [--process NAME] [--since TIMESTAMP] [--since-restart] [--no-follow] [--json]~Tail logs/bench.log.~no~no~no~no~document
flag~logs~--worker~~Read logs/worker.log.
flag~logs~--worker-error~~Read logs/worker.error.log.
flag~logs~--previous~~Read logs/bench.previous.log (the starts before it are bench.previous.1.log to .3.log).
flag~logs~--process~NAME~web, socketio, schedule or worker. The worker one reads logs/worker.log.
flag~logs~--since~TIMESTAMP~Only lines at or after it (--json; ISO 8601, or HH:MM:SS today).
flag~logs~--since-restart~~Only lines after the bench's last start (--json).
flag~logs~--no-follow~~Print and exit.
flag~logs~-n~N~The last N lines (default 50); -nN, or a bare number, also works.
cmd~fg~benchbar fg~Stop the service and run honcho in the foreground.~yes~no~no~yes~none
cmd~watch~benchbar watch~Run bench watch for asset rebuilds.~no~no~no~no~none
cmd~autostart~benchbar autostart [on|off]~Whether the bench may come back after login.~no~no~no~yes~stream
cmd~listen~benchbar listen [local|all] [--dry-run] [--yes]~Where the bench's web server and socketio listen: 127.0.0.1 only (the default) or every interface.~yes~no~no~yes~stream
note~listen~The choice is stored per bench and applied to Procfile.lean; restart the bench to use it. Listening on every interface is a person's decision and is refused without a terminal.
cmd~uninstall-service~benchbar uninstall-service [--all] [--yes] [--dry-run]~Remove the agent, runner, Procfile.lean and shell helpers.~yes~no~no~yes~stream
flag~uninstall-service~--all~~Every bench with a benchbar agent, after one question. Run it before brew uninstall benchbar: brew cannot stop the agents itself.
flag~uninstall-service~--yes~~Do not ask; required without a terminal.
cmd~path~benchbar path~Print the bench directory (benchcd uses it).~no~no~no~no~none
env~path~BENCHBAR_LOAD_ALL~Debugging switch: 1 loads every library, as before the lean start (the output is the same; use it to see whether a problem comes from the lean load).
cmd~console~benchbar console [--site S]~bench --site SITE console: a Python shell with frappe.~yes~no~no~no~none
cmd~db~benchbar db [--site S] | benchbar db orphans [--json]~bench --site SITE mariadb: the site's database.~yes~no~no~no~none
cmd~db orphans~benchbar db orphans [--json]~Databases of frappe's shape (an underscore and 16 hex digits) that no site of any bench benchbar knows (or was told to forget, while its folder is there) refers to. A listed database may belong to a bench or program benchbar does not know. Read only: benchbar never drops them. Needs the MariaDB root password.~no~no~no~no~document
flag~db orphans~--json~~One document: checked and orphans, each with the archived site folder that names it, if any.
env~db orphans~MARIADB_ROOT_PASSWORD~Only when MariaDB has a password benchbar does not know.
cmd~run~benchbar run [--site S] [--timeout SECS] [--dry-run --json | --apply TOKEN --yes] -- COMMAND [FLAGS]~Run one command of the allow list (migrate, clear-cache, clear-website-cache, build, run-tests, doctor, list-apps, version) with bench's own environment, in the right bench and site, under a deadline. A command that changes things: --dry-run --json prints the plan and its token, --apply TOKEN --yes runs exactly that plan; migrate backs the site up first. Anything else is refused with exit 64 and the list.~yes~no~no~yes~document
flag~run~--timeout~SECS~Stop the bench command after this many seconds (1 to 7200; each command has a default, 60 to 1800). The backup before migrate is not counted.
flag~run~--dry-run~~Print the plan and its token, run nothing.
flag~run~--apply~TOKEN~Run exactly that plan (with --yes).
flag~run~--yes~~Do not ask before a change; with --apply it confirms the plan was reviewed.
cmd~db~benchbar db [--site S]~bench --site SITE mariadb: the site's database.~yes~no~no~no~none
cmd~open~benchbar open [--site S] [--as USER] [--path P] [--no-browser] [--print-url] [--json]~Open a site in the browser, or open it signed in as USER (developer_mode sites that were opted in with site open-as on).~no~no~no~no~document
flag~open~--as~USER~Sign in as this user, no password. Refused unless site open-as is on for the site and developer_mode is on. A sign in runs the apps' on_login and on_session_creation hooks as a real login does: last_login, an Activity Log entry, a mail to System Managers for Administrator, an ERPNext Customer or Supplier for a Website User, and Frappe may end the user's oldest session (simultaneous_sessions).
flag~open~--path~P~Where to land, for example /app/todo. Default: /app, or / for a Website User.
flag~open~--no-browser~~Start the session, open nothing.
flag~open~--print-url~~Print the link (it holds the session id) instead of opening it; in --json as url. With --as, refused under BENCHBAR_NONINTERACTIVE, --for-agent and mcp.
flag~open~--json~~One JSON document; url only with --print-url.
cmd~users~benchbar users [--site S] [--search Q] [--limit N] [--json]~Enabled users of a site, for open --as (needs site open-as on).~no~no~no~no~document
flag~users~--search~TEXT~Only users whose id or full name contains TEXT.
flag~users~--limit~N~At most N users (1 to 500, default 50).
flag~users~--json~~One JSON document.
cmd~pull~benchbar pull HOST:SITE [--as NAME] [--from-dir DIR] [--replace] [--dry-run|--apply TOKEN --yes] [--json]~Copy a production site over SSH into a new local site.~yes~no~yes~yes~stream
flag~pull~--background~~Start it detached and print its op_id at once (benchbar op status, op wait follow it). Nothing can be asked: needs --yes and the inputs in the environment, as for an agent. Not with --dry-run.
flag~pull~--as~NAME~Local site name (default SITE.local).
flag~pull~--from-dir~DIR~A backup set downloaded by hand, no SSH.
flag~pull~--remote-bench~DIR~The bench folder on the server.
flag~pull~--new-backup~~Run bench backup on the server first.
flag~pull~--keep-secrets~~Keep the copy's integrations and stored secrets (by default they are switched off and cleared). A person's decision: refused under --for-agent, benchbar mcp and BENCHBAR_NONINTERACTIVE=1.
flag~pull~--replace~~Restore over an existing local site, after backing it up.
flag~pull~--confirm-site~SITE~With --new-backup: the site name, instead of typing it.
flag~pull~--skip-app~APP~Restore without APP (its tables stay behind as orphans); repeat for more apps.
flag~pull~--no-files~~Database only.
flag~pull~--no-migrate~~Stop after the restore and the dev safety, before bench migrate.
flag~pull~--before-migrate~SCRIPT~An executable run after the restore, before migrate, in the bench folder, with BENCHBAR_SITE, BENCHBAR_BENCH and BENCHBAR_DB_NAME; a failing script stops the run.
flag~pull~--keep-scheduler~~Leave the scheduler as production has it.
flag~pull~--keep-staging~~Keep the downloaded backup in the bench's .benchbar/pulls/ after a successful run.
flag~pull~--dry-run~~Print the plan and its token, change nothing.
flag~pull~--apply~TOKEN~Run exactly that plan (with --yes); refused when the plan changed since the token was made.
flag~pull~--secrets-stdin~~Read the passwords from standard input, not the environment: KEY=VALUE lines (ADMIN_PASSWORD, MARIADB_ROOT_PASSWORD, BENCHBAR_SUDO_PASSWORD), LF only, ended by an empty line (required). For a program that has no terminal.
env~pull~MARIADB_ROOT_PASSWORD~Only when MariaDB has a password benchbar does not know.
cmd~report~benchbar report [--print] [--json]~Redacted diagnostics zip on the Desktop for bug reports.~no~no~no~no~document
flag~report~--print~~Print to the terminal instead of writing the zip.
flag~report~--out~DIR~Write the zip into this folder (default: the Desktop).
flag~report~--json~~Print {"zip": path, "redactions": n}, for the app and scripts.
cmd~docs~benchbar docs [TOPIC] [--print]~Open the documentation, or one topic's page.~no~no~no~no~none
flag~docs~--print~~Print the page's address instead of opening it.
cmd~self-update~benchbar self-update [--check] [--dry-run] [--json]~Update the benchbar CLI and the BenchBar app with the one line installer, after asking.~yes~no~yes~yes~document
note~self-update~A Homebrew install runs brew upgrade askysh/tap/benchbar instead. It never touches a bench and never runs bench update.
flag~self-update~--check~~This version against the latest.
flag~self-update~--dry-run~~Print the plan, change nothing.
cmd~where~benchbar where [--json]~How this CLI was installed (homebrew, managed, checkout, other), the path it records for itself, its state folder and the BenchBar app.~no~no~no~no~document
env~where~BENCHBAR_LOAD_ALL~Debugging switch: 1 loads every library, as before the lean start (the output is the same; use it to see whether a problem comes from the lean load).
cmd~mcp~benchbar mcp [--print-agents-md] [--calls [N]] [--allow-bench PATH]~Model Context Protocol server on stdio for coding agents.~no~no~no~no~none
flag~mcp~--print-agents-md~~Print a snippet for a project's AGENTS.md or CLAUDE.md and exit.
flag~mcp~--calls~[N]~Print the last N (default 50) lines of the audit log of MCP calls (mcp-calls.jsonl in the state folder) and exit.
flag~mcp~--allow-bench~PATH~Let the changing tools act on this bench folder although benchbar does not know it (repeatable; the environment variable BENCHBAR_MCP_ALLOW_BENCH holds a : separated list). A person's choice, never a tool argument.
env~mcp~BENCHBAR_MCP_APPLY_DELAY~Seconds a plan must have been returned before its apply is accepted (default 5; 0 turns the wait off).
cmd~op~benchbar op status|list|wait ...~The long runs: every run that changes things has an op_id (in its plan, step, progress and done lines) and a record that benchbar remembers (the newest 100).~no~no~no~no~none
cmd~op status~benchbar op status [OP_ID] [--json]~One operation (its command, bench, site, state, last step, last progress, exit, log), or the ten newest. A run that died without a done line is interrupted. --json adds the run's done line as result once it ended.~no~no~no~no~document
cmd~op list~benchbar op list [--running] [--limit N] [--json]~The operations, newest first.~no~no~no~no~document
flag~op list~--running~~Only the ones that run now.
flag~op list~--limit~N~At most N (1 to 100, default 20).
cmd~op wait~benchbar op wait OP_ID [--timeout SECS] [--json]~Wait until the operation is not running, then print it. Exit 0 when it ended with exit 0, else 1 (failed, interrupted or still running at the timeout: --json says which).~no~no~no~no~document
flag~op wait~--timeout~SECS~Give up after SECS seconds (the operation goes on); default: wait for it.
cmd~history~benchbar history [--bench PATH] [--since TIME] [--limit N] [--json]~What ran on this machine, newest first: every run that changed things, with its op_id, command line (secrets as ***), who started it, bench, site, times, exit, what it changed and its log. A run an agent started through benchbar mcp also names the MCP tool and the client that made the call. Kept in history.jsonl in the state folder, 1 MB and three older files.~no~no~no~no~document
flag~history~--bench~PATH~Only the runs on this bench.
flag~history~--since~TIME~Only the runs that started since 90m, 12h, 7d, 2w ago, a date (2026-11-19, UTC) or a time (2026-11-19T10:15:00Z).
flag~history~--limit~N~At most N runs (1 to 1000, default 20).
env~history~BENCHBAR_CALLER~Who started a run, for the history: terminal, app, tray, mcp, agent or script. The Mac app, the tray and benchbar mcp set it; --for-agent says agent; without it a terminal on stdin is terminal and anything else script. A label the caller sets, not a proof: any process of the user can set it, and a value outside the list is ignored; NAME:REST counts as NAME (the MCP server's holder mcp:CLIENT:PID is mcp). The history never changes BENCHBAR_CALLER, which a lease uses as its holder name.
cmd~help~benchbar help~The global help text.~no~no~no~no~none
cmd~commands~benchbar commands --json~This table: every command, flag and environment variable.~no~no~no~no~document
env~commands~BENCHBAR_LENIENT_FLAGS~Applies to every command: 1 turns the error for an unknown option (exit 64) back into a warning on stderr, as before 0.9.0, for a script that passed options a command never read. Without it a typo of --dry-run next to --yes can no longer run for real.
env~commands~BENCHBAR_LOAD_ALL~Debugging switch: 1 loads every library, as before the lean start (the output is the same; use it to see whether a problem comes from the lean load).
cmd~ports~benchbar ports plan|setup|apply|check|mode ...~Port allocation for several benches.~no~no~no~no~none
cmd~ports plan~benchbar ports plan [--json] -- PATH ...~Read-only preview of the port allocation and its approval token.~no~no~no~no~document
flag~ports plan~--json~~The plan and its token as one JSON document.
cmd~ports setup~benchbar ports setup [--dry-run] -- PATH ...~Preview the port changes, confirm once, then apply them.~yes~yes~no~yes~stream
flag~ports setup~--dry-run~~Show the preview and change nothing.
cmd~ports apply~benchbar ports apply TOKEN --yes [--json] -- PATH ...~Apply a reviewed plan; refuses a stale token.~no~yes~no~yes~stream
flag~ports apply~--yes~~Required: the plan was reviewed.
env~ports apply~BENCHBAR_SUDO~Linux only: env makes the sudo steps use BENCHBAR_SUDO_PASSWORD, no terminal needed (a wrong one fails at once with error_id sudo_password_wrong, before any change).
env~ports apply~BENCHBAR_SUDO_PASSWORD~The sudo password, with BENCHBAR_SUDO=env. Read once at startup and removed from the environment; never in argv, the log or a child.
cmd~ports check~benchbar ports check [--json]~Check the bench for port conflicts.~no~no~no~no~document
flag~ports check~--json~~The conflicts as one JSON document.
cmd~ports mode~benchbar ports mode automatic|fixed~Keep automatic or fixed ports for the bench.~no~no~no~yes~stream
cmd~site~benchbar site list|add|default|hosts|backup|backups|restore|snapshot|snapshots|rollback|drop|open-as ...~The sites of a bench.~no~no~no~no~none
cmd~site list~benchbar site list [--json]~The bench's sites; the default one is what benchup waits for.~no~no~no~no~document
cmd~site add~benchbar site add NAME [--bundle NAME|--apps "a b"] [--dry-run|--apply TOKEN] [--yes] [--json]~bench new-site, the hosts line and apps from apps/. The default site stays.~yes~yes~no~yes~stream
flag~site add~--background~~Start it detached and print its op_id at once (benchbar op status, op wait follow it). Nothing can be asked: needs --yes and the inputs in the environment, as for an agent. Not with --dry-run.
flag~site add~--bundle~NAME~App bundle to install.
flag~site add~--apps~"a b"~Apps of apps/ to install.
flag~site add~--dry-run~~Print the plan and its token, change nothing.
flag~site add~--apply~TOKEN~Run exactly that plan (with --yes).
flag~site add~--yes~~Do not ask.
flag~site add~--secrets-stdin~~Read the passwords from standard input, not the environment: KEY=VALUE lines (ADMIN_PASSWORD, MARIADB_ROOT_PASSWORD, BENCHBAR_SUDO_PASSWORD), LF only, ended by an empty line (required). For a program that has no terminal.
env~site add~ADMIN_PASSWORD~The new site's Administrator password.
env~site add~MARIADB_ROOT_PASSWORD~Only when MariaDB has a password benchbar does not know.
env~site add~BENCHBAR_SUDO~Linux only: env makes the sudo steps use BENCHBAR_SUDO_PASSWORD, no terminal needed (a wrong one fails at once with error_id sudo_password_wrong, before any change).
env~site add~BENCHBAR_SUDO_PASSWORD~The sudo password, with BENCHBAR_SUDO=env. Read once at startup and removed from the environment; never in argv, the log or a child.
cmd~site default~benchbar site default NAME [--json]~Make NAME the default site.~no~no~no~yes~stream
cmd~site open-as~benchbar site open-as on|off|status [NAME] [--json]~Turn password-less sign in (open --as) on or off for a site, or show it. Changes benchbar's state only. on needs a person at a terminal.~yes~no~no~yes~stream
flag~site open-as~--yes~~Do not ask before turning on (still refused without a terminal session, BENCHBAR_NONINTERACTIVE=1).
flag~site open-as~--json~~JSON lines for on and off, one document for status.
cmd~share~benchbar share setup|users|preflight|start|stop|extend|status|code|invite|lock|unlock|people|remove|assign|log|open-as|teardown ...~Share a hardened copy of a site with people on your network: setup makes the copy and the identity, start and stop run the share.~no~no~no~no~none
cmd~share setup~benchbar share setup [--site S] [--from STAMP|latest] [--backup-now] [--users A,B] [--name LABEL] [--refresh] [--regenerate-identity] [--acknowledge-data] [--dry-run] [--yes] [--json]~Prepare sharing: the host identity and a hardened share copy of a site.~yes~no~no~yes~stream
flag~share setup~--users~A,B~The Frappe users who may sign in to the copy, one seat each. They must be enabled System Users; each loses the roles that can run code or change settings, in the copy only. Default: the last setup's.
flag~share setup~--from~STAMP|latest~The backup set of the site to copy (benchbar site backups S lists them). Default: the newest complete one.
flag~share setup~--backup-now~~Take a backup of the site first (benchbar site backup S) and copy that.
flag~share setup~--name~LABEL~The room's label, at most 40 printable characters. Default: "<your name>'s room".
flag~share setup~--refresh~~Replace the existing copy (it is backed up first). Anything guests changed in it is lost; needed to change --users.
flag~share setup~--regenerate-identity~~Replace the host's key and certificate and empty the paired Macs: every pairing becomes invalid. Asks first (--yes).
flag~share setup~--acknowledge-data~~Agree that the copy holds the site's real data (people, customers, contacts, addresses). Without it setup stops before any change, naming what the copy holds.
flag~share setup~--dry-run~~Print the plan (size, time, the data the copy holds) and change nothing.
flag~share setup~--yes~~Do not ask before replacing the copy or the identity.
flag~share setup~--json~~JSON lines: plan, steps, done.
env~share setup~MARIADB_ROOT_PASSWORD~Making the copy restores it as MariaDB's root user: the password from the Keychain, this variable, or typed at a terminal. With none of them, setup and its dry run exit 2 before any change.
cmd~share users~benchbar share users [--site S] [--json]~The users of a site who can take a seat in a shared copy, and which roles each would lose there.~no~no~no~no~document
cmd~share preflight~benchbar share preflight [--static|--critical] [--quiet] [--json]~The checks that prove this Mac is safe to share the hardened copy on the LAN; exits 1 when one fails.~no~no~no~no~document
flag~share preflight~--static~~Only the checks that run before anything starts: the copy, its seats, node, the firewall.
flag~share preflight~--critical~~Only the fast checks a running share repeats: the pf block (probed from this Mac's LAN address with its own listener and a control), the share web process, the bench's Redis.
flag~share preflight~--quiet~~List only the checks that are not ok.
flag~share preflight~--json~~One document: protocol, ok, lan_ip and the checks, each with a status, a message and a fix_action.
cmd~share start~benchbar share start [--for DUR] [--name LABEL] [--open-seats] [--dry-run] [--json]~Start sharing on the LAN until the deadline. You give out the seats (benchbar share assign) unless --open-seats is passed.~yes~no~no~yes~stream
flag~share start~--for~DUR~How long the share runs: 30m, 4h; from 5 minutes to 12 hours. Default: 4h.
flag~share start~--name~LABEL~The room's label for this share, at most 40 printable characters. Default: the one share setup recorded.
flag~share start~--open-seats~~Guests take a free seat themselves, as before 0.9.0: anyone with the room code takes any free seat, the most privileged one included. Without it you give out the seats: a person who joins waits (up to 10 minutes) until you run benchbar share assign for them, and cannot take or change a seat themselves.
flag~share start~--assign-seats~~The default, said out loud: you give out the seats. Not with --open-seats.
flag~share start~--dry-run~~Print the plan and start nothing.
flag~share start~--json~~JSON lines: plan, steps, done (with the deadline).
cmd~share stop~benchbar share stop [--json]~Stop sharing: the gateway and the job end, the room empties, every session of the copy ends. Never refused (no dry run).~no~no~no~yes~stream
flag~share stop~--json~~JSON lines: steps, done.
cmd~share extend~benchbar share extend --by DUR [--json]~Move the deadline of the running share, up to 12 hours from its start.~no~no~no~yes~stream
flag~share extend~--by~DUR~How much later: 30m, 1h; from 5 minutes to 12 hours.
flag~share extend~--json~~JSON lines: done, with the new deadline.
cmd~share status~benchbar share status [--preflight] [--json]~The share: on, off, expired or error, the time left, the copy, the room's counts. Reads only.~no~no~no~no~document
flag~share status~--preflight~~Run the critical checks too and add them, each with its fix_action.
flag~share status~--json~~One document (never the room code).
cmd~share code~benchbar share code [--new] [--json]~The room code, on the terminal only: the one way it leaves the gateway (--json is the app's read). Refused under BENCHBAR_NONINTERACTIVE, --for-agent and mcp.~no~no~no~no~document
flag~share code~--new~~Draw a new code first: the failure budget resets, the people in the room stay, a code already handed out stops working.
flag~share code~--json~~One document with the code: never logged, never stored.
cmd~share invite~benchbar share invite [--install-url URL] [--json]~A ready-to-paste invite for the team channel: a benchbar://share/join link with the room, this Mac's key fingerprint, the code's salt, the code, the LAN address and the deadline. It carries the code, so it is refused under BENCHBAR_NONINTERACTIVE, --for-agent and mcp. Needs a running share.~no~no~no~no~document
flag~share invite~--install-url~URL~Where people download BenchBar, added to the invite text; one http:// or https:// address.
flag~share invite~--json~~One document with the invite text and its link: the code is in it, never logged, never stored.
cmd~share lock~benchbar share lock [--json]~Lock the room: nobody new can join until share unlock.~no~no~no~yes~stream
flag~share lock~--json~~JSON lines: done, with locked and lock_reason.
cmd~share unlock~benchbar share unlock [--json]~Unlock the room. A lock after 10 wrong codes stays until share code --new.~no~no~no~yes~stream
flag~share unlock~--json~~JSON lines: done, with locked and lock_reason.
cmd~share people~benchbar share people [--json]~The people in the room: name, Mac, address, seat, online. Reads only (it retries a wipe the gateway still owes).~no~no~no~no~document
flag~share people~--json~~One document: state; people, each with id, name, model, ip, seat_id, seat_full_name, online, joined, last_seen; seats, every seat of the room with seat_id, full_name, roles, held_by and held_by_name (null for a free seat); seat_mode (host or open).
cmd~share devices~benchbar share devices [--json]~Another name for share people.~no~no~no~no~document
flag~share devices~--json~~As share people --json.
cmd~share remove~benchbar share remove ID [--new-code] [--yes] [--json]~Remove a person from the room: their seat's sessions end and their Mac cannot join again with the current code; a new code (a new invite) lets them back. Asks first (--yes).~yes~no~no~yes~stream
flag~share remove~--new-code~~Also draw a new room code, for when the person is not known: a fresh Mac could join again with the old one. The new code also lets the removed Mac back, if they get it.
flag~share remove~--yes~~Do not ask first.
flag~share remove~--json~~JSON lines: done, with removed, new_code and the wipe.
cmd~share revoke~benchbar share revoke ID [--new-code] [--yes] [--json]~Another name for share remove.~yes~no~no~yes~stream
flag~share revoke~--new-code~~As share remove --new-code.
flag~share revoke~--yes~~Do not ask first.
flag~share revoke~--json~~As share remove --json.
cmd~share assign~benchbar share assign ID SEAT_ID [--json]~Move a person in the room to another free seat; the old seat's sessions end first.~no~no~no~yes~stream
flag~share assign~--json~~JSON lines: done, with the device and its new seat.
cmd~share log~benchbar share log [--device ID] [--since TIME] [--limit N] [--json]~What the people in the room opened in the last 14 days: time, Mac, seat, method, page (two path segments, never a document name), status.~no~no~no~no~document
flag~share log~--device~ID~Only this Mac (an id of share people).
flag~share log~--since~TIME~Only entries at or after it: ISO 8601, YYYY-MM-DD HH:MM:SS, a date, or HH:MM:SS today.
flag~share log~--limit~N~The newest N entries, 1 to 5000. Default: 200.
flag~share log~--json~~One document: entries (ts, device, user, method, path, status) and truncated. user is the seat's name (the seat's id when the room no longer has the seat), never an e-mail address but in a line written by 0.8.3.
cmd~share open-as~benchbar share open-as USER [--print-url] [--json]~Open the shared copy in this Mac's browser signed in as a seat, the way open --as does. Needs sharing on; never a user who is not a seat or can run code. Refused under BENCHBAR_NONINTERACTIVE, --for-agent, mcp and without a terminal (the app passes BENCHBAR_SUDO=gui).~yes~no~no~yes~document
flag~share open-as~--print-url~~Print the sign-in link instead of opening it; it holds the session.
flag~share open-as~--json~~One document without the link (never the session).
cmd~share teardown~benchbar share teardown [--yes] [--json]~Stop sharing, drop the copy (backed up first), and delete the share folder with the host identity and the room; the Time Machine exclusions go too. Asks first (--yes); only a person runs it.~yes~no~no~yes~stream
flag~share teardown~--yes~~Do not ask first.
flag~share teardown~--json~~JSON lines: steps, done with copy_dropped, archived_path and state_removed.
cmd~share join~benchbar share join [ADDRESS[:PORT]] [--host-key HEX] [--name NAME] [--seat SEAT_ID] [--no-wait] [--no-open] [--dry-run] [--yes] [--json]~Join somebody's room as a guest. With ADDRESS it asks for the room code, without one for the invite link: neither is ever an argument. It shows the room and the host key first, waits for a seat, and opens the room on a localhost address of this computer. Refused under BENCHBAR_NONINTERACTIVE, --for-agent and mcp.~yes~no~yes~yes~document
flag~share join~--host-key~HEX~Join only if the host shows this key (the 64 hex digits: host_pin of a look with --dry-run --json). Another key is refused before any request, with exit code 3. Public, so an argument is fine.
flag~share join~--name~NAME~The name the host sees for this computer (default: the computer's name).
flag~share join~--seat~SEAT_ID~Take this seat, in a room where guests pick theirs (the host started it with --open-seats).
flag~share join~--no-wait~~Do not wait for the host to give a seat: join, say so, and end.
flag~share join~--no-open~~Do not open the browser; the address is printed.
flag~share join~--dry-run~~Show the room, its address and the host key, and stop: nothing that depends on the code is sent, nothing is saved.
flag~share join~--yes~~Do not ask "Join this room?" after an invite link.
env~share join~BENCHBAR_SUDO~gui: the app or the tray made the run after its own window; the code or the invite link is then the first line of stdin.
cmd~share joined~benchbar share joined [--json]~The rooms this computer joined: id (16 digits of the host key), room, host, address, whether it is open here, the seat and the local address. Reads only, and dials no room.~no~no~no~no~document
cmd~share leave~benchbar share leave [ROOM] [--json]~Leave a room: the host is told, so the seat is free and its sessions end, and the local address closes. The room and this computer's key for its host stay. ROOM is the id from share joined; not needed with one room. Only a person runs it.~no~no~yes~yes~stream
cmd~share forget~benchbar share forget [ROOM] [--json]~Leave a room and delete it from this computer with the key made for its host: to that host, a later join is a new computer. Only a person runs it.~no~no~yes~yes~stream
cmd~lan-guard~benchbar lan-guard install|status|remove|allow-node ...~The LAN guard: on macOS a pf anchor (com.apple/250.benchbar), on Linux an nftables table (inet benchbar), that refuses the bench ports (8000:8099 9000:9099 11000:11099 13000:13099 3306) to anything but this machine, and on macOS the firewall allow for the share gateway's node.~yes~yes~no~yes~stream
cmd~lan-guard install~benchbar lan-guard install [--dry-run] [--yes] [--json]~Write the pf anchor and the launch daemon (macOS), or the nftables rules file and the systemd unit (Linux), that load it at boot, with sudo once, then probe the block from the LAN address. Unchanged, with no sudo, when the guard already matches. A person's decision: refused under BENCHBAR_NONINTERACTIVE, --for-agent and mcp, and without a terminal (macOS: unless BENCHBAR_SUDO=gui).~yes~yes~no~yes~stream
flag~lan-guard install~--dry-run~~Print what would be written and run, with no sudo.
flag~lan-guard install~--yes~~Do not ask first (sudo still asks for the password).
flag~lan-guard install~--json~~JSON lines: done, with state, active, ports, anchor and lan_ip.
cmd~lan-guard status~benchbar lan-guard status [--json]~Whether the guard is installed, missing or outdated, and whether the bench ports are refused on this machine's LAN address (a probe with its own listener). Reads only; never refused.~no~no~no~no~document
flag~lan-guard status~--json~~One document: state, active (null with no LAN address), ports, anchor, lan_ip.
cmd~lan-guard remove~benchbar lan-guard remove [--yes] [--json]~Unload and delete the pf anchor and its daemon (macOS), or the nftables table, its systemd unit and its rules file (Linux, nothing else in nftables), with sudo once. On macOS it also takes the node that lan-guard allow-node added out of the firewall's allowed apps. Sharing refuses to start without the guard. Asks first. Runs while the lan-rooms Lab is off too.~yes~yes~no~yes~stream
flag~lan-guard remove~--yes~~Do not ask first.
flag~lan-guard remove~--json~~JSON lines: done, with the guard's state.
cmd~lan-guard allow-node~benchbar lan-guard allow-node [--yes] [--json]~Add the realpath of the node the share gateway runs on to the macOS firewall's allowed apps, with sudo once. Unchanged when the firewall is off or already allows it; needed again after a Homebrew upgrade of node (the older entry then goes). The entry is per program: every script that node runs can then accept incoming connections; lan-guard remove takes it out again. macOS only: refused on Linux.~yes~yes~no~yes~stream
flag~lan-guard allow-node~--yes~~Do not ask first.
flag~lan-guard allow-node~--json~~JSON lines: done, with node (the realpath).
cmd~site hosts~benchbar site hosts [--prune] [--dry-run]~Add a 127.0.0.1 line for every site to /etc/hosts. On Linux it edits nothing: a *.localhost name already resolves, and any other name gets the sudo line to run yourself. --prune removes instead the lines in benchbar's block whose site no bench benchbar knows has (one backup, one sudo; without a terminal it prints the command).~yes~yes~no~yes~stream
flag~site hosts~--prune~~Remove the stale lines of benchbar's block instead of adding the missing ones (sites of a forgotten bench whose folder is still there count as sites). The printed fallback command keeps a .bak copy. macOS only.
cmd~site backup~benchbar site backup NAME [--with-files] [--json]~bench --site NAME backup.~no~no~no~yes~document
flag~site backup~--background~~Start it detached and print its op_id at once (benchbar op status, op wait follow it). Nothing can be asked: needs --yes and the inputs in the environment, as for an agent. Not with --dry-run.
flag~site backup~--with-files~~Include the uploads.
cmd~site backups~benchbar site backups NAME [--json]~The site's backups, newest first.~no~no~no~no~document
cmd~site restore~benchbar site restore NAME --from STAMP|PATH [--from-site S] [--new] [--neutralise] [--no-migrate] [--before-migrate SCRIPT] [--with-files] --dry-run --json, then --apply TOKEN --yes~Restore a local backup set into a site (a new one with --new), after a backup of the target; a reviewed plan.~no~yes~no~yes~document
flag~site restore~--background~~Start it detached and print its op_id at once (benchbar op status, op wait follow it). Nothing can be asked: needs --yes and the inputs in the environment, as for an agent. Not with --dry-run.
flag~site restore~--from~STAMP|PATH~The backup set: its stamp in the target's (or --from-site's) backup folder, or the database file's path.
flag~site restore~--from-site~S~Read the stamp from this site's backups.
flag~site restore~--new~~Create the site (bench new-site) first.
flag~site restore~--neutralise~~Switch the restored site's integrations off and clear its stored secrets, after the restore and before migrate (the list pull runs; the Administrator login is kept). Needed for a set from outside this bench when no person runs the restore.
flag~site restore~--no-migrate~~Stop after the restore, before bench migrate.
flag~site restore~--before-migrate~SCRIPT~An executable run after the restore, before migrate.
flag~site restore~--with-files~~Restore the uploads too.
flag~site restore~--dry-run~~Print the plan and its token.
flag~site restore~--apply~TOKEN~Run exactly that plan (with --yes).
env~site restore~MARIADB_ROOT_PASSWORD~Only when MariaDB has a password benchbar does not know.
cmd~site move~benchbar site move NAME --to-bench PATH [--no-migrate] --dry-run --json, then --apply TOKEN --yes~Move a site to another registered bench on this machine: a backup with files, the restore there under the same name, migrate, a check that it lists the same apps there, then the drop here (a second backup first; the backups stay in archived/sites). The source bench must be stopped (benchbar down), or writes made after the first backup would be lost. Never the default site of either bench; a failed step before the drop leaves the site here as it was. A reviewed plan.~no~yes~no~yes~document
flag~site move~--to-bench~PATH~The bench the site goes to: a bench benchbar knows (benchbar register PATH), not this one.
flag~site move~--no-migrate~~Stop after the restore, before bench migrate.
flag~site move~--dry-run~~Print the plan and its token.
flag~site move~--apply~TOKEN~Run exactly that plan (with --yes).
env~site move~MARIADB_ROOT_PASSWORD~Only when MariaDB has a password benchbar does not know.
cmd~site snapshot~benchbar site snapshot NAME [--label TEXT] [--json]~Save the state of a site (database, files, site_config, the apps and their commits) in sites/NAME/snapshots, which frappe's backup pruning never touches. Changes nothing in the site. To remove snapshots: benchbar site snapshot drop.~no~no~no~yes~document
flag~site snapshot~--background~~Start it detached and print its op_id at once (benchbar op status, op wait follow it). Nothing can be asked: needs --yes and the inputs in the environment, as for an agent. Not with --dry-run.
flag~site snapshot~--label~TEXT~What the snapshot is for (up to 120 characters, no quotes); it is part of the folder name.
flag~site snapshot~--dry-run~~Print what would happen, change nothing.
cmd~site snapshot drop~benchbar site snapshot drop NAME SNAPSHOT|--prune [--keep N] [--force-undo-point] [--yes] [--dry-run] [--json]~Remove one snapshot of a site, or with --prune the ones beyond the newest N. A person's choice: refused for an agent (--for-agent, benchbar mcp, BENCHBAR_NONINTERACTIVE=1); its --dry-run says what would go and is open to an agent. Never the undo point of a rollback unless --force-undo-point.~no~no~no~yes~document
flag~site snapshot drop~--prune~~Remove the snapshots beyond the newest N (never an undo point of a rollback).
flag~site snapshot drop~--keep~N~With --prune: how many to keep (default 10, or SNAPSHOT_KEEP in the bench's state file).
flag~site snapshot drop~--force-undo-point~~With one named snapshot: also remove an undo point of a rollback (a plain drop refuses it).
flag~site snapshot drop~--yes~~Do not ask. Refused for an agent: drop is a person's choice.
flag~site snapshot drop~--dry-run~~Print what would be removed, change nothing.
cmd~site snapshots~benchbar site snapshots NAME [--keep N] [--json]~The site's snapshots, newest first: label, time, size, apps with their commits, and whether the bench's apps still match.~no~no~no~no~document
flag~site snapshots~--keep~N~Say which snapshots are beyond the newest N (default 10, or SNAPSHOT_KEEP in the bench's state file). Nothing is removed.
cmd~site rollback~benchbar site rollback NAME --to SNAPSHOT|latest [--no-migrate] --dry-run --json, then --apply TOKEN --yes~Put a snapshot back into the site: its database and files. The current state is snapshotted first (label before rollback), so a rollback can be undone. Migrates only when the bench's apps differ from the snapshot's; a reviewed plan.~no~yes~no~yes~document
flag~site rollback~--background~~Start it detached and print its op_id at once (benchbar op status, op wait follow it). Nothing can be asked: needs --yes and the inputs in the environment, as for an agent. Not with --dry-run.
flag~site rollback~--to~SNAPSHOT~The snapshot: its name, its stamp, or latest (benchbar site snapshots NAME lists them).
flag~site rollback~--no-migrate~~Stop after the restore, before bench migrate.
flag~site rollback~--dry-run~~Print the plan and its token.
flag~site rollback~--apply~TOKEN~Run exactly that plan (with --yes).
env~site rollback~MARIADB_ROOT_PASSWORD~Only when MariaDB has a password benchbar does not know.
cmd~site drop~benchbar site drop NAME --confirm-site NAME [--new-default OTHER] [--dry-run|--apply TOKEN --yes] [--json]~bench drop-site: a backup with files first, the folder moved to archived/sites.~no~yes~no~yes~document
flag~site drop~--confirm-site~NAME~Repeat the site name exactly.
flag~site drop~--new-default~OTHER~Required when NAME is the default site.
flag~site drop~--dry-run~~Print the plan, change nothing. With --json the plan carries a token.
flag~site drop~--apply~TOKEN~Run the plan of a dry run; refused when the sites, the default or the hosts line changed since (needs --yes).
flag~site drop~--secrets-stdin~~Read the passwords from standard input, not the environment: KEY=VALUE lines (ADMIN_PASSWORD, MARIADB_ROOT_PASSWORD, BENCHBAR_SUDO_PASSWORD), LF only, ended by an empty line (required). For a program that has no terminal.
env~site drop~MARIADB_ROOT_PASSWORD~Only when MariaDB has a password benchbar does not know.
cmd~app~benchbar app list|add|install|update|focus|unfocus ...~The apps of a bench.~no~no~no~no~none
cmd~app list~benchbar app list [--json] [--no-sites]~Every app: branch, commit, local changes, the sites that have it.~no~no~no~no~document
flag~app list~--no-sites~~Leave out the sites that have each app (faster).
cmd~app add~benchbar app add NAME|URL [--branch B] [--name N] [--commit SHA] [--install-on S,S] [NAME|URL ...] [--site S|--all-sites] --dry-run --json, then --apply TOKEN --yes~bench get-app from config/apps.tsv or any git URL, as a reviewed plan.~no~no~yes~yes~document
flag~app add~--background~~Start it detached and print its op_id at once (benchbar op status, op wait follow it). Nothing can be asked: needs --yes and the inputs in the environment, as for an agent. Not with --dry-run.
flag~app add~--branch~B~Branch or tag.
flag~app add~--name~N~The app's package name.
flag~app add~--commit~SHA~Pin the app to this commit (7 to 40 hex characters).
flag~app add~--install-on~S,S~Install this app on these sites only.
flag~app add~--site~S~Install it on this site.
flag~app add~--all-sites~~Install it on every site.
flag~app add~--skip-backup~~Install on the sites without a backup first (the plan takes one by default).
flag~app add~--dry-run~~Print the plan and its token.
flag~app add~--apply~TOKEN~Run exactly that plan (with --yes).
cmd~app install~benchbar app install NAME --site S [--skip-backup] [--dry-run --json | --apply TOKEN --yes]~Back up a site, then install an app of the bench on it.~no~no~no~yes~stream
flag~app install~--skip-backup~~Install without a backup of the site first.
flag~app install~--dry-run~~Print the plan as one JSON document with --json; it carries a token.
flag~app install~--apply~TOKEN~Run exactly that plan (with --yes); refused when the plan changed since the token was made.
cmd~app update~benchbar app update NAME [--skip-backup] [--dry-run --json | --apply TOKEN --yes]~Fast forward one app with a changelog first, back up its sites, migrate, build.~yes~no~yes~yes~stream
flag~app update~--background~~Start it detached and print its op_id at once (benchbar op status, op wait follow it). Nothing can be asked: needs --yes and the inputs in the environment, as for an agent. Not with --dry-run.
flag~app update~--skip-backup~~Migrate without a backup first.
flag~app update~--dry-run~~Print the plan as one JSON document with --json; it carries a token (null when there is nothing to do).
flag~app update~--apply~TOKEN~Run exactly that plan (with --yes); the plan is made again after a fetch, under the lock, and refused when it changed.
flag~app update~--discard-pending~~Drop the record of an update or add that stopped part way and stop: none of its steps and no update runs.
cmd~app focus~benchbar app focus [NAME] [--list] [--auto] [--fetch] [--json]~Focus apps: the ones you work on.~no~no~no~no~document
flag~app focus~--list~~List the focus apps (the default without a name).
flag~app focus~--auto~~With NAME: let benchbar decide again (undo a pin).
flag~app focus~--fetch~~git fetch the branches of the focus apps first.
cmd~app unfocus~benchbar app unfocus NAME~Pin NAME as not a focus app.~no~no~no~yes~document
cmd~lock~benchbar lock write|check|apply ...~The team lockfile benchbar.toml.~no~no~no~no~none
cmd~lock write~benchbar lock write [--lock PATH] [--no-commits] [--allow-dirty]~Write benchbar.toml from this bench.~yes~no~no~yes~stream
flag~lock write~--lock~PATH~Write this lockfile, and remember it for this bench.
flag~lock write~--no-commits~~Leave the commit hashes out (branches only).
flag~lock write~--allow-dirty~~Write it although an app has local changes.
cmd~lock check~benchbar lock check [--json]~Compare the bench with benchbar.toml. Exit 1 on any difference.~no~no~no~no~document
flag~lock check~--lock~PATH~Compare with this lockfile, and remember it for this bench.
cmd~lock apply~benchbar lock apply [--dry-run --json | --apply TOKEN --yes]~Clone missing apps, switch branches, fast forward to pinned commits.~yes~no~yes~yes~stream
flag~lock apply~--lock~PATH~Apply this lockfile, and remember it for this bench.
flag~lock apply~--dry-run~~Print the plan as one JSON document with --json; it carries a token (null when the apps match).
flag~lock apply~--apply~TOKEN~Run exactly that plan (with --yes); refused when the lockfile, an app or the plan changed since the token was made.
cmd~bench~benchbar bench forget|remove|scratch|gc ...~The end of a bench's life: forget it, remove it, mark it scratch, collect the scratch benches that expired.~no~no~no~no~none
cmd~bench forget~benchbar bench forget PATH --dry-run --json, then --apply TOKEN --yes~Unregister a bench: its service files are backed up and moved aside, its settings are set aside, the default bench is cleared when it was this one. The folder, sites, apps, databases and hosts lines stay (only the service files benchbar made in it go, each backed up first). An agent may run it with the plan and token.~yes~no~no~yes~document
flag~bench forget~--dry-run~~Print the plan and its token, change nothing.
flag~bench forget~--apply~TOKEN~Run exactly that plan (with --yes).
cmd~bench remove~benchbar bench remove PATH --dry-run --json, then --confirm-bench NAME --apply TOKEN --yes~Forget a bench, back up each site and drop its database (bench drop-site), then move the folder to <parent>/.benchbar-trash/ (never deleted). A person's decision: refused under BENCHBAR_NONINTERACTIVE, --for-agent and mcp, and without a terminal. Its plan (--dry-run) is open to agents. Never the default bench.~yes~no~no~yes~document
flag~bench remove~--dry-run~~Print the plan and its token, change nothing.
flag~bench remove~--apply~TOKEN~Run exactly that plan (with --yes).
flag~bench remove~--confirm-bench~NAME~Repeat the bench folder's name exactly.
env~bench remove~MARIADB_ROOT_PASSWORD~Only when MariaDB has a password benchbar does not know.
cmd~bench scratch~benchbar bench scratch PATH [--ttl DAYS] [--clear] [--json]~Mark an existing bench scratch (asks; --yes in a mode that cannot ask): it expires after DAYS (default 7, 1 to 90), or --clear keeps it. bench gc only collects benches benchbar knows (benchbar register PATH). install --scratch marks a new one.~no~no~no~yes~document
flag~bench scratch~--ttl~DAYS~Days until the bench expires.
flag~bench scratch~--yes~~Required to mark (it asks otherwise): marking is what lets bench gc remove the bench and its databases, and gc shows who marked it and when.
flag~bench scratch~--clear~~Not scratch any more.
cmd~bench gc~benchbar bench gc --dry-run --json, then --apply TOKEN --yes~List the scratch benches that expired (never the default bench) and remove each as bench remove does. Applying is a person's decision (refused under BENCHBAR_NONINTERACTIVE, --for-agent and mcp, and without a terminal); the plan is open to agents.~yes~no~no~yes~document
flag~bench gc~--dry-run~~Print the plan (expired, pending, skipped) and its token, change nothing.
flag~bench gc~--apply~TOKEN~Run exactly that plan (with --yes).
env~bench gc~MARIADB_ROOT_PASSWORD~Only when MariaDB has a password benchbar does not know.
cmd~profile~benchbar profile list|show|create|export|import|subscribe|update|remove|check ...~Team profiles.~no~no~no~no~none
cmd~profile list~benchbar profile list [--json]~Built in and team profiles.~no~no~no~no~document
cmd~profile show~benchbar profile show NAME~What a profile installs.~no~no~no~no~none
cmd~profile create~benchbar profile create NAME --from-bench PATH [--dir DIR]~Write a team profile from a bench.~no~no~no~yes~stream
flag~profile create~--from-bench~PATH~The bench to read the apps from.
flag~profile create~--dir~DIR~Write the profile into this folder (default ~/.config/benchbar/profiles).
cmd~profile export~benchbar profile export NAME [--out FILE] [--plan] [--json]~A copy to share.~no~no~yes~yes~document
flag~profile export~--out~FILE~Where to write (default ./NAME.toml).
flag~profile export~--branch~APP=BR~Export APP on BR instead of its default branch; repeatable.
flag~profile export~--drop~APP~Leave APP out of the copy; repeatable. Refused when a kept app requires it.
flag~profile export~--plan~~Print the review only, write nothing.
flag~profile export~--expect~DIGEST~Refuse unless the profile's digest is this (the one the plan showed).
cmd~profile import~benchbar profile import FILE|URL [--as NAME] [--plan] [--json]~Add a profile someone sent.~yes~no~yes~yes~document
flag~profile import~--as~NAME~Save it under this name.
flag~profile import~--plan~~Print the review only, write nothing.
flag~profile import~--expect~DIGEST~Refuse unless the profile's digest is this (the one the plan showed).
cmd~profile subscribe~benchbar profile subscribe GIT_URL [--plan|--yes] [--json]~Clone a team's config repo.~yes~no~yes~yes~document
flag~profile subscribe~--plan~~Print the review only, clone nothing.
cmd~profile update~benchbar profile update NAME|--all [--plan] [--json]~Fetch an import or subscription again.~yes~no~yes~yes~document
flag~profile update~--all~~Every import and subscription.
flag~profile update~--plan~~Print the review only, change nothing.
flag~profile update~--expect~DIGEST~Refuse unless the fetched profile's digest is this (the one the plan showed).
cmd~profile remove~benchbar profile remove NAME [--yes] [--json] [--dry-run | --apply TOKEN --yes]~Move an import or subscription aside.~yes~no~no~yes~document
flag~profile remove~--dry-run~~Print the plan (what moves aside) as one JSON document with --json; it carries a token.
flag~profile remove~--apply~TOKEN~Run exactly that plan (with --yes); refused when the file or the subscription changed since the token was made.
cmd~profile check~benchbar profile check NAME [--json]~Can git read every repo with your credentials?~no~no~yes~no~document
cmd~labs~benchbar labs [list|on NAME|off NAME|status NAME] [--yes] [--json]~Experiments: off until a person turns one on.~no~no~no~no~document
flag~labs~--json~~One JSON document.
cmd~labs list~benchbar labs list [--json]~The experiments, whether each is on, and the commands each gates.~no~no~no~no~document
flag~labs list~--json~~One JSON document.
cmd~labs on~benchbar labs on NAME [--yes] [--json]~Turn an experiment on after its warning. Refused without a person (BENCHBAR_NONINTERACTIVE, --for-agent, mcp) and without a terminal unless an app passes BENCHBAR_NONINTERACTIVE=0.~yes~no~no~yes~stream
flag~labs on~--json~~JSON lines, ending in a done line.
flag~labs on~--yes~~Do not ask before turning on (still refused without a person, BENCHBAR_NONINTERACTIVE=1).
cmd~labs off~benchbar labs off NAME [--json]~Turn an experiment off and undo what it started. Always allowed.~no~no~no~yes~stream
flag~labs off~--json~~JSON lines, ending in a done line.
cmd~labs status~benchbar labs status NAME [--json]~Whether an experiment is on. Exit 0 on, 1 off.~no~no~no~no~document
flag~labs status~--json~~One JSON document.
cmd~lease~benchbar lease take|release|renew|list ...~Leases: a bench or a site held for a while, so that restart, down, migrate, drop and restore by another agent or the app wait.~no~no~no~no~none
cmd~lease take~benchbar lease take (--bench PATH | --site NAME) [--for MINUTES] [--note TEXT] [--json]~Take a lease on a bench, or on one site of it, and return its id. Commands that change what it covers refuse, naming the holder and the end, unless they pass --lease ID. Reads are never refused. Benchbar's own state only.~no~no~no~yes~stream
flag~lease take~--bench~PATH~Lease the whole bench (every site of it).
flag~lease take~--site~NAME~Lease one site (global option; the bench is --bench-dir or the default one).
flag~lease take~--for~MINUTES~How long, from 1 to 480. Default: 30.
flag~lease take~--note~TEXT~Why, for whoever meets the lease: printable ASCII, at most 120 characters.
flag~lease take~--json~~JSON lines, ending in a done line with the lease and its id.
env~lease take~BENCHBAR_CALLER~The holder's name (1 to 40 letters, digits or . _ @ : + -). benchbar mcp sets it per client; without it a terminal run is the login name, and an agent run (BENCHBAR_NONINTERACTIVE, --for-agent) cannot take a lease.
cmd~lease release~benchbar lease release ID [--json]~Let go of a lease. Unchanged when it is already gone.~no~no~no~yes~stream
flag~lease release~--json~~JSON lines, ending in a done line.
cmd~lease renew~benchbar lease renew ID [--for MINUTES] [--json]~Push a lease's end to MINUTES from now (default: its first length). Refused once it has expired.~no~no~no~yes~stream
flag~lease renew~--for~MINUTES~How long from now, from 1 to 480.
flag~lease renew~--json~~JSON lines, ending in a done line with the lease.
cmd~lease list~benchbar lease list [--bench PATH] [--json]~The active leases of every bench, or of one. The id is shown to the lease's holder only (BENCHBAR_CALLER); for anyone else it is null.~no~no~no~no~document
flag~lease list~--bench~PATH~Only the leases of this bench.
flag~lease list~--json~~One JSON document.
cmd~notices~benchbar notices [--json] [--dismiss ID|--all]~The notices an update left: a default that changed, how to switch back and where it is explained. Each shows once in the terminal after the update and stays in status --json until dismissed.~no~no~no~no~document
flag~notices~--json~~One JSON document: notices[] with id, title, text, switch_back, doc and since.
flag~notices~--dismiss~ID~Hide one notice (also in the BenchBar app). An id that is already hidden is unchanged.
flag~notices~--all~~Hide every notice.
TABLE

# fl_cmd_load: FL_CMD_TABLE, the records between the two marker lines above. The lines
# before them are counted, the file is read whole (no program: `read -d ''` gets a file
# byte by byte on bash 3.2, and a string built line by line is quadratic), and the
# records are cut out with an offset and one pattern: % takes the last end marker, so
# no other line of this file may be just TABLE (tests/test-commands-cost.sh checks).
# LC_ALL=C: bytes, not characters.
fl_cmd_load() {
  local LC_ALL=C line off=0 t
  while IFS= read -r line; do
    off=$((off + ${#line} + 1))
    [[ "$line" != ": <<'TABLE'" ]] || break
  done <"$FL_CMD_FILE"
  t="$(<"$FL_CMD_FILE")"
  t="${t:off}"
  FL_CMD_TABLE="${t%$'\nTABLE\n'*}"
  # a file that cannot be read twice (commands.sh sourced from a pipe) gives no record and, before, no error
  [[ -n "$FL_CMD_TABLE" ]] || fl_die "The commands table could not be read from ${FL_CMD_FILE}." "commands.sh has to be sourced from a file, not from a pipe or a process substitution."
}
fl_cmd_load

fl_cmd_table() { printf '%s\n' "$FL_CMD_TABLE"; }
# The readers below loop over the variable with a here string, never over a
# pipe from fl_cmd_table: one that returns at its match closes the pipe on a
# writer that is still printing the table. A shell whose parent ignores
# SIGPIPE (GitHub Actions, an app) then prints "printf: write error: Broken
# pipe" on stderr, in the middle of a command's output, and the larger the
# table grew the more often it did.

# fl_cmd_visible_table: the table without the commands of a lab that is off
fl_cmd_visible_table() {
  local line hidden key word skip=0
  fl_lab_hidden_v hidden
  while IFS= read -r line; do
    case "$line" in
      cmd~*) key="${line#cmd~}"; key="${key%%~*}"; word="${key%% *}"
             case " ${hidden} " in *" ${word} "*) skip=1 ;; *) skip=0 ;; esac ;;
    esac
    [[ "$skip" == 1 ]] || printf '%s\n' "$line"
  done <<<"$FL_CMD_TABLE"
}

# Options every command takes, for the help text and `commands --json`.
read -r -d '' FL_CMD_GLOBAL_FLAGS <<'FLAGS' || true
--bench-dir~DIR~Bench to act on (default: remembered, or auto-detected).
--site~NAME~Site name (default: remembered, or from the bench).
--json~~JSON: one document for a command that reads, JSON lines for one that changes things.
--lease~ID~A lease you hold (benchbar lease take): lets this command change what the lease covers. Repeatable.
--break-lease~~Go ahead although a lease covers this command. A person at a terminal only; refused under BENCHBAR_NONINTERACTIVE, --for-agent and mcp.
--jsonl~~JSON lines (plan, step, progress, done) for any command that changes things.
--for-agent~~--jsonl for a command that changes things, --json for one that reads, plus BENCHBAR_NONINTERACTIVE=1, NO_COLOR=1 and --plain.
--plain~~No colors or spinners.
-h, --help~~Help for the command.
FLAGS
fl_cmd_global_flags() { printf '%s\n' "$FL_CMD_GLOBAL_FLAGS"; }

# fl_cmd_key_for COMMAND ARG: the table key: "COMMAND ARG" when the table has
# that subcommand, else COMMAND; fails when the table knows neither
fl_cmd_key_for() {
  local cmd="$1" arg="${2:-}" line third="${ARGS[1]:-}"
  # three words where the table has them (site snapshot drop): the third is the global ARGS[1]
  if [[ -n "$arg" && "$arg" != -* && -n "$third" && "$third" != -* ]]; then
    while IFS= read -r line; do
      [[ "$line" == "cmd~${cmd} ${arg} ${third}~"* ]] && { printf '%s' "${cmd} ${arg} ${third}"; return 0; }
    done <<<"$FL_CMD_TABLE"
  fi
  if [[ -n "$arg" && "$arg" != -* ]]; then
    while IFS= read -r line; do
      [[ "$line" == "cmd~${cmd} ${arg}~"* ]] && { printf '%s' "${cmd} ${arg}"; return 0; }
    done <<<"$FL_CMD_TABLE"
  fi
  while IFS= read -r line; do
    [[ "$line" == "cmd~${cmd}~"* ]] && { printf '%s' "$cmd"; return 0; }
  done <<<"$FL_CMD_TABLE"
  return 1
}

# fl_cmd_attr_v VAR KEY FIELD: tty, sudo, network, mutating or json of KEY
fl_cmd_attr_v() {
  local __line __k __u __s __t __sd __n __m __j __r=""
  while IFS= read -r __line; do
    [[ "$__line" == "cmd~${2}~"* ]] || continue
    IFS='~' read -r _ __k __u __s __t __sd __n __m __j <<<"$__line"
    case "$3" in tty) __r="$__t" ;; sudo) __r="$__sd" ;; network) __r="$__n" ;; mutating) __r="$__m" ;; json) __r="$__j" ;; esac
    break
  done <<<"$FL_CMD_TABLE"
  printf -v "$1" '%s' "$__r"
}

# fl_wrap_v VAR WIDTH FIRST REST TEXT: TEXT in lines of at most WIDTH characters (a word longer than that stands
# alone, unless it lists alternatives with |: it breaks after one). The first line starts with FIRST, the others with REST;
# the lines are joined by newlines, the last has none.
fl_wrap_v() {
  local __var="$1" __width="$2" __line="$3" __rest="$4" __out="" __word __fresh=1 __glue __piece __rem
  local __words=() __pieces=()
  read -ra __words <<<"$5" || true
  for __word in ${__words[@]+"${__words[@]}"}; do
    __pieces=("$__word")
    # a word that cannot fit on a line of its own, and lists alternatives (setup|users|...), breaks after a |
    if [[ "$__word" == *"|"* && $((${#__rest} + ${#__word})) -gt "$__width" ]]; then
      __pieces=(); __rem="$__word"
      while [[ "$__rem" == *"|"* ]]; do __pieces+=("${__rem%%|*}|"); __rem="${__rem#*|}"; done
      [[ -z "$__rem" ]] || __pieces+=("$__rem")
    fi
    __glue=" "
    for __piece in "${__pieces[@]}"; do
      if [[ "$__fresh" == 1 ]]; then
        __line="${__line}${__piece}"; __fresh=0
      elif [[ $((${#__line} + ${#__glue} + ${#__piece})) -gt "$__width" ]]; then
        __out="${__out}${__line}"$'\n'; __line="${__rest}${__piece}"
      else
        __line="${__line}${__glue}${__piece}"
      fi
      __glue=""
    done
  done
  printf -v "$__var" '%s' "${__out}${__line}"
}

# fl_cmd_help KEY: the table's entry as text, in lines of at most 100 characters. The text under the name is
# the summary and the note of the command (one text; `commands --json` gives it as the summary).
fl_cmd_help() {
  local key="$1" line kind k a b c flags="" envs="" summary="" note="" usage="" tty sudo net mut json w head fname
  while IFS= read -r line; do
    IFS='~' read -r kind k a b c <<<"$line"
    [[ "$k" == "$key" ]] || continue
    case "$kind" in
      cmd) usage="$a"; summary="$b"; IFS='~' read -r _ _ _ _ tty sudo net mut json <<<"$line" ;;
      note) note="$a" ;;
      flag) printf -v fname '%-22s' "${a}${b:+ ${b}}"; fl_wrap_v w 100 "  ${fname} " "                         " "$c"; flags="${flags}${w}"$'\n' ;;
      env) printf -v fname '%-22s' "$a"; fl_wrap_v w 100 "  ${fname} " "                         " "$b"; envs="${envs}${w}"$'\n' ;;
    esac
  done <<<"$FL_CMD_TABLE"
  fl_wrap_v head 100 "benchbar ${key}: " "  " "${summary}${note:+ ${note}}"
  printf '%s\n\n' "$head"
  fl_wrap_v head 100 "Usage: " "       " "$usage"
  printf '%s\n' "$head"
  [[ -z "$flags" ]] || printf '\nOptions:\n%s' "$flags"
  [[ -z "$envs" ]] || printf '\nEnvironment:\n%s' "$envs"
  printf '\nGlobal options: --bench-dir DIR, --site NAME, --json, --jsonl, --for-agent, --plain, -h.\n'
  printf 'Needs: a terminal to ask questions: %s; sudo: %s; the network: %s.\n' "$tty" "$sudo" "$net"
  printf 'Changes things: %s. JSON: %s.\n' "$mut" "$json"
  printf 'All commands: benchbar commands --json\n'
}

# fl_commands_json: benchbar commands --json. The commands of a lab that is
# off are left out and named in "gated"; one of a lab that is on has "lab".
# One pass over the records of this file, with builtins only (a subshell per
# value cost 1 s, a call of fl_json_str_v per value 0.25 s). A record whose
# fields have nothing to escape (all of them but a few) is quoted as it is; the
# others go through fl_json_str_v, so the bytes are the same as before.
# tests/test-commands-cost.sh holds the bytes and the cost.
fl_commands_json() {
  local LC_ALL=C
  local kind k a b c ctty csudo cnet cmut cjson on=0 out="" body="" fsep="" esep="" envs="" open=0 gflags="" gsep=""
  local word="" lab="" skip=0 gated="" gsep2="" lab_on=0 enabled="" labmap="" labs_on="" lsep="" n
  local jk ja jb jc jt js jn jm jj jl jw bh="" bs="" bm="" raws=""
  fl_lab_enabled_v enabled
  fl_lab_cmd_map_v labmap
  for n in $enabled; do fl_json_str_v jl "$n"; labs_on="${labs_on}${lsep}${jl}"; lsep=","; done
  while IFS='~' read -r kind k a b c; do
    if [[ "$on" != 1 ]]; then
      if [[ "$kind" == ": <<'TABLE'" ]]; then on=1; fi
      continue
    fi
    [[ "$kind" != TABLE ]] || break
    case "$kind" in
      cmd)
        if [[ "$open" == "1" ]]; then out="${out}${out:+,}${bh}${bs}${bm}${body}],\"env\":[${envs}]}"; fi
        open=0; skip=0
        if [[ "${k%% *}" != "$word" ]]; then
          word="${k%% *}"; lab=""; lab_on=0
          case "$labmap" in
            *" ${word}:"*)
              lab="${labmap#*" ${word}:"}"; lab="${lab%% *}"
              case " ${enabled} " in *" ${lab} "*) lab_on=1 ;; esac ;;
          esac
        fi
        if [[ -n "$lab" && "$lab_on" != "1" ]]; then
          skip=1
          fl_json_str_v jw "$word"
          case ",${gated}" in *"\"name\":${jw},"*) ;; *) fl_json_str_v jl "$lab"; gated="${gated}${gsep2}{\"name\":${jw},\"lab\":${jl}}"; gsep2="," ;; esac
          continue
        fi
        # the rest of the record: tty~sudo~network~mutating~json
        ctty="${c%%"~"*}"; c="${c#*"~"}"; csudo="${c%%"~"*}"; c="${c#*"~"}"; cnet="${c%%"~"*}"; c="${c#*"~"}"; cmut="${c%%"~"*}"; cjson="${c#*"~"}"
        case "${k}${a}${b}${cjson}" in
          *[\\\"]*|*[!\ -~]*) fl_json_str_v jk "$k"; fl_json_str_v ja "$a"; fl_json_str_v jb "$b"; fl_json_str_v jj "$cjson" ;;
          *)
            jk="\"${k}\""; ja="\"${a}\""; jb="\"${b}\""; jj="\"${cjson}\""
            [[ -n "$k" ]] || jk=null
            [[ -n "$a" ]] || ja=null
            [[ -n "$b" ]] || jb=null
            [[ -n "$cjson" ]] || jj=null ;;
        esac
        case "$ctty" in 1|yes|true) jt=true ;; *) jt=false ;; esac
        case "$csudo" in 1|yes|true) js=true ;; *) js=false ;; esac
        case "$cnet" in 1|yes|true) jn=true ;; *) jn=false ;; esac
        case "$cmut" in 1|yes|true) jm=true ;; *) jm=false ;; esac
        # the summary is held apart (bs): a note record after this one joins it before the record is written
        bh="{\"name\":${jk},\"usage\":${ja},\"summary\":"; bs="$jb"; raws="$b"
        bm=",\"tty\":${jt},\"sudo\":${js},\"network\":${jn},\"mutating\":${jm},\"json\":${jj},"
        if [[ -n "$lab" ]]; then fl_json_str_v jl "$lab"; bm="${bm}\"lab\":${jl},"; fi
        bm="${bm}\"flags\":["
        body=""
        envs=""; open=1; fsep=""; esep="" ;;
      note)
        [[ "$skip" != 1 ]] || continue
        # the summary, one space, the note: the whole text, as before it was split in two records
        case "${raws}${a}" in
          *[\\\"]*|*[!\ -~]*) fl_json_str_v bs "${raws}${raws:+ }${a}" ;;
          *) bs="\"${raws}${raws:+ }${a}\"" ;;
        esac ;;
      flag)
        [[ "$skip" != 1 ]] || continue
        case "${a}${b}${c}" in
          *[\\\"]*|*[!\ -~]*) fl_json_str_v ja "$a"; fl_json_str_v jb "$b"; fl_json_str_v jc "$c" ;;
          *)
            ja="\"${a}\""; jb="\"${b}\""; jc="\"${c}\""
            [[ -n "$a" ]] || ja=null
            [[ -n "$b" ]] || jb=null
            [[ -n "$c" ]] || jc=null ;;
        esac
        body="${body}${fsep}{\"name\":${ja},\"value\":${jb},\"help\":${jc}}"; fsep="," ;;
      env)
        [[ "$skip" != 1 ]] || continue
        case "${a}${b}" in
          *[\\\"]*|*[!\ -~]*) fl_json_str_v ja "$a"; fl_json_str_v jb "$b" ;;
          *)
            ja="\"${a}\""; jb="\"${b}\""
            [[ -n "$a" ]] || ja=null
            [[ -n "$b" ]] || jb=null ;;
        esac
        envs="${envs}${esep}{\"name\":${ja},\"help\":${jb}}"; esep="," ;;
    esac
  done <"$FL_CMD_FILE"
  [[ "$open" != "1" ]] || out="${out}${out:+,}${bh}${bs}${bm}${body}],\"env\":[${envs}]}"
  while IFS='~' read -r a b c; do
    fl_json_str_v ja "$a"; fl_json_str_v jb "$b"; fl_json_str_v jc "$c"
    gflags="${gflags}${gsep}{\"name\":${ja},\"value\":${jb},\"help\":${jc}}"; gsep=","
  done <<<"$FL_CMD_GLOBAL_FLAGS"
  printf '{"schema_version":%d,"cli_version":"%s","labs":[%s],"gated":[%s],"global_flags":[%s],"commands":[%s]}\n' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$labs_on" "$gated" "$gflags" "$out"
}

# fl_cmd_flag_check KEY ARG...: whether every option among ARG... (up to a
# bare --) is one of the flags the table lists for KEY. An option of a flag
# that takes a value skips the next word; --flag=VALUE and a short flag with
# its value glued on (-n20) are the same flag. Returns 1 with FL_BAD_FLAGS
# set to the unknown options, space separated. The options the main loop of
# the entrypoint takes (--bench-dir, --json ...) never reach it.
FL_BAD_FLAGS=""
fl_cmd_flag_check() {
  local key="$1" line rest name val tok skip=0 hit s
  local longs=" " valued=" " shorts=" "
  shift
  FL_BAD_FLAGS=""
  # most runs have no option among their arguments: no table read for those
  hit=0
  for tok in "$@"; do
    [[ "$tok" != -- ]] || break
    case "$tok" in -?*) hit=1; break ;; esac
  done
  [[ "$hit" == 1 ]] || return 0
  while IFS= read -r line; do
    case "$line" in
      "flag~${key}~"*)
        rest="${line#flag~"${key}"~}"; name="${rest%%~*}"; rest="${rest#*~}"; val="${rest%%~*}"
        case "$name" in
          --*) longs="${longs}${name} " ;;
          *) shorts="${shorts}${name} " ;;
        esac
        [[ -z "$val" ]] || valued="${valued}${name} " ;;
    esac
  done <<<"$FL_CMD_TABLE"
  for tok in "$@"; do
    [[ "$tok" != -- ]] || break
    if [[ "$skip" == 1 ]]; then skip=0; continue; fi
    case "$tok" in
      -|-h|--help) continue ;;
      --*) name="${tok%%=*}"
           case "$longs" in
             *" ${name} "*) [[ "$tok" == *=* ]] || case "$valued" in *" ${name} "*) skip=1 ;; esac ;;
             *) FL_BAD_FLAGS="${FL_BAD_FLAGS:+${FL_BAD_FLAGS} }${tok%%=*}" ;;
           esac ;;
      -?*) hit=0
           for s in $shorts; do
             case "$tok" in
               "$s") hit=1; case "$valued" in *" ${s} "*) skip=1 ;; esac ;;
               "$s"*) case "$valued" in *" ${s} "*) hit=1 ;; esac ;;
             esac
             [[ "$hit" == 0 ]] || break
           done
           [[ "$hit" == 1 ]] || FL_BAD_FLAGS="${FL_BAD_FLAGS:+${FL_BAD_FLAGS} }${tok}" ;;
    esac
  done
  [[ -z "$FL_BAD_FLAGS" ]]
}

# fl_usage_refuse ERROR_ID MESSAGE FIX [KEY]: a command line that cannot be read is a usage
# error: exit 64 (EX_USAGE), never 2 (the MariaDB root password is unknown: the Windows tray
# shows its password prompt for a 2 without a done line) and never 1 (the app's calls that
# accept [0,1] would parse an empty output). It runs before the stream, the log and the lock,
# so the JSON answer is built here, in the shape every other refusal has: a command that
# changes things (or --jsonl) ends in one `done` line, a command that reads in one document
# (schema_version, cli_version, exit, error_id, error, fix). Which one comes from the table
# entry of KEY; the options are read from the original command line because the main loop may
# not have reached them yet.
FL_USAGE_EXIT=64
# fl_cmd_usage_v VAR KEY: the usage line of the table entry KEY (empty when there is none)
fl_cmd_usage_v() {
  local __line __u=""
  while IFS= read -r __line; do
    case "$__line" in "cmd~${2}~"*) __u="${__line#cmd~"${2}"~}"; __u="${__u%%~*}"; break ;; esac
  done <<<"$FL_CMD_TABLE"
  printf -v "$1" '%s' "$__u"
}
fl_usage_refuse() { fl_refuse_json "$1" "$2" "$3" "${4:-}"; }
# fl_refuse_json ERROR_ID MESSAGE FIX [KEY]: the refusal in the shape --json, --jsonl and
# --for-agent want (above), always exit 64. A refusal of the whole run (benchbar as root)
# uses it too: a client that asked for JSON gets JSON, never a text line it cannot parse.
fl_refuse_json() {
  local id="$1" msg="$2" fix="$3" key="${4:-}" a want_json=0 want_jsonl=0 want_agent=0 kind="" mut="" f
  [[ "${OPT_JSON:-0}" != 1 ]] || want_json=1
  [[ "${OPT_JSONL:-0}" != 1 ]] || want_jsonl=1
  [[ "${OPT_FOR_AGENT:-0}" != 1 ]] || want_agent=1
  for a in ${FL_ORIG_ARGS[@]+"${FL_ORIG_ARGS[@]}"}; do
    case "$a" in
      --) break ;;
      --json) want_json=1 ;;
      --jsonl) want_json=1; want_jsonl=1 ;;
      --for-agent) want_agent=1 ;;
    esac
  done
  if [[ -n "$key" ]]; then
    fl_cmd_attr_v kind "$key" json
    fl_cmd_attr_v mut "$key" mutating
  fi
  # a command with no JSON of its own prints text, as it always did
  if [[ "$kind" == "none" ]]; then want_json=0; want_agent=0; fi
  if [[ "$want_agent" == 1 ]]; then
    want_json=1
    [[ "$mut" != "yes" ]] || want_jsonl=1
  fi
  if [[ "$want_json" == 1 ]]; then
    FL_ERROR_ID="$id"; FL_ERROR_FIX="$fix"
    FL_DONE_NO_BENCH=1; FL_DONE_NO_STATE=1
    fl_redact_url_v msg "$msg"
    printf '[FAIL] %s\n%s\n' "$msg" "$fix" >&2
    fl_done_fields_v f "$FL_USAGE_EXIT"
    if [[ "$want_jsonl" == 1 || "$kind" == "stream" ]]; then
      printf '{"schema_version":%d,"cli_version":"%s","event":"done",%s,"bench":null,"fix":%s,"log":"","error":%s}\n' \
        "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$f" "$(fl_json_str "$fix")" "$(fl_json_str "$msg")"
    else
      printf '{"schema_version":%d,"cli_version":"%s",%s,"fix":%s,"error":%s}\n' \
        "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$f" "$(fl_json_str "$fix")" "$(fl_json_str "$msg")"
    fi
    exit "$FL_USAGE_EXIT"
  fi
  fl_die "$msg" "$fix" "$FL_USAGE_EXIT"
}

# fl_args_validate: the dispatcher's check of the options after the command
# (ARGS, or the part before a bare --; FL_ARGS_FLAGS_N is its length).
# An unknown option is a usage error, exit 64 (error_id unknown_flag), naming the option and the command's
# usage line. BENCHBAR_LENIENT_FLAGS=1 turns the error into a warning on
# stderr, the way every release before 0.9.0 behaved.
fl_args_validate() {
  local key usage bad n="${FL_ARGS_FLAGS_N:--1}"
  [[ "${#ARGS[@]}" -gt 0 ]] || return 0
  key="$(fl_cmd_key_for "$COMMAND" "${ARGS[0]:-}")" || return 0
  if [[ "$n" -lt 0 || "$n" -gt "${#ARGS[@]}" ]]; then n="${#ARGS[@]}"; fi
  fl_cmd_flag_check "$key" "${ARGS[@]:0:$n}" && return 0
  fl_cmd_usage_v usage "$key"
  if [[ "${BENCHBAR_LENIENT_FLAGS:-0}" == "1" ]]; then
    for bad in $FL_BAD_FLAGS; do
      printf 'Ignoring unknown option for %s: %s (BENCHBAR_LENIENT_FLAGS=1; without it this is an error)\n' "$key" "$bad" >&2
    done
    return 0
  fi
  # the first one, as the other commands name it
  fl_usage_refuse unknown_flag "Unknown option for ${key}: ${FL_BAD_FLAGS%% *}" "Usage: ${usage}. Every flag: benchbar ${key} --help. A script that relied on unknown options being ignored: BENCHBAR_LENIENT_FLAGS=1 turns this error into a warning." "$key"
}

# ---------------------------------------------------------------- what the entry point asks the table
# Moved out of the entry point as it was (CORE-18, issue 151): what --json, --jsonl and --for-agent
# mean for a command, and the inputs a command needs when nobody can be asked (the preflight).
# Both read the command line state of the entry point (COMMAND, ARGS, OPT_*).

# fl_json_mode_resolve: what --json, --jsonl and --for-agent mean for this
# command, from its entry in commands.sh. Sets FL_JSON_KEY (its table key) and
# FL_JSON_MODE: stream (JSON lines ending in a done line, the stream starts
# before the lock), doc (one document; with --jsonl the stream wraps it) or
# "" (no JSON). install, adopt, repair and pull have streams of their own
# (FL_JSON_MODE own).
FL_JSON_KEY=""
FL_JSON_MODE=""
fl_json_mode_resolve() {
  local mut kind
  FL_JSON_KEY="$(fl_cmd_key_for "$COMMAND" "${ARGS[0]:-}")" || FL_JSON_KEY=""
  # a command or subcommand that does not exist ends the stream like any refusal: one done line
  if [[ -z "$FL_JSON_KEY" && ( "$OPT_FOR_AGENT" == "1" || "$OPT_JSONL" == "1" ) ]]; then
    export BENCHBAR_NONINTERACTIVE=1 NO_COLOR=1
    FL_PLAIN=1; fl_ui_init
    OPT_JSON=1; OPT_JSONL=1; FL_JSON_MODE=stream
    return 0
  fi
  if [[ "$OPT_FOR_AGENT" == "1" ]]; then
    export BENCHBAR_NONINTERACTIVE=1 NO_COLOR=1
    FL_PLAIN=1; fl_ui_init
    fl_cmd_attr_v kind "$FL_JSON_KEY" json
    if [[ -n "$kind" && "$kind" != "none" ]]; then
      OPT_JSON=1
      fl_cmd_attr_v mut "$FL_JSON_KEY" mutating
      [[ "$mut" != "yes" ]] || OPT_JSONL=1
    fi
  fi
  [[ "$OPT_JSON" == "1" ]] || return 0
  case "$COMMAND" in
    install|adopt|repair|pull) FL_JSON_MODE=own; return 0 ;;
  esac
  case "$FL_JSON_KEY" in
    up|down|restart|service|"site default"|"ports apply") FL_JSON_MODE=stream ;;
    # a dry run of these is their plan, one document with its token
    "app update"|"app install"|"lock apply"|"site add") if [[ "$FL_DRY_RUN" == "1" ]]; then FL_JSON_MODE=doc; else FL_JSON_MODE=stream; fi ;;
    "site backup"|"site drop"|"site restore"|"site move"|"site snapshot"|"site snapshot drop"|"site snapshots"|"site rollback"|"app add"|"run"|"bench forget"|"bench remove"|"bench scratch"|"bench gc"|"db orphans") FL_JSON_MODE=doc ;;
    # on and off stream like site default; status only reads
    "site open-as") if [[ "${ARGS[1]:-}" == "status" ]]; then FL_JSON_MODE=doc; else FL_JSON_MODE=stream; fi ;;
    "share setup"|"share start"|"share stop"|"share extend"|"share lock"|"share unlock"|"share remove"|"share revoke"|"share assign"|"share teardown"|"share leave"|"share forget") FL_JSON_MODE=stream ;;
    "share users"|"share preflight"|"share status"|"share code"|"share invite"|"share people"|"share devices"|"share log"|"share open-as"|"share joined") FL_JSON_MODE=doc ;;
    # one document, like share code: a stream closes stdin, and the app and the tray send the room code there
    "share join") FL_JSON_MODE=doc ;;
    "lan-guard"|"lan-guard install"|"lan-guard remove"|"lan-guard allow-node") FL_JSON_MODE=stream ;;
    "lan-guard status"|wait) FL_JSON_MODE=doc ;;
    "labs on"|"labs off") FL_JSON_MODE=stream ;;
    "lease take"|"lease release"|"lease renew") FL_JSON_MODE=stream ;;
    # the commands that changed things and had no JSON before: a stream, as site default
    autostart|listen|uninstall-service|"lock write"|"profile create"|"ports setup"|"ports mode"|"site hosts") FL_JSON_MODE=stream ;;
    # these print a document of their own under --json, and keep it
    register|"app unfocus"|"profile export"|"profile import"|"profile subscribe"|"profile update"|"profile remove"|self-update) FL_JSON_MODE=doc ;;
  esac
}

# fl_site_arg_name: the NAME of "site add|drop NAME ..." (the first word that is
# not an option or an option's value)
fl_site_arg_name() {
  local skip=0 i=0 a
  for a in ${ARGS[@]+"${ARGS[@]}"}; do
    i=$((i + 1)); [[ "$i" -gt 1 ]] || continue
    if [[ "$skip" == "1" ]]; then skip=0; continue; fi
    case "$a" in
      --apps|--bundle|--confirm-site|--new-default|--from|--from-site|--before-migrate|--apply|--to|--to-bench|--label|--keep) skip=1 ;;
      -*) ;;
      *) printf '%s' "$a"; return 0 ;;
    esac
  done
}

# fl_need_mariadb_password: MARIADB_ROOT_PASSWORD, only when neither the
# environment nor benchbar's own store knows one (fl_keychain_get)
fl_need_mariadb_password() {
  [[ -z "${MARIADB_ROOT_PASSWORD:+x}" ]] || return 0
  [[ -z "$(fl_keychain_get 2>/dev/null || true)" ]] || return 0
  fl_need MARIADB_ROOT_PASSWORD "the MariaDB root password: no working one is known to benchbar"
}

# fl_noninteractive_preflight: every input a command needs, checked before
# the lock, the log or any bench call, all named in one error (fl_need_check).
# uninstall-service without a terminal and without --yes is refused in any
# mode: it used to read the missing terminal as "no" and end without a word.
fl_noninteractive_preflight() {
  local name sudo_why=""
  [[ "$FL_DRY_RUN" != "1" ]] || return 0
  if [[ "$COMMAND" == "uninstall-service" && "$FL_ASSUME_YES" != "1" ]] && ! [[ " ${ARGS[*]:-} " == *" --all "* && -n "$OPT_BENCH_DIR" ]]; then
    if fl_noninteractive; then fl_need "--yes" "to confirm removing the background service"
    elif [[ ! -t 0 ]]; then fl_need "--yes" "to confirm removing the background service; there is no terminal to ask in"; fi
    fl_need_check always
    return 0
  fi
  fl_noninteractive || return 0
  case "$COMMAND ${ARGS[0]:-}" in
    "install "*)
      fl_context_init "$OPT_BENCH_DIR" "$OPT_SITE" "$OPT_PROFILE"
      if [[ -n "$FL_TEAM_PROFILE" && -n "$FL_TEAM_SITE" && "$FL_SITE_SOURCE" == "default" ]]; then FL_SITE="$FL_TEAM_SITE"; fi
      [[ "$FL_ASSUME_YES" == "1" ]] || fl_need "--yes" "to confirm the install plan"
      [[ -d "${FL_BENCH_DIR}/sites/${FL_SITE}" || -n "${ADMIN_PASSWORD:+x}" ]] || fl_need ADMIN_PASSWORD "the Administrator password of the new site ${FL_SITE}"
      # json runs skip a root step that would ask; a plain run would wait for the password.
      # BENCHBAR_SUDO=env has the password (checked up front, fl_sudo_env_preflight) or it is named
      if fl_sudo_env_has_password; then
        :
      elif fl_sudo_env; then
        sudo_why="$(fl_install_sudo_reasons)"
        if [[ -n "$sudo_why" ]] && ! { command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; }; then
          fl_need BENCHBAR_SUDO_PASSWORD "BENCHBAR_SUDO=env needs the sudo password for: ${sudo_why//$'\n'/; }"
        fi
      elif [[ "$OPT_JSON" != "1" ]] && ! fl_sudo_gui; then
        sudo_why="$(fl_install_sudo_reasons)"
        if [[ -n "$sudo_why" ]] && ! { command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; }; then
          fl_need "sudo" "it would ask for a password: ${sudo_why//$'\n'/; }; cache the credential first, or pass --json to skip those steps"
        fi
      fi ;;
    "adopt "*) [[ "$FL_ASSUME_YES" == "1" ]] || fl_need "--yes" "to confirm the adopt plan" ;;
    "site add")
      name="$(fl_site_arg_name)"
      fl_site_name_ok "$name" || return 0
      fl_context_init "$OPT_BENCH_DIR" "$OPT_SITE" "$OPT_PROFILE"
      fl_is_bench_dir "$FL_BENCH_DIR" || return 0
      if [[ ! -d "${FL_BENCH_DIR}/sites/${name}" ]]; then
        [[ -n "${ADMIN_PASSWORD:+x}" ]] || fl_need ADMIN_PASSWORD "the Administrator password of the new site ${name}"
        fl_need_mariadb_password
      fi
      # the hosts line asks once and needs sudo (a Mac; Linux never edits /etc/hosts)
      if ! fl_is_linux && ! fl_hosts_has_name "$name"; then
        [[ "$FL_ASSUME_YES" == "1" ]] || fl_need "--yes" "to add ${name} to ${FL_HOSTS_FILE} with sudo"
        if [[ "$OPT_JSON" != "1" ]] && ! fl_sudo_gui && ! { command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; }; then
          fl_need "sudo" "the ${FL_HOSTS_FILE} line would ask for a password; cache the credential first, or pass --json to skip it"
        fi
      fi ;;
    "site open-as"*)
      # password-less sign in is turned on by a person: refused before the lock, whatever else is given
      [[ "${ARGS[1]:-}" != "on" ]] || fl_need "a person at a terminal" "turning on Open as is a person's decision; run benchbar site open-as on NAME in a terminal"
      ;;
    "bench remove"|"bench gc")
      # deleting a bench's databases and moving its folder is a person's decision: its plan (--dry-run) is open to agents
      fl_need "a person at a terminal" "removing a bench is a person's decision; read the plan with --dry-run --json, then run benchbar bench ${ARGS[0]} in a terminal" ;;
    "db orphans") fl_need_mariadb_password ;;
    "share setup")
      # the copy holds real data and others sign in to it: a person's decision, refused before the lock
      fl_need "a person at a terminal" "sharing a site is a person's decision; run benchbar share setup in a terminal"
      ;;
    "share start")
      fl_need "a person at a terminal" "sharing on the network is a person's decision; run benchbar share start in a terminal"
      ;;
    "share join"|"share leave"|"share forget")
      # a room is somebody's site with real data, and the code is typed by the person it was given to
      fl_need "a person at a terminal" "joining and leaving a room is a person's decision; run benchbar share ${ARGS[0]} in a terminal"
      ;;
    "lan-guard install"|"lan-guard remove"|"lan-guard allow-node")
      # sudo for the pf anchor or the firewall: a person's decision, refused before anything is asked (U3)
      fl_need "a person at a terminal" "benchbar lan-guard ${ARGS[0]} runs sudo; run it in a terminal"
      ;;
    "site snapshot")
      # removing a snapshot is a person's decision: its plan (--dry-run) is open to agents
      [[ "${ARGS[1]:-}" != "drop" ]] || fl_need "a person at a terminal" "removing a snapshot is a person's decision; read what would go with --dry-run, then run benchbar site snapshot drop in a terminal" ;;
    "site restore"|"site rollback"|"site move")
      # the restore needs the root password (to create or replace the database) and a yes
      [[ "$FL_ASSUME_YES" == "1" ]] || fl_need "--yes" "to confirm the restore plan (or --apply TOKEN --yes)"
      name="$(fl_site_arg_name)"
      fl_site_name_ok "$name" || return 0
      fl_context_init "$OPT_BENCH_DIR" "$OPT_SITE" "$OPT_PROFILE"
      fl_is_bench_dir "$FL_BENCH_DIR" || return 0
      fl_need_mariadb_password ;;
    "pull "*)
      # a --json pull answers its own gates; the root password is the only input it cannot guess
      [[ "$FL_ASSUME_YES" == "1" || "$OPT_JSON" == "1" ]] || fl_need "--yes" "to confirm the pull plan"
      fl_context_init "$OPT_BENCH_DIR" "$OPT_SITE" "$OPT_PROFILE"
      fl_is_bench_dir "$FL_BENCH_DIR" || return 0
      fl_need_mariadb_password ;;
    "site drop")
      name="$(fl_site_arg_name)"
      fl_site_name_ok "$name" || return 0
      fl_context_init "$OPT_BENCH_DIR" "$OPT_SITE" "$OPT_PROFILE"
      fl_is_bench_dir "$FL_BENCH_DIR" && [[ -d "${FL_BENCH_DIR}/sites/${name}" ]] || return 0
      fl_need_mariadb_password ;;
  esac
  fl_need_check
}

# ---------------------------------------------------------------- the global help
# `benchbar --help`, `benchbar help` and `benchbar` alone print the `use` records of usage.sh,
# which is read here, when the help prints, and not at every start (CORE-18, issue 151).
usage() {
  # shellcheck source=lib/frappe-local/usage.sh
  . "${SCRIPT_DIR}/lib/frappe-local/usage.sh"
  fl_usage_text | fl_lab_usage_filter
}

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

# The table is read into a variable with the read builtin: status and list
# are polled and start no process, and `cat` is one.
read -r -d '' FL_CMD_TABLE <<'TABLE' || true
cmd~install~benchbar install [--profile NAME] [--bundle NAME] [--dry-run] [--yes] [--json]~Phase 00 (system dependencies), 01 (bench and site) and the background service, idempotent.~yes~yes~yes~yes~stream
flag~install~--profile~NAME~Release profile (default v15-lts) or a team profile.
flag~install~--bundle~NAME~App bundle: minimal, common or extended.
flag~install~--port-offset~N~Use port block N (web 8000+N).
flag~install~--make-default~~Make this the default bench even when another one is.
flag~install~--offline~~Skip the remote branch checks.
flag~install~--dry-run~~Print the plan, change nothing.
flag~install~--yes~~Do not ask; secrets come from the environment.
env~install~ADMIN_PASSWORD~The new site's Administrator password.
env~install~MARIADB_ROOT_PASSWORD~Only when MariaDB has a password benchbar does not know.
cmd~adopt~benchbar adopt PATH [--dry-run] [--yes] [--json]~Register an existing bench: Procfile.lean, runner, agent, helpers. Never runs migrate, build or update.~yes~yes~no~yes~stream
flag~adopt~--port-offset~N~Move the bench to port block N.
flag~adopt~--make-default~~Make this the default bench.
flag~adopt~--dry-run~~Print the plan, change nothing.
flag~adopt~--yes~~Do not ask.
cmd~service~benchbar service [--with-schedule|--without-schedule] [--port-offset N] [--dry-run] [--json]~Install or refresh only the background service (phase 02).~yes~no~no~yes~stream
flag~service~--with-schedule~~Add the scheduler to Procfile.lean.
flag~service~--without-schedule~~Remove it again.
flag~service~--port-offset~N~Use port block N.
flag~service~--dry-run~~Print the plan, change nothing.
cmd~mariadb-password~benchbar mariadb-password [--yes]~Print the MariaDB root password (asks first).~yes~no~no~no~none
flag~mariadb-password~--yes~~Do not ask.
cmd~doctor~benchbar doctor [--json] [--fix-hints] [--quick] [--ack CHECK] [--unack CHECK] [--prerequisites] [--fetch]~Read only health report. Exit 1 when something FAILs.~no~no~no~no~document
flag~doctor~--json~~One JSON document.
flag~doctor~--fix-hints~~Only the fix commands, one per line.
flag~doctor~--quick~~Skip the slow checks and say which.
flag~doctor~--ack~CHECK~Silence one named WARN for this bench until its message changes.
flag~doctor~--unack~CHECK~Undo --ack.
flag~doctor~--prerequisites~~What this Mac needs before an install, no bench needed.
flag~doctor~--fetch~~git fetch the branches of the apps your focus apps need first.
cmd~repair~benchbar repair [--dry-run] [--yes] [--json]~Apply only the fixes doctor flagged, in dependency order.~yes~yes~yes~yes~stream
flag~repair~--dry-run~~Print the plan, change nothing.
flag~repair~--yes~~Do not ask.
cmd~status~benchbar status [--json] [--ping]~State, pid, stop reason, site ping.~no~no~no~no~document
flag~status~--ping~~Ask every site, not only the default one.
cmd~list~benchbar list [--json]~Every bench benchbar knows about. Never pings a site.~no~no~no~no~document
cmd~scan~benchbar scan PATH [--json]~Find benches recursively in a folder (read only).~no~no~no~no~document
cmd~register~benchbar register PATH...~Remember selected benches without changing their services.~no~no~no~yes~none
cmd~up~benchbar up [--json]~Start the bench in the background.~yes~no~no~yes~stream
cmd~down~benchbar down [--json]~Stop the bench and keep it stopped across reboots.~no~no~no~yes~stream
cmd~restart~benchbar restart [--json]~Restart the bench, for example after changing Python code.~yes~no~no~yes~stream
cmd~logs~benchbar logs [-nN] [--worker|--worker-error|--previous] [--process NAME] [--since TIMESTAMP] [--since-restart] [--no-follow] [--json]~Tail logs/bench.log.~no~no~no~no~document
flag~logs~--worker~~Read logs/worker.log.
flag~logs~--worker-error~~Read logs/worker.error.log.
flag~logs~--previous~~Read logs/bench.previous.log.
flag~logs~--process~NAME~web, socketio, schedule or worker.
flag~logs~--since~TIMESTAMP~Only lines at or after it (--json; ISO 8601, or HH:MM:SS today).
flag~logs~--since-restart~~Only lines after the bench's last start (--json).
flag~logs~--no-follow~~Print and exit.
cmd~fg~benchbar fg~Stop the service and run honcho in the foreground.~yes~no~no~yes~none
cmd~watch~benchbar watch~Run bench watch for asset rebuilds.~no~no~no~no~none
cmd~autostart~benchbar autostart [on|off]~Whether the bench may come back after login.~no~no~no~yes~none
cmd~uninstall-service~benchbar uninstall-service [--all] [--yes] [--dry-run]~Remove the agent, runner, Procfile.lean and shell helpers.~yes~no~no~yes~none
flag~uninstall-service~--all~~Every bench with a benchbar agent, after one question.
flag~uninstall-service~--yes~~Do not ask; required without a terminal.
cmd~path~benchbar path~Print the bench directory.~no~no~no~no~none
cmd~console~benchbar console [--site S]~bench --site SITE console: a Python shell with frappe.~yes~no~no~no~none
cmd~db~benchbar db [--site S]~bench --site SITE mariadb: the site's database.~yes~no~no~no~none
cmd~pull~benchbar pull HOST:SITE [--as NAME] [--from-dir DIR] [--replace] [--json]~Copy a production site over SSH into a new local site.~yes~no~yes~yes~stream
flag~pull~--as~NAME~Local site name (default SITE.local).
flag~pull~--from-dir~DIR~A backup set downloaded by hand, no SSH.
flag~pull~--remote-bench~DIR~The bench folder on the server.
flag~pull~--new-backup~~Run bench backup on the server first.
flag~pull~--replace~~Restore over an existing local site, after backing it up.
env~pull~MARIADB_ROOT_PASSWORD~Only when MariaDB has a password benchbar does not know.
cmd~report~benchbar report [--print] [--json]~Redacted diagnostics zip on the Desktop for bug reports.~no~no~no~no~document
flag~report~--print~~Print to the terminal instead of writing the zip.
cmd~docs~benchbar docs [TOPIC] [--print]~Open the documentation, or one topic's page.~no~no~no~no~none
cmd~self-update~benchbar self-update [--check] [--dry-run] [--json]~Update the benchbar CLI and the BenchBar app.~yes~no~yes~yes~document
flag~self-update~--check~~This version against the latest.
cmd~where~benchbar where [--json]~How this CLI was installed, its state folder and the app.~no~no~no~no~document
cmd~mcp~benchbar mcp~Model Context Protocol server on stdio for coding agents.~no~no~no~no~none
cmd~help~benchbar help~The global help text.~no~no~no~no~none
cmd~commands~benchbar commands --json~This table: every command, flag and environment variable.~no~no~no~no~document
cmd~ports~benchbar ports plan|setup|apply|check|mode ...~Port allocation for several benches.~no~no~no~no~none
cmd~ports plan~benchbar ports plan [--json] -- PATH ...~Read only preview of the allocation and its approval token.~no~no~no~no~document
cmd~ports setup~benchbar ports setup [--dry-run] -- PATH ...~Preview, confirm once, then apply.~yes~yes~no~yes~none
cmd~ports apply~benchbar ports apply TOKEN --yes [--json] -- PATH ...~Apply a reviewed plan; refuses a stale token.~no~yes~no~yes~stream
flag~ports apply~--yes~~Required: the plan was reviewed.
cmd~ports check~benchbar ports check [--json]~Port conflicts of the bench.~no~no~no~no~document
cmd~ports mode~benchbar ports mode automatic|fixed~Keep automatic or fixed ports for the bench.~no~no~no~yes~none
cmd~site~benchbar site list|add|default|hosts|backup|backups|drop ...~The sites of a bench.~no~no~no~no~none
cmd~site list~benchbar site list [--json]~The bench's sites; the default one is what benchup waits for.~no~no~no~no~document
cmd~site add~benchbar site add NAME [--bundle NAME|--apps "a b"] [--yes] [--json]~bench new-site, the hosts line and apps from apps/. The default site stays.~yes~yes~no~yes~stream
flag~site add~--bundle~NAME~App bundle to install.
flag~site add~--apps~"a b"~Apps of apps/ to install.
flag~site add~--yes~~Do not ask.
env~site add~ADMIN_PASSWORD~The new site's Administrator password.
env~site add~MARIADB_ROOT_PASSWORD~Only when MariaDB has a password benchbar does not know.
cmd~site default~benchbar site default NAME [--json]~Make NAME the default site.~no~no~no~yes~stream
cmd~site hosts~benchbar site hosts~Add a 127.0.0.1 line for every site to /etc/hosts.~yes~yes~no~yes~none
cmd~site backup~benchbar site backup NAME [--with-files] [--json]~bench --site NAME backup.~no~no~no~yes~document
flag~site backup~--with-files~~Include the uploads.
cmd~site backups~benchbar site backups NAME [--json]~The site's backups, newest first.~no~no~no~no~document
cmd~site drop~benchbar site drop NAME --confirm-site NAME [--new-default OTHER] [--dry-run] [--json]~bench drop-site: a backup with files first, the folder moved to archived/sites.~no~yes~no~yes~document
flag~site drop~--confirm-site~NAME~Repeat the site name exactly.
flag~site drop~--new-default~OTHER~Required when NAME is the default site.
flag~site drop~--dry-run~~Print the plan, change nothing.
env~site drop~MARIADB_ROOT_PASSWORD~Only when MariaDB has a password benchbar does not know.
cmd~app~benchbar app list|add|install|update|focus|unfocus ...~The apps of a bench.~no~no~no~no~none
cmd~app list~benchbar app list [--json] [--no-sites]~Every app: branch, commit, local changes, the sites that have it.~no~no~no~no~document
cmd~app add~benchbar app add NAME|URL [--branch B] [--site S|--all-sites] --dry-run --json, then --apply TOKEN --yes~bench get-app from config/apps.tsv or any git URL, as a reviewed plan.~no~no~yes~yes~document
flag~app add~--branch~B~Branch or tag.
flag~app add~--name~N~The app's package name.
flag~app add~--site~S~Install it on this site.
flag~app add~--all-sites~~Install it on every site.
flag~app add~--dry-run~~Print the plan and its token.
flag~app add~--apply~TOKEN~Run exactly that plan (with --yes).
cmd~app install~benchbar app install NAME --site S~Install an app of the bench on a site.~no~no~no~yes~none
cmd~app update~benchbar app update NAME [--skip-backup] [--dry-run] [--json]~Fast forward one app with a changelog first, back up its sites, migrate, build.~yes~no~yes~yes~stream
flag~app update~--skip-backup~~Migrate without a backup first.
flag~app update~--dry-run~~Print the plan as one JSON document with --json.
cmd~app focus~benchbar app focus [NAME] [--list] [--auto] [--fetch] [--json]~Focus apps: the ones you work on.~no~no~no~no~document
cmd~app unfocus~benchbar app unfocus NAME~Pin NAME as not a focus app.~no~no~no~yes~none
cmd~lock~benchbar lock write|check|apply ...~The team lockfile benchbar.toml.~no~no~no~no~none
cmd~lock write~benchbar lock write [--lock PATH] [--no-commits] [--allow-dirty]~Write benchbar.toml from this bench.~yes~no~no~yes~none
cmd~lock check~benchbar lock check [--json]~Compare the bench with benchbar.toml. Exit 1 on any difference.~no~no~no~no~document
cmd~lock apply~benchbar lock apply~Clone missing apps, switch branches, fast forward to pinned commits.~yes~no~yes~yes~none
cmd~profile~benchbar profile list|show|create|export|import|subscribe|update|remove|check ...~Team profiles.~no~no~no~no~none
cmd~profile list~benchbar profile list [--json]~Built in and team profiles.~no~no~no~no~document
cmd~profile show~benchbar profile show NAME~What a profile installs.~no~no~no~no~none
cmd~profile create~benchbar profile create NAME --from-bench PATH [--dir DIR]~Write a team profile from a bench.~no~no~no~yes~none
cmd~profile export~benchbar profile export NAME [--out FILE] [--plan] [--json]~A copy to share.~no~no~yes~yes~document
cmd~profile import~benchbar profile import FILE|URL [--as NAME] [--plan] [--json]~Add a profile someone sent.~yes~no~yes~yes~document
cmd~profile subscribe~benchbar profile subscribe GIT_URL [--plan|--yes] [--json]~Clone a team's config repo.~yes~no~yes~yes~document
cmd~profile update~benchbar profile update NAME|--all [--plan] [--json]~Fetch an import or subscription again.~yes~no~yes~yes~document
cmd~profile remove~benchbar profile remove NAME [--yes] [--json]~Move an import or subscription aside.~yes~no~no~yes~document
cmd~profile check~benchbar profile check NAME [--json]~Can git read every repo with your credentials?~no~no~yes~no~document
TABLE

fl_cmd_table() { printf '%s\n' "$FL_CMD_TABLE"; }

# Options every command takes, for the help text and `commands --json`.
fl_cmd_global_flags() {
  cat <<'FLAGS'
--bench-dir~DIR~Bench to act on (default: remembered, or auto-detected).
--site~NAME~Site name (default: remembered, or from the bench).
--json~~JSON: one document for a command that reads, JSON lines for one that changes things.
--jsonl~~JSON lines (plan, step, progress, done) for any command that changes things.
--for-agent~~--jsonl for a command that changes things, --json for one that reads, plus BENCHBAR_NONINTERACTIVE=1, NO_COLOR=1 and --plain.
--plain~~No colors or spinners.
-h, --help~~Help for the command.
FLAGS
}

# fl_cmd_key_for COMMAND ARG: the table key: "COMMAND ARG" when the table has
# that subcommand, else COMMAND; fails when the table knows neither
fl_cmd_key_for() {
  local cmd="$1" arg="${2:-}" line
  if [[ -n "$arg" && "$arg" != -* ]]; then
    while IFS= read -r line; do
      [[ "$line" == "cmd~${cmd} ${arg}~"* ]] && { printf '%s' "${cmd} ${arg}"; return 0; }
    done < <(fl_cmd_table)
  fi
  while IFS= read -r line; do
    [[ "$line" == "cmd~${cmd}~"* ]] && { printf '%s' "$cmd"; return 0; }
  done < <(fl_cmd_table)
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
  done < <(fl_cmd_table)
  printf -v "$1" '%s' "$__r"
}

# fl_cmd_help KEY: the table's entry as text
fl_cmd_help() {
  local key="$1" line kind k a b c flags="" envs="" summary="" usage="" tty sudo net mut json
  while IFS= read -r line; do
    IFS='~' read -r kind k a b c <<<"$line"
    [[ "$k" == "$key" ]] || continue
    case "$kind" in
      cmd) usage="$a"; summary="$b"; IFS='~' read -r _ _ _ _ tty sudo net mut json <<<"$line" ;;
      flag) flags="${flags}  $(printf '%-22s' "${a}${b:+ ${b}}") ${c}"$'\n' ;;
      env) envs="${envs}  $(printf '%-22s' "$a") ${b}"$'\n' ;;
    esac
  done < <(fl_cmd_table)
  printf 'benchbar %s: %s\n\nUsage: %s\n' "$key" "$summary" "$usage"
  [[ -z "$flags" ]] || printf '\nOptions:\n%s' "$flags"
  [[ -z "$envs" ]] || printf '\nEnvironment:\n%s' "$envs"
  printf '\nGlobal options: --bench-dir DIR, --site NAME, --json, --jsonl, --for-agent, --plain, -h.\n'
  printf 'Needs: a terminal to ask questions: %s; sudo: %s; the network: %s.\n' "$tty" "$sudo" "$net"
  printf 'Changes things: %s. JSON: %s.\n' "$mut" "$json"
  printf 'All commands: benchbar commands --json\n'
}

# fl_commands_json: benchbar commands --json
fl_commands_json() {
  local line kind k a b c out="" body="" fsep="" esep="" envs="" open=0 gflags="" gsep="" tty sudo net mut json
  while IFS= read -r line; do
    IFS='~' read -r kind k a b c <<<"$line"
    case "$kind" in
      cmd)
        if [[ "$open" == "1" ]]; then out="${out}${out:+,}${body}],\"env\":[${envs}]}"; fi
        IFS='~' read -r _ _ _ _ tty sudo net mut json <<<"$line"
        body="{\"name\":$(fl_json_str "$k"),\"usage\":$(fl_json_str "$a"),\"summary\":$(fl_json_str "$b"),\"tty\":$(fl_json_bool "$tty"),\"sudo\":$(fl_json_bool "$sudo"),\"network\":$(fl_json_bool "$net"),\"mutating\":$(fl_json_bool "$mut"),\"json\":$(fl_json_str "$json"),\"flags\":["
        envs=""; open=1; fsep=""; esep="" ;;
      flag)
        body="${body}${fsep}{\"name\":$(fl_json_str "$a"),\"value\":$(fl_json_str "$b"),\"help\":$(fl_json_str "$c")}"; fsep="," ;;
      env)
        envs="${envs}${esep}{\"name\":$(fl_json_str "$a"),\"help\":$(fl_json_str "$b")}"; esep="," ;;
    esac
  done < <(fl_cmd_table)
  [[ "$open" != "1" ]] || out="${out}${out:+,}${body}],\"env\":[${envs}]}"
  while IFS='~' read -r a b c; do
    gflags="${gflags}${gsep}{\"name\":$(fl_json_str "$a"),\"value\":$(fl_json_str "$b"),\"help\":$(fl_json_str "$c")}"; gsep=","
  done < <(fl_cmd_global_flags)
  printf '{"schema_version":%d,"cli_version":"%s","global_flags":[%s],"commands":[%s]}\n' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$gflags" "$out"
}

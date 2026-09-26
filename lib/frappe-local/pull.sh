#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# pull.sh: benchbar pull, a production site into a new local site.
#
#   benchbar pull HOST:SITE [--as NAME]      over SSH (HOST from ~/.ssh/config)
#   benchbar pull --from-dir DIR --as NAME   a backup downloaded by hand
#
# Check (read only, local and remote), plan, gates, apply, verify:
#   - the latest existing backup on the server is used; --new-backup takes a
#     fresh one after the production site name is typed (bench backup also
#     deletes older backups there)
#   - the download resumes (rsync --partial), encrypted backups are decrypted
#     here with gpg, the passphrase on stdin
#   - restore goes into a new local site only (--replace backs the old up)
#   - the site's encryption_key comes over on stdin, never on a command line,
#     in the output or in the log; the rest of the production config stays
#   - apps the bench lacks stop the run with the bench get-app commands,
#     unless --skip-app names them
#   - email is muted and the scheduler paused before the copy ever starts
#
# The MariaDB root password and the Administrator password reach frappe
# through a small Python wrapper that reads them on stdin and calls frappe's
# own command line in process, so they never show in the process list.

FL_PULL_ACTIVE=0
FL_PULL_DONE_SENT=0
FL_PULL_SSH_DIR=""
FL_PULL_SSH_OPTS=()
FL_PULL_HOST=""
FL_PULL_RSITE=""
FL_PULL_RBENCH=""
FL_PULL_FROM_DIR=""
FL_PULL_AS=""
FL_PULL_REPLACE=0
FL_PULL_NEW_BACKUP=0
FL_PULL_CONFIRM_SITE=""
FL_PULL_SKIP_APPS=""
FL_PULL_NO_FILES=0
FL_PULL_KEEP_SCHEDULER=0
FL_PULL_KEEP_STAGING=0
FL_PULL_STAGING=""
# the backup set: file names (remote) and their sizes
FL_PULL_DB=""; FL_PULL_PUB=""; FL_PULL_PRIV=""; FL_PULL_CONF=""
FL_PULL_DB_BYTES=0; FL_PULL_PUB_BYTES=0; FL_PULL_PRIV_BYTES=0; FL_PULL_TOTAL_BYTES=0
FL_PULL_ENCRYPTED=0
FL_PULL_HAS_KEY=0
FL_PULL_HAS_BACKUP_KEY=0
FL_PULL_REMOTE_RSYNC=0
# "app|version|branch|origin" per production app, one per line
FL_PULL_R_APPS=""
FL_PULL_APPS_KNOWN=0
FL_PULL_MISSING=""
FL_PULL_NEED_MIGRATE=1
FL_PULL_SITE_EXISTS=0
FL_PULL_PROBE_OK=""
FL_PULL_PROBE_BAD=""
FL_PULL_WARNINGS=""
FL_PULL_APPS_JSON=""
FL_PULL_ADMIN_PW=""
FL_PULL_STEPS=()

# Python snippets (they contain no single quotes, so they travel over SSH as
# one quoted word). None of them takes a secret as an argument.

# conf PATH value KEY  -> the value, on stdout only (always piped onwards)
# conf PATH has KEY... -> "KEY=yes|no ..." (a value that is empty or 0 is no)
FL_PULL_PY_CONF='import json, sys
path, mode = sys.argv[1], sys.argv[2]
try:
    conf = json.load(open(path))
except Exception:
    conf = {}
if mode == "value":
    sys.stdout.write(str(conf.get(sys.argv[3]) or ""))
else:
    print(" ".join("%s=%s" % (k, "yes" if conf.get(k) else "no") for k in sys.argv[3:]))'

# setkey PATH, the key on stdin: writes encryption_key the way frappe does
# (indent 1, sorted keys), through a temp file and a rename
FL_PULL_PY_SETKEY='import json, os, sys, tempfile
path = sys.argv[1]
key = sys.stdin.read().strip()
if not key:
    sys.exit(3)
conf = json.load(open(path))
if conf.get("encryption_key") == key:
    print("unchanged")
    sys.exit(0)
conf["encryption_key"] = key
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".site_config.")
with os.fdopen(fd, "w") as f:
    json.dump(conf, f, indent=1, sort_keys=True)
    f.write("\n")
os.chmod(tmp, os.stat(path).st_mode & 0o777)
os.replace(tmp, path)
print("written")'

# benchbar-frappe SITE CMD OPT ARGS..., the secret on stdin: runs
# "bench --site SITE CMD ARGS... OPT SECRET" (OPT "-": the secret is a
# positional argument) inside this process, from sites/
FL_PULL_PY_FRAPPE='import sys
secret = sys.stdin.readline().rstrip("\n")
site, cmd, opt = sys.argv[2], sys.argv[3], sys.argv[4]
args = ["frappe", "--site", site, cmd] + sys.argv[5:]
args += [secret] if opt == "-" else [opt, secret]
sys.argv = ["bench_helper"] + args
from frappe.utils.bench_helper import main
main()'

# benchbar-probe SITE: how many encrypted __Auth rows decrypt with the
# site key, and how many fail. Only the counts are printed.
# shellcheck disable=SC2016  # backticks are SQL quoting, for python
FL_PULL_PY_PROBE='import sys
import frappe
from frappe.utils.password import decrypt
frappe.init(site=sys.argv[2], sites_path=".")
frappe.connect()
ok = bad = 0
for row in frappe.db.sql("select `password` from `__Auth` where `encrypted` = 1"):
    try:
        decrypt(row[0])
        ok += 1
    except Exception:
        bad += 1
frappe.destroy()
print("benchbar-probe %d %d" % (ok, bad))'

# ---------------------------------------------------------------- helpers

# fl_pull_emit EVENT [,"field":value...]: one JSON line on the saved stdout (fd 3)
fl_pull_emit() {
  [[ "${OPT_JSON:-0}" == "1" ]] || return 0
  printf '{"schema_version":%d,"cli_version":"%s","event":"%s"%s}\n' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$1" "${2:-}" >&3
}

fl_pull_warn() {
  fl_warn "$1"
  FL_PULL_WARNINGS="${FL_PULL_WARNINGS}${FL_PULL_WARNINGS:+,}$(fl_json_str "$1")"
}

# a word for a POSIX shell, in single quotes
fl_sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# The remote bench as a shell expression: "~/x" expands on the server.
fl_pull_rbench_expr() {
  # shellcheck disable=SC2016  # $HOME is for the remote shell
  case "$FL_PULL_RBENCH" in
    '~') printf '"$HOME"' ;;
    '~/'*) printf '"$HOME"/%s' "$(fl_sq "${FL_PULL_RBENCH#\~/}")" ;;
    *) fl_sq "$FL_PULL_RBENCH" ;;
  esac
}

# The backup folder for rsync and scp: relative paths start in the home folder.
fl_pull_rbackups_path() {
  local rb="$FL_PULL_RBENCH"
  case "$rb" in '~') rb="." ;; '~/'*) rb="${rb#\~/}" ;; esac
  printf '%s/sites/%s/private/backups' "$rb" "$FL_PULL_RSITE"
}

# fl_pull_ssh COMMAND: runs COMMAND on the server. The command goes to the
# log, its output never does.
fl_pull_ssh() {
  fl_log "remote: $1"
  ssh "${FL_PULL_SSH_OPTS[@]}" -- "$FL_PULL_HOST" "$1"
}

fl_pull_ssh_init() {
  FL_PULL_SSH_DIR="$(mktemp -d /tmp/benchbar-ssh.XXXXXX)"
  # one connection (and one key prompt) for the whole run
  FL_PULL_SSH_OPTS=(-o "ControlPath=${FL_PULL_SSH_DIR}/cm" -o ControlMaster=auto -o ControlPersist=60)
  if [[ "${FL_ASSUME_YES:-0}" == "1" || "${OPT_JSON:-0}" == "1" ]]; then
    FL_PULL_SSH_OPTS=(-o BatchMode=yes "${FL_PULL_SSH_OPTS[@]}")
  fi
}

# Called by the exit handler of benchbar however the run ends.
fl_pull_on_exit() {
  local code="${1:-0}"
  [[ "$FL_PULL_ACTIVE" == "1" ]] || return 0
  FL_PULL_ACTIVE=0
  if [[ -n "$FL_PULL_SSH_DIR" ]]; then
    ssh -o "ControlPath=${FL_PULL_SSH_DIR}/cm" -O exit "$FL_PULL_HOST" >/dev/null 2>&1 || true
    rm -f "${FL_PULL_SSH_DIR}/cm"
    rmdir "$FL_PULL_SSH_DIR" 2>/dev/null || true
  fi
  if [[ "$FL_PULL_DONE_SENT" == "0" ]]; then
    FL_PULL_DONE_SENT=1
    fl_pull_emit "done" ",\"exit\":${code},\"site\":$(fl_json_str "$FL_PULL_AS"),\"warnings\":[${FL_PULL_WARNINGS}]"
  fi
}

# fl_ver_cmp A B: -1, 0 or 1 (dot separated numbers; a suffix like -dev is ignored)
fl_ver_cmp() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    sub(/[^0-9.].*/, "", a); sub(/[^0-9.].*/, "", b)
    n = split(a, x, "."); m = split(b, y, "."); k = (n > m) ? n : m
    for (i = 1; i <= k; i++) {
      if ((x[i] + 0) < (y[i] + 0)) { print -1; exit }
      if ((x[i] + 0) > (y[i] + 0)) { print 1; exit }
    }
    print 0
  }'
}

fl_pull_human() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.1f GB", b / 1073741824
    else if (b >= 1048576) printf "%.1f MB", b / 1048576
    else if (b >= 1024) printf "%.0f KB", b / 1024
    else printf "%d bytes", b
  }'
}

# The version in apps/APP/APP/__init__.py, nothing when unknown.
fl_pull_local_version() {
  local f="${FL_BENCH_DIR}/apps/$1/$1/__init__.py"
  [[ -f "$f" ]] || return 0
  grep -m1 '^__version__' "$f" 2>/dev/null | cut -d= -f2 | tr -d " \"'" || true
}

fl_pull_local_branch() {
  git -C "${FL_BENCH_DIR}/apps/$1" rev-parse --abbrev-ref HEAD 2>/dev/null || true
}

fl_pull_local_has_app() {
  [[ -d "${FL_BENCH_DIR}/apps/$1" ]] && grep -qx "$1" "${FL_BENCH_DIR}/sites/apps.txt" 2>/dev/null
}

fl_pull_skipped() { case " $FL_PULL_SKIP_APPS " in *" $1 "*) return 0 ;; esac; return 1; }

# A token in a git remote (https://user:token@host/...) never reaches the screen.
fl_pull_redact_url() { printf '%s' "$1" | sed -E 's#://[^/@]*@#://#'; }

# The age of a backup from the timestamp at the start of its name, in hours
# (server time, so approximate). Nothing when it cannot be read.
fl_pull_age_hours() {
  local ts="$1" epoch
  epoch="$(date -j -f '%Y%m%d_%H%M%S' "$ts" +%s 2>/dev/null || date -d "$(printf '%s' "$ts" | sed -E 's/^(....)(..)(..)_(..)(..)(..)$/\1-\2-\3 \4:\5:\6/')" +%s 2>/dev/null || true)"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 0
  printf '%d' $((($(date +%s) - epoch) / 3600))
}

# fl_pull_pick_set NAMES: file names, one per line; sets FL_PULL_DB and the
# rest of the newest complete set (partial backups are left out).
fl_pull_pick_set() {
  local names="$1" prefix re
  FL_PULL_DB="$(printf '%s\n' "$names" | grep -E -- '-database(-enc)?\.sql(\.gz)?$' | grep -v -- '-partial-' | sort -r | head -n1 || true)"
  FL_PULL_PUB=""; FL_PULL_PRIV=""; FL_PULL_CONF=""
  [[ -n "$FL_PULL_DB" ]] || return 0
  prefix="${FL_PULL_DB%-database*}"
  re="$(printf '%s' "$prefix" | sed 's/\./\\./g')"
  FL_PULL_PUB="$(printf '%s\n' "$names" | grep -E "^${re}-files(-enc)?\.(tar|tgz|tar\.gz)$" | head -n1 || true)"
  FL_PULL_PRIV="$(printf '%s\n' "$names" | grep -E "^${re}-private-files(-enc)?\.(tar|tgz|tar\.gz)$" | head -n1 || true)"
  FL_PULL_CONF="$(printf '%s\n' "$names" | grep -E "^${re}-site_config_backup(-enc)?\.json$" | head -n1 || true)"
  FL_PULL_ENCRYPTED=0
  case "$FL_PULL_DB $FL_PULL_PUB $FL_PULL_PRIV" in *-enc.*) FL_PULL_ENCRYPTED=1 ;; esac
  return 0
}

# fl_pull_key_stream KEY: the value of KEY in the production site config, on
# stdout. Callers always pipe it into the one command that needs it.
fl_pull_key_stream() {
  if [[ -n "$FL_PULL_FROM_DIR" ]]; then
    [[ -n "$FL_PULL_CONF" ]] || return 0
    "${FL_BENCH_DIR}/env/bin/python" -c "$FL_PULL_PY_CONF" "${FL_PULL_FROM_DIR}/${FL_PULL_CONF}" value "$1"
  else
    fl_pull_ssh "cd $(fl_pull_rbench_expr) && env/bin/python -c $(fl_sq "$FL_PULL_PY_CONF") sites/$(fl_sq "$FL_PULL_RSITE")/site_config.json value $1"
  fi
}

fl_pull_files_list() {
  local f
  for f in "$FL_PULL_DB" "$FL_PULL_PUB" "$FL_PULL_PRIV"; do
    [[ -n "$f" ]] || continue
    [[ "$FL_PULL_NO_FILES" == "1" && "$f" != "$FL_PULL_DB" ]] && continue
    printf '%s\n' "$f"
  done
}

# The local file restore uses for NAME: the decrypted one for -enc files.
fl_pull_local_file() {
  local src
  if [[ -n "$FL_PULL_FROM_DIR" ]]; then src="${FL_PULL_FROM_DIR}/$1"; else src="${FL_PULL_STAGING}/$1"; fi
  case "$1" in
    *-enc.*) printf '%s/%s' "$FL_PULL_STAGING" "${1/-enc/}" ;;
    *) printf '%s' "$src" ;;
  esac
}

# ---------------------------------------------------------------- check

fl_pull_parse_args() {
  local src=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --as|--from-dir|--remote-bench|--skip-app|--confirm-site)
        [[ "$#" -ge 2 && -n "$2" ]] || fl_die "$1 needs a value." "Run: benchbar --help"
        case "$1" in
          --as) FL_PULL_AS="$2" ;;
          --from-dir) FL_PULL_FROM_DIR="$2" ;;
          --remote-bench) FL_PULL_RBENCH="$2" ;;
          --skip-app) FL_PULL_SKIP_APPS="${FL_PULL_SKIP_APPS}${FL_PULL_SKIP_APPS:+ }$2" ;;
          --confirm-site) FL_PULL_CONFIRM_SITE="$2" ;;
        esac
        shift 2 ;;
      --as=*) FL_PULL_AS="${1#*=}"; shift ;;
      --from-dir=*) FL_PULL_FROM_DIR="${1#*=}"; shift ;;
      --remote-bench=*) FL_PULL_RBENCH="${1#*=}"; shift ;;
      --skip-app=*) FL_PULL_SKIP_APPS="${FL_PULL_SKIP_APPS}${FL_PULL_SKIP_APPS:+ }${1#*=}"; shift ;;
      --confirm-site=*) FL_PULL_CONFIRM_SITE="${1#*=}"; shift ;;
      --new-backup) FL_PULL_NEW_BACKUP=1; shift ;;
      --replace) FL_PULL_REPLACE=1; shift ;;
      --no-files) FL_PULL_NO_FILES=1; shift ;;
      --keep-scheduler) FL_PULL_KEEP_SCHEDULER=1; shift ;;
      --keep-staging) FL_PULL_KEEP_STAGING=1; shift ;;
      -*) fl_die "Unknown option for pull: $1" "Run: benchbar --help" ;;
      *)
        [[ -z "$src" ]] || fl_die "pull takes one source, got '${src}' and '$1'." "Example: benchbar pull prod:erp.example.com --as erpcopy"
        src="$1"; shift ;;
    esac
  done
  if [[ -n "$FL_PULL_FROM_DIR" ]]; then
    [[ -z "$src" ]] || fl_die "Pass either HOST:SITE or --from-dir, not both."
    FL_PULL_FROM_DIR="$(cd "$FL_PULL_FROM_DIR" 2>/dev/null && pwd -P)" || fl_die "No folder ${FL_PULL_FROM_DIR}."
    [[ -n "$FL_PULL_AS" ]] || fl_die "--from-dir needs --as NAME, the local site name." "Example: benchbar pull --from-dir ~/Downloads/erp-backup --as erpcopy"
    [[ "$FL_PULL_NEW_BACKUP" == "0" ]] || fl_die "--new-backup needs a server; a folder has only the backup it has."
  else
    if [[ -z "$src" ]]; then
      src="$(fl_bstate_get PULL_SOURCE 2>/dev/null || true)"
      [[ -n "$src" ]] || fl_die "Usage: benchbar pull HOST:SITE [--as NAME] (or --from-dir DIR --as NAME)" "HOST is a Host alias from ~/.ssh/config, SITE the production site name."
      [[ -n "$FL_PULL_RBENCH" ]] || FL_PULL_RBENCH="$(fl_bstate_get PULL_REMOTE_BENCH 2>/dev/null || true)"
      fl_info "source from the last pull: ${src}"
    fi
    [[ "$src" == *:* ]] || fl_die "The source must be HOST:SITE, got '${src}'." "Example: benchbar pull prod:erp.example.com --as erpcopy"
    FL_PULL_HOST="${src%:*}"; FL_PULL_RSITE="${src##*:}"
    [[ -n "$FL_PULL_HOST" && "$FL_PULL_HOST" != -* && "$FL_PULL_HOST" =~ ^[A-Za-z0-9@._-]+$ ]] || fl_die "Invalid host '${FL_PULL_HOST}'." "Use a Host alias from ~/.ssh/config."
    [[ "$FL_PULL_RSITE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fl_die "Invalid production site name '${FL_PULL_RSITE}'."
    FL_PULL_RBENCH="${FL_PULL_RBENCH:-~/frappe-bench}"
    [[ "$FL_PULL_RBENCH" != -* && "$FL_PULL_RBENCH" != *$'\n'* ]] || fl_die "Invalid --remote-bench '${FL_PULL_RBENCH}'."
    [[ -n "$FL_PULL_AS" ]] || FL_PULL_AS="$(printf '%s.local' "$FL_PULL_RSITE" | tr '[:upper:]' '[:lower:]')"
  fi
  fl_site_valid_name "$FL_PULL_AS"
  local a
  for a in $FL_PULL_SKIP_APPS; do
    [[ "$a" =~ ^[a-z0-9_]+$ ]] || fl_die "Invalid app name for --skip-app: '${a}'."
    [[ "$a" != "frappe" ]] || fl_die "frappe cannot be skipped: every site needs it."
  done
}

# Everything read from the server, read only.
fl_pull_check_remote() {
  local out err code=0 rb line a list ver branch info origin names sizes
  rb="$(fl_pull_rbench_expr)"
  err="$(mktemp "${TMPDIR:-/tmp}/benchbar-ssh-err.XXXXXX")"
  out="$(fl_pull_ssh "cd ${rb} && test -f sites/$(fl_sq "$FL_PULL_RSITE")/site_config.json && test -x env/bin/python && echo benchbar-ok" 2>"$err")" || code=$?
  if [[ "$out" != *benchbar-ok* ]]; then
    fl_log "ssh: $(tr '\n' ' ' <"$err")"
    if [[ "$code" == "255" ]]; then
      fl_fail "ssh ${FL_PULL_HOST} failed: $(head -n1 "$err")"
      rm -f "$err"
      fl_die "No SSH connection to ${FL_PULL_HOST}." "Check that 'ssh ${FL_PULL_HOST} true' works (Host, HostName, User and IdentityFile in ~/.ssh/config, the key in ssh-agent)."
    fi
    rm -f "$err"
    fl_die "No site ${FL_PULL_RSITE} in ${FL_PULL_RBENCH} on ${FL_PULL_HOST} (or no env/bin/python there)." "Pass the bench folder on the server with --remote-bench DIR (default ~/frappe-bench)."
  fi
  rm -f "$err"
  fl_ok "ssh ${FL_PULL_HOST}: site ${FL_PULL_RSITE} in ${FL_PULL_RBENCH}"

  # the installed apps as production sees them: "app version branch"
  list="$(fl_pull_ssh "cd ${rb}/sites && ../env/bin/python -m frappe.utils.bench_helper frappe --site $(fl_sq "$FL_PULL_RSITE") list-apps" 2>/dev/null)" \
    || fl_die "Could not list the apps of ${FL_PULL_RSITE} on ${FL_PULL_HOST}." "Run on the server: cd ${FL_PULL_RBENCH} && bench --site ${FL_PULL_RSITE} list-apps"
  a=""
  while read -r line; do
    # shellcheck disable=SC2086  # split the line into its words
    set -- $line
    [[ "$#" -ge 2 && "$1" =~ ^[a-z][a-z0-9_]*$ ]] || continue
    a="${a}${a:+ }$1"
    FL_PULL_R_APPS="${FL_PULL_R_APPS}$1|$2|${3:-}|"$'\n'
  done <<<"$list"
  [[ -n "$a" ]] || fl_die "No apps in the list-apps output of ${FL_PULL_RSITE}." "Run on the server: cd ${FL_PULL_RBENCH} && bench --site ${FL_PULL_RSITE} list-apps"
  FL_PULL_APPS_KNOWN=1
  # branch and origin of each app folder on the server
  info="$(fl_pull_ssh "cd ${rb} && for a in ${a}; do printf '%s|%s|%s\\n' \"\$a\" \"\$(git -C apps/\$a rev-parse --abbrev-ref HEAD 2>/dev/null)\" \"\$(git -C apps/\$a remote get-url origin 2>/dev/null)\"; done" 2>/dev/null || true)"
  list="$FL_PULL_R_APPS"; FL_PULL_R_APPS=""
  while IFS='|' read -r a ver branch _; do
    [[ -n "$a" ]] || continue
    line="$(printf '%s\n' "$info" | grep "^${a}|" | head -n1 || true)"
    origin="$(fl_pull_redact_url "$(printf '%s' "$line" | cut -d'|' -f3-)")"
    [[ -n "$(printf '%s' "$line" | cut -d'|' -f2)" ]] && branch="$(printf '%s' "$line" | cut -d'|' -f2)"
    FL_PULL_R_APPS="${FL_PULL_R_APPS}${a}|${ver}|${branch}|${origin}"$'\n'
  done <<<"$list"

  names="$(fl_pull_ssh "cd ${rb}/sites/$(fl_sq "$FL_PULL_RSITE")/private/backups 2>/dev/null && ls -1" 2>/dev/null || true)"
  fl_pull_pick_set "$names"
  if [[ -n "$FL_PULL_DB" ]]; then
    sizes="$(fl_pull_ssh "cd ${rb}/sites/$(fl_sq "$FL_PULL_RSITE")/private/backups && wc -c $(for a in "$FL_PULL_DB" "$FL_PULL_PUB" "$FL_PULL_PRIV"; do [[ -n "$a" ]] && fl_sq "$a" && printf ' '; done)" 2>/dev/null || true)"
    fl_pull_set_sizes "$sizes"
  fi
  out="$(fl_pull_ssh "cd ${rb} && env/bin/python -c $(fl_sq "$FL_PULL_PY_CONF") sites/$(fl_sq "$FL_PULL_RSITE")/site_config.json has encryption_key backup_encryption_key" 2>/dev/null || true)"
  case " $out " in *" encryption_key=yes "*) FL_PULL_HAS_KEY=1 ;; *) FL_PULL_HAS_KEY=0 ;; esac
  case " $out " in *" backup_encryption_key=yes "*) FL_PULL_HAS_BACKUP_KEY=1 ;; esac
  fl_pull_ssh "command -v rsync" >/dev/null 2>&1 && FL_PULL_REMOTE_RSYNC=1
  return 0
}

# fl_pull_set_sizes "wc -c output": the byte counts of the set
fl_pull_set_sizes() {
  local n f
  FL_PULL_DB_BYTES=0; FL_PULL_PUB_BYTES=0; FL_PULL_PRIV_BYTES=0
  while read -r n f; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    case "$f" in
      "$FL_PULL_DB") FL_PULL_DB_BYTES="$n" ;;
      "$FL_PULL_PUB") FL_PULL_PUB_BYTES="$n" ;;
      "$FL_PULL_PRIV") FL_PULL_PRIV_BYTES="$n" ;;
    esac
  done <<<"$1"
  FL_PULL_TOTAL_BYTES="$FL_PULL_DB_BYTES"
  [[ "$FL_PULL_NO_FILES" == "1" ]] || FL_PULL_TOTAL_BYTES=$((FL_PULL_DB_BYTES + FL_PULL_PUB_BYTES + FL_PULL_PRIV_BYTES))
}

# The same facts from a folder of downloaded backup files.
fl_pull_check_dir() {
  local names out f
  names="$(ls -1 "$FL_PULL_FROM_DIR" 2>/dev/null || true)"
  fl_pull_pick_set "$names"
  [[ -n "$FL_PULL_DB" ]] || fl_die "No database backup (*-database.sql.gz) in ${FL_PULL_FROM_DIR}." "Download the backup set (database, files, private files, site config) into one folder."
  out=""
  for f in "$FL_PULL_DB" "$FL_PULL_PUB" "$FL_PULL_PRIV"; do
    [[ -n "$f" ]] && out="${out}$(wc -c <"${FL_PULL_FROM_DIR}/${f}" | tr -d ' ') ${f}"$'\n'
  done
  fl_pull_set_sizes "$out"
  if [[ -n "$FL_PULL_CONF" && "$FL_PULL_CONF" != *-enc.* ]]; then
    out="$("${FL_BENCH_DIR}/env/bin/python" -c "$FL_PULL_PY_CONF" "${FL_PULL_FROM_DIR}/${FL_PULL_CONF}" has encryption_key backup_encryption_key 2>/dev/null || true)"
    case " $out " in *" encryption_key=yes "*) FL_PULL_HAS_KEY=1 ;; esac
    case " $out " in *" backup_encryption_key=yes "*) FL_PULL_HAS_BACKUP_KEY=1 ;; esac
  else
    FL_PULL_CONF=""
  fi
  # the app list is in the dump (tabDefaultValue installed_apps); an
  # encrypted dump is read after it is decrypted
  [[ "$FL_PULL_ENCRYPTED" == "1" ]] || fl_pull_apps_from_dump "${FL_PULL_FROM_DIR}/${FL_PULL_DB}"
  return 0
}

# fl_pull_apps_from_dump FILE: the installed_apps global of a dump
fl_pull_apps_from_dump() {
  local reader=cat apps a
  [[ "$1" == *.gz ]] && reader="gzip -dc"
  apps="$($reader "$1" 2>/dev/null | grep -o -m1 "'installed_apps','[^']*'" 2>/dev/null | head -n1 | sed -e "s/^'installed_apps','//" -e "s/'\$//" | tr -d '[]\\" ' | tr ',' ' ' || true)"
  [[ -n "$apps" ]] || { fl_pull_warn "the app list could not be read from the dump; missing apps show up only at migrate"; return 0; }
  FL_PULL_R_APPS=""
  for a in $apps; do FL_PULL_R_APPS="${FL_PULL_R_APPS}${a}|||"$'\n'; done
  FL_PULL_APPS_KNOWN=1
}

# The app table: production apps against this bench. Sets FL_PULL_MISSING
# and FL_PULL_NEED_MIGRATE, prints the table.
fl_pull_diff_apps() {
  local rows=() a ver branch origin lver lbranch status cmp
  FL_PULL_MISSING=""; FL_PULL_APPS_JSON=""
  FL_PULL_NEED_MIGRATE=0
  [[ "$FL_PULL_APPS_KNOWN" == "1" ]] || { FL_PULL_NEED_MIGRATE=1; return 0; }
  rows+=("App|Production|Local|Status")
  while IFS='|' read -r a ver branch origin; do
    [[ -n "$a" ]] || continue
    lver=""; lbranch=""
    if fl_pull_skipped "$a"; then
      status="skipped"
    elif ! fl_pull_local_has_app "$a"; then
      status="missing"; FL_PULL_MISSING="${FL_PULL_MISSING}${a}|${branch}|${origin}"$'\n'
    else
      lver="$(fl_pull_local_version "$a")"; lbranch="$(fl_pull_local_branch "$a")"
      status="ok"
      if [[ -n "$ver" && -n "$lver" ]]; then
        cmp="$(fl_ver_cmp "$lver" "$ver")"
        [[ "$cmp" == "-1" ]] && status="local older"
        [[ "$cmp" == "1" ]] && status="local newer"
        [[ "$cmp" == "0" ]] || FL_PULL_NEED_MIGRATE=1
      else
        FL_PULL_NEED_MIGRATE=1
      fi
      [[ "$status" == "ok" && -n "$branch" && -n "$lbranch" && "$branch" != "$lbranch" ]] && status="branch differs"
    fi
    rows+=("${a}|${ver:-?}${branch:+ (${branch})}|${lver:-${lbranch:+?}}${lbranch:+ (${lbranch})}|${status}")
    FL_PULL_APPS_JSON="${FL_PULL_APPS_JSON}${FL_PULL_APPS_JSON:+,}{\"app\":$(fl_json_str "$a"),\"production_version\":$(fl_json_str "$ver"),\"production_branch\":$(fl_json_str "$branch"),\"local_version\":$(fl_json_str "$lver"),\"local_branch\":$(fl_json_str "$lbranch"),\"status\":$(fl_json_str "$status")}"
  done <<<"$FL_PULL_R_APPS"
  [[ -n "$FL_PULL_SKIP_APPS" ]] && FL_PULL_NEED_MIGRATE=1
  printf '\n%sApps%s\n' "$FL_BOLD" "$FL_RESET"
  fl_table "${rows[@]}"
}

# Stops when production has apps this bench lacks, with the commands to get them.
fl_pull_require_apps() {
  local a branch origin cmd
  [[ -n "$FL_PULL_MISSING" ]] || return 0
  printf '\n'
  fl_fail "this bench lacks apps the production site has installed; a restored site with a missing app fails at migrate"
  while IFS='|' read -r a branch origin; do
    [[ -n "$a" ]] || continue
    cmd="cd ${FL_BENCH_DIR} && bench get-app"
    [[ -n "$branch" ]] && cmd="${cmd} --branch ${branch}"
    cmd="${cmd} ${origin:-$a}"
    fl_fix "$cmd"
  done <<<"$FL_PULL_MISSING"
  fl_info "or leave an app out with --skip-app APP: the site forgets it, but its doctypes and tables stay behind as orphans"
  fl_die "Get the missing apps first, then run this again." "Nothing was changed."
}

# Production frappe newer than this bench: restore would ask about a
# downgrade and migrate cannot go backwards.
fl_pull_require_frappe_version() {
  local rver lver
  rver="$(printf '%s\n' "$FL_PULL_R_APPS" | awk -F'|' '$1 == "frappe" { print $2; exit }')"
  lver="$(fl_pull_local_version frappe)"
  [[ -n "$rver" && -n "$lver" ]] || return 0
  if [[ "$(fl_ver_cmp "$rver" "$lver")" == "1" ]]; then
    fl_die "Production runs frappe ${rver}, this bench frappe ${lver}: the dump is newer than the code." \
      "Update this bench's apps to the production versions first (bench update is your call), or pull into a bench on the same version."
  fi
}

fl_pull_check_local() {
  if [[ -d "${FL_BENCH_DIR}/sites/${FL_PULL_AS}" ]]; then
    FL_PULL_SITE_EXISTS=1
    [[ "$FL_PULL_REPLACE" == "1" ]] || fl_die "Site ${FL_PULL_AS} already exists in ${FL_BENCH_DIR}." "Pick another name with --as NAME, or pass --replace (backs the site up first, then restores over it)."
    fl_warn "site ${FL_PULL_AS} exists and will be replaced (--replace): it is backed up first"
  fi
  fl_port_listening 3306 || fl_die "MariaDB is not running (nothing listens on 3306)." "Start it: brew services start ${FL_MARIADB_FORMULA:-mariadb}"
  fl_mariadb_root_password_resolve || fl_die "The MariaDB root password is needed for the restore." "Re-run with: MARIADB_ROOT_PASSWORD='...' benchbar pull ..." 2
  if [[ "$FL_PULL_ENCRYPTED" == "1" ]]; then
    command -v gpg >/dev/null 2>&1 || fl_die "The backup is encrypted and gpg is not installed." "Install it: brew install gnupg"
    [[ "$FL_PULL_HAS_BACKUP_KEY" == "1" ]] || fl_die "The backup is encrypted but the production site config has no backup_encryption_key." "Decrypt the files by hand, or copy the key from the server's site_config.json."
  fi
  fl_pull_check_disk
}

fl_pull_check_disk() {
  local avail need
  [[ "$FL_PULL_TOTAL_BYTES" -gt 0 ]] || return 0
  avail="$(df -k "$FL_BENCH_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  [[ "$avail" =~ ^[0-9]+$ ]] || return 0
  # the download, the decrypted copy or the database and the extracted files
  need=$(((FL_PULL_TOTAL_BYTES * 3 + 1023) / 1024))
  if [[ "$avail" -lt "$need" ]]; then
    fl_die "Not enough free disk space: $(fl_pull_human $((avail * 1024))) free, about $(fl_pull_human $((need * 1024))) needed (3x the backup)." "Free some space on the volume of ${FL_BENCH_DIR}, or pull without files (--no-files)."
  fi
}

# ---------------------------------------------------------------- plan

fl_pull_source_label() {
  if [[ -n "$FL_PULL_FROM_DIR" ]]; then printf '%s' "$FL_PULL_FROM_DIR"; else printf '%s:%s' "$FL_PULL_HOST" "$FL_PULL_RSITE"; fi
}

fl_pull_backup_label() {
  local age ts
  if [[ "$FL_PULL_NEW_BACKUP" == "1" ]]; then
    printf 'a new backup on %s (asks for the site name first)' "$FL_PULL_HOST"
    return 0
  fi
  ts="${FL_PULL_DB%%-*}"
  age="$(fl_pull_age_hours "$ts")"
  printf '%s, %s%s%s' "$ts" "$(fl_pull_human "$FL_PULL_TOTAL_BYTES")" "${age:+, about ${age}h old}" "$([[ "$FL_PULL_ENCRYPTED" == "1" ]] && printf ', encrypted')"
}

# fl_pull_plan_steps: the step labels, in order, for this run
fl_pull_plan_steps() {
  FL_PULL_STEPS=()
  [[ "$FL_PULL_NEW_BACKUP" == "1" ]] && FL_PULL_STEPS+=("new_backup|Take a new backup on ${FL_PULL_HOST}")
  [[ -z "$FL_PULL_FROM_DIR" ]] && FL_PULL_STEPS+=("download|Download the backup")
  [[ "$FL_PULL_ENCRYPTED" == "1" || "$FL_PULL_NEW_BACKUP" == "1" ]] && FL_PULL_STEPS+=("decrypt|Decrypt the backup (gpg, local)")
  [[ "$FL_PULL_SITE_EXISTS" == "1" ]] && FL_PULL_STEPS+=("local_backup|Back up the local site ${FL_PULL_AS}")
  FL_PULL_STEPS+=("restore|Restore into ${FL_PULL_AS}")
  FL_PULL_STEPS+=("encryption_key|Carry the encryption key over")
  FL_PULL_STEPS+=("dev_safety|Mute email and pause the scheduler")
  [[ -n "$FL_PULL_SKIP_APPS" ]] && FL_PULL_STEPS+=("skip_apps|Remove skipped apps from the site: ${FL_PULL_SKIP_APPS}")
  FL_PULL_STEPS+=("migrate|bench migrate")
  FL_PULL_STEPS+=("clear_cache|Clear caches")
  FL_PULL_STEPS+=("admin_password|Administrator password")
  FL_PULL_STEPS+=("hosts|Hosts line for ${FL_PULL_AS}")
  [[ -z "$FL_PULL_FROM_DIR" || "$FL_PULL_ENCRYPTED" == "1" ]] && FL_PULL_STEPS+=("cleanup|Remove the downloaded files")
  FL_PULL_STEPS+=("verify|Verify")
  return 0
}

fl_pull_print_plan() {
  local s labels=() json_steps=""
  printf '\n'
  fl_box "Pull" \
    "from     $(fl_pull_source_label)$([[ -z "$FL_PULL_FROM_DIR" ]] && printf ' (bench %s)' "$FL_PULL_RBENCH")" \
    "backup   $(fl_pull_backup_label)" \
    "into     ${FL_PULL_AS} in ${FL_BENCH_DIR}$([[ "$FL_PULL_SITE_EXISTS" == "1" ]] && printf ' (replaced, backup first)')" \
    "key      $([[ "$FL_PULL_HAS_KEY" == "1" ]] && printf 'encryption_key carried over (never shown)' || printf 'none on production: stored passwords will not decrypt')" \
    "safety   mute_emails$([[ "$FL_PULL_KEEP_SCHEDULER" == "1" ]] && printf ', scheduler kept' || printf ', scheduler paused'), host_name http://${FL_PULL_AS}:${FL_WEB_PORT}"
  if [[ "$FL_PULL_NEW_BACKUP" == "1" ]]; then
    fl_warn "--new-backup runs bench backup on ${FL_PULL_HOST}: it writes a full dump there and deletes backup files older than keep_backups_for_hours (default 23) in sites/${FL_PULL_RSITE}/private/backups"
  elif [[ -z "$FL_PULL_FROM_DIR" ]]; then
    fl_info "nothing is written on ${FL_PULL_HOST}: the latest existing backup is used (--new-backup takes a fresh one)"
  fi
  printf '\n%sSteps%s\n' "$FL_BOLD" "$FL_RESET"
  local i=1
  for s in "${FL_PULL_STEPS[@]}"; do
    printf '  %s %d. %s\n' "$FL_G_PEND" "$i" "${s#*|}"
    json_steps="${json_steps}${json_steps:+,}$(fl_json_str "${s#*|}")"
    i=$((i + 1))
  done
  fl_pull_emit plan ",\"source\":$(fl_json_str "$(fl_pull_source_label)"),\"host\":$(fl_json_str "$FL_PULL_HOST"),\"remote_site\":$(fl_json_str "$FL_PULL_RSITE"),\"remote_bench\":$(fl_json_str "$FL_PULL_RBENCH"),\"from_dir\":$(fl_json_str "$FL_PULL_FROM_DIR"),\"bench\":$(fl_json_str "$FL_BENCH_DIR"),\"site\":$(fl_json_str "$FL_PULL_AS"),\"replace\":$(fl_json_bool "$FL_PULL_SITE_EXISTS"),\"backup\":{\"name\":$(fl_json_str "$([[ "$FL_PULL_NEW_BACKUP" == "1" ]] || printf '%s' "$FL_PULL_DB")"),\"new\":$(fl_json_bool "$FL_PULL_NEW_BACKUP"),\"bytes\":$(fl_json_num "$([[ "$FL_PULL_NEW_BACKUP" == "1" ]] || printf '%s' "$FL_PULL_TOTAL_BYTES")"),\"age_hours\":$(fl_json_num "$([[ "$FL_PULL_NEW_BACKUP" == "1" ]] || fl_pull_age_hours "${FL_PULL_DB%%-*}")"),\"encrypted\":$(fl_json_bool "$FL_PULL_ENCRYPTED")},\"encryption_key\":$(fl_json_bool "$FL_PULL_HAS_KEY"),\"apps\":[${FL_PULL_APPS_JSON:-}],\"migrate\":$(fl_json_bool "$FL_PULL_NEED_MIGRATE"),\"steps\":[${json_steps}],\"dry_run\":$(fl_json_bool "${FL_DRY_RUN:-0}")"
}

# ---------------------------------------------------------------- gates

# The only remote write: typed site name, even with --yes (it also deletes
# older backups on production).
fl_pull_gate_new_backup() {
  local answer=""
  if [[ -n "$FL_PULL_CONFIRM_SITE" ]]; then
    answer="$FL_PULL_CONFIRM_SITE"
  elif [[ -t 0 && "${OPT_JSON:-0}" != "1" ]]; then
    read -r -p "  Type the production site name (${FL_PULL_RSITE}) to run bench backup on ${FL_PULL_HOST}: " answer || answer=""
  else
    fl_pull_emit gate ",\"name\":\"new_backup\",\"answer\":\"no\""
    fl_die "--new-backup needs the production site name typed, even with --yes." "Run it in a terminal, or add --confirm-site ${FL_PULL_RSITE}. Nothing was changed."
  fi
  if [[ "$answer" != "$FL_PULL_RSITE" ]]; then
    fl_pull_emit gate ",\"name\":\"new_backup\",\"answer\":\"no\""
    fl_die "The name does not match ${FL_PULL_RSITE}; no backup was taken." "Nothing was changed. Without --new-backup the latest existing backup is used."
  fi
  fl_pull_emit gate ",\"name\":\"new_backup\",\"answer\":\"yes\""
}

fl_pull_gate_apply() {
  local q
  q="Restore $(fl_pull_source_label) into the new site ${FL_PULL_AS}?"
  [[ "$FL_PULL_SITE_EXISTS" == "1" ]] && q="Back up ${FL_PULL_AS}, then replace it with $(fl_pull_source_label)?"
  if fl_confirm "$q"; then
    fl_pull_emit gate ",\"name\":\"apply\",\"answer\":\"yes\""
    return 0
  fi
  fl_pull_emit gate ",\"name\":\"apply\",\"answer\":\"no\""
  fl_warn "Cancelled. Nothing was changed."
  exit 1
}

# ---------------------------------------------------------------- apply steps

fl_pull_step_new_backup() {
  local rb names before="$FL_PULL_DB"
  rb="$(fl_pull_rbench_expr)"
  fl_run_long "bench backup on ${FL_PULL_HOST}" fl_pull_ssh \
    "cd ${rb}/sites && ../env/bin/python -m frappe.utils.bench_helper frappe --site $(fl_sq "$FL_PULL_RSITE") backup$([[ "$FL_PULL_NO_FILES" == "1" ]] || printf ' --with-files')" || return 1
  names="$(fl_pull_ssh "cd ${rb}/sites/$(fl_sq "$FL_PULL_RSITE")/private/backups && ls -1" 2>/dev/null || true)"
  fl_pull_pick_set "$names"
  if [[ -z "$FL_PULL_DB" || "$FL_PULL_DB" == "$before" ]]; then
    fl_fail "no new backup appeared in sites/${FL_PULL_RSITE}/private/backups"
    return 1
  fi
  fl_pull_set_sizes "$(fl_pull_ssh "cd ${rb}/sites/$(fl_sq "$FL_PULL_RSITE")/private/backups && wc -c $(for f in "$FL_PULL_DB" "$FL_PULL_PUB" "$FL_PULL_PRIV"; do [[ -n "$f" ]] && fl_sq "$f" && printf ' '; done)" 2>/dev/null || true)"
  fl_ok "new backup ${FL_PULL_DB%%-*} ($(fl_pull_human "$FL_PULL_TOTAL_BYTES"))"
  fl_pull_check_disk
}

fl_pull_staging_init() {
  local key
  if [[ -n "$FL_PULL_FROM_DIR" ]]; then key="dir-${FL_PULL_DB%%-*}"; else key="${FL_PULL_RSITE}-${FL_PULL_DB%%-*}"; fi
  # keyed by the backup, so a rerun of the same pull resumes into the same folder
  FL_PULL_STAGING="${FL_BENCH_DIR}/.benchbar/pulls/${key}"
  mkdir -p "$FL_PULL_STAGING"
  chmod 700 "${FL_BENCH_DIR}/.benchbar/pulls" "$FL_PULL_STAGING"
}

fl_pull_step_download() {
  local f size done_bytes=0 remote rsync_flags=(-a --partial) e_opts code
  fl_pull_staging_init
  remote="$(fl_pull_rbackups_path)"
  if rsync --version 2>/dev/null | head -n1 | grep -q -E '^rsync +version 3\.'; then
    rsync_flags+=(--append-verify --info=progress2)
  else
    # rsync 2.6.9 and openrsync (macOS): --partial keeps the partial file as the basis of the next run
    rsync_flags+=(--progress)
  fi
  e_opts="ssh ${FL_PULL_SSH_OPTS[*]}"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case "$f" in
      "$FL_PULL_DB") size="$FL_PULL_DB_BYTES" ;;
      "$FL_PULL_PUB") size="$FL_PULL_PUB_BYTES" ;;
      *) size="$FL_PULL_PRIV_BYTES" ;;
    esac
    if [[ -f "${FL_PULL_STAGING}/${f}" && "$(wc -c <"${FL_PULL_STAGING}/${f}" | tr -d ' ')" == "$size" ]]; then
      fl_ok "${f} already downloaded"
    else
      fl_info "downloading ${f} ($(fl_pull_human "$size"))"
      fl_log "download: ${FL_PULL_HOST}:${remote}/${f}"
      code=0
      if [[ "$FL_PULL_REMOTE_RSYNC" == "1" ]] && command -v rsync >/dev/null 2>&1; then
        rsync "${rsync_flags[@]}" -e "$e_opts" "${FL_PULL_HOST}:${remote}/${f}" "${FL_PULL_STAGING}/" || code=$?
      else
        scp -q "${FL_PULL_SSH_OPTS[@]}" "${FL_PULL_HOST}:${remote}/${f}" "${FL_PULL_STAGING}/" || code=$?
      fi
      if [[ "$code" != "0" ]]; then
        fl_fail "the download of ${f} stopped (exit ${code})"
        fl_fix "run the same benchbar pull again: the files already here are kept$([[ "$FL_PULL_REMOTE_RSYNC" == "1" ]] && printf ' and the transfer resumes')"
        return 1
      fi
      if [[ "$(wc -c <"${FL_PULL_STAGING}/${f}" | tr -d ' ')" != "$size" ]]; then
        fl_fail "${f} has the wrong size after the download"
        return 1
      fi
    fi
    done_bytes=$((done_bytes + size))
    fl_pull_emit progress ",\"file\":$(fl_json_str "$f"),\"bytes\":${done_bytes},\"total\":${FL_PULL_TOTAL_BYTES}"
  done < <(fl_pull_files_list)
  fl_ok "downloaded to ${FL_PULL_STAGING} ($(fl_pull_human "$FL_PULL_TOTAL_BYTES"))"
}

fl_pull_step_decrypt() {
  local f src out
  if [[ "$FL_PULL_ENCRYPTED" != "1" ]]; then FL_STEP_RESULT=skipped; fl_info "the backup is not encrypted"; return 0; fi
  [[ -n "$FL_PULL_STAGING" ]] || fl_pull_staging_init
  command -v gpg >/dev/null 2>&1 || { fl_fail "gpg is not installed"; fl_fix "brew install gnupg"; return 1; }
  while IFS= read -r f; do
    [[ -n "$f" && "$f" == *-enc.* ]] || continue
    if [[ -n "$FL_PULL_FROM_DIR" ]]; then src="${FL_PULL_FROM_DIR}/${f}"; else src="${FL_PULL_STAGING}/${f}"; fi
    out="$(fl_pull_local_file "$f")"
    # frappe's own decrypt puts the passphrase on gpg's command line; here it goes in on stdin
    if ! fl_pull_key_stream backup_encryption_key | gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 0 -o "$out" -d "$src" >>"${FL_LOG_FILE:-/dev/null}" 2>&1; then
      fl_fail "gpg could not decrypt ${f} with the production backup_encryption_key"
      return 1
    fi
    fl_ok "decrypted ${f}"
  done < <(fl_pull_files_list)
  if [[ -n "$FL_PULL_FROM_DIR" && "$FL_PULL_APPS_KNOWN" == "0" ]]; then
    fl_pull_apps_from_dump "$(fl_pull_local_file "$FL_PULL_DB")"
    fl_pull_diff_apps
    fl_pull_require_apps
  fi
}

fl_pull_step_local_backup() {
  fl_bench_env_exports
  fl_run_long "bench --site ${FL_PULL_AS} backup --with-files" fl__in_dir "$FL_BENCH_DIR" bench --site "$FL_PULL_AS" backup --with-files || return 1
  fl_ok "backup of the old ${FL_PULL_AS} in sites/${FL_PULL_AS}/private/backups"
  if [[ "${FL_ASSUME_YES:-0}" != "1" ]] && ! fl_confirm "The old ${FL_PULL_AS} is backed up. Replace it now?"; then
    fl_pull_emit gate ",\"name\":\"replace\",\"answer\":\"no\""
    fl_warn "Cancelled after the backup. ${FL_PULL_AS} is unchanged."
    exit 1
  fi
}

# fl__pull_frappe_secret VAR SITE CMD OPT ARGS...: bench --site SITE CMD with
# the value of VAR on stdin (the name, not the value, is what logs see)
fl__pull_frappe_secret() {
  local var="$1"
  shift
  printf '%s\n' "${!var}" | fl__in_dir "${FL_BENCH_DIR}/sites" "${FL_BENCH_DIR}/env/bin/python" -c "$FL_PULL_PY_FRAPPE" benchbar-frappe "$@"
}

fl_pull_step_restore() {
  local args=(--mariadb-root-password "$(fl_pull_local_file "$FL_PULL_DB")")
  if [[ "$FL_PULL_NO_FILES" != "1" ]]; then
    [[ -n "$FL_PULL_PUB" ]] && args+=(--with-public-files "$(fl_pull_local_file "$FL_PULL_PUB")")
    [[ -n "$FL_PULL_PRIV" ]] && args+=(--with-private-files "$(fl_pull_local_file "$FL_PULL_PRIV")")
  fi
  fl_bench_env_exports
  # frappe v16 needs the bench's Redis during restore and migrate
  [[ -n "$FL_SETUP_REDIS_PORTS" ]] || fl_bench_redis_up "$FL_BENCH_DIR"
  fl_run_long "bench --site ${FL_PULL_AS} restore" fl__pull_frappe_secret FL_MARIADB_ROOT_PW "$FL_PULL_AS" restore "${args[@]}" || {
    fl_fix "the log has frappe's message: ${FL_LOG_FILE:-}"
    return 1
  }
  [[ -f "${FL_BENCH_DIR}/sites/${FL_PULL_AS}/site_config.json" ]] || { fl_fail "restore left no sites/${FL_PULL_AS}/site_config.json"; return 1; }
}

fl_pull_step_encryption_key() {
  local out
  if [[ "$FL_PULL_HAS_KEY" != "1" ]]; then
    FL_STEP_RESULT=skipped
    fl_pull_warn "production has no encryption_key: passwords stored in the site (email accounts, integrations) must be entered again"
    return 0
  fi
  out="$(fl_pull_key_stream encryption_key | "${FL_BENCH_DIR}/env/bin/python" -c "$FL_PULL_PY_SETKEY" "${FL_BENCH_DIR}/sites/${FL_PULL_AS}/site_config.json" 2>>"${FL_LOG_FILE:-/dev/null}")" || {
    fl_fail "could not copy the encryption_key into sites/${FL_PULL_AS}/site_config.json"
    return 1
  }
  [[ "$out" == "unchanged" ]] && FL_STEP_RESULT=unchanged
  fl_ok "encryption_key of ${FL_PULL_RSITE:-the backup} is in sites/${FL_PULL_AS}/site_config.json (not shown)"
}

fl_pull_bench_site() {
  fl_log "run: bench --site ${FL_PULL_AS} $*"
  (cd "$FL_BENCH_DIR" && bench --site "$FL_PULL_AS" "$@") >>"${FL_LOG_FILE:-/dev/null}" 2>&1
}

fl_pull_step_dev_safety() {
  fl_bench_env_exports
  fl_pull_bench_site set-config -p mute_emails 1 || { fl_fail "set-config mute_emails failed"; return 1; }
  fl_ok "mute_emails set: the copy sends no email"
  if [[ "$FL_PULL_KEEP_SCHEDULER" == "1" ]]; then
    fl_info "scheduler left as production had it (--keep-scheduler)"
  else
    fl_pull_bench_site set-config -p pause_scheduler 1 || { fl_fail "set-config pause_scheduler failed"; return 1; }
    fl_pull_bench_site disable-scheduler || fl_warn "bench disable-scheduler failed; pause_scheduler is set anyway"
    fl_ok "scheduler paused (bench --site ${FL_PULL_AS} enable-scheduler, and remove pause_scheduler, to run jobs)"
  fi
  fl_pull_bench_site set-config host_name "http://${FL_PULL_AS}:${FL_WEB_PORT}" || fl_warn "could not set host_name"
}

fl_pull_step_skip_apps() {
  local a
  fl_bench_env_exports
  for a in $FL_PULL_SKIP_APPS; do
    fl_pull_bench_site remove-from-installed-apps "$a" || { fl_fail "remove-from-installed-apps ${a} failed"; return 1; }
    fl_warn "${a} removed from the site's app list; its doctypes and tables stay behind"
  done
}

fl_pull_step_migrate() {
  if [[ "$FL_PULL_NEED_MIGRATE" != "1" ]]; then
    FL_STEP_RESULT=skipped
    fl_info "every app has the production version; no migrate needed"
    return 0
  fi
  fl_bench_env_exports
  [[ -n "$FL_SETUP_REDIS_PORTS" ]] || fl_bench_redis_up "$FL_BENCH_DIR"
  fl_run_long "bench --site ${FL_PULL_AS} migrate" fl__in_dir "$FL_BENCH_DIR" bench --site "$FL_PULL_AS" migrate || {
    fl_fix "cd ${FL_BENCH_DIR} && bench --site ${FL_PULL_AS} migrate"
    return 1
  }
}

fl_pull_step_clear_cache() {
  fl_bench_env_exports
  fl_pull_bench_site clear-cache || fl_warn "clear-cache failed"
  fl_pull_bench_site clear-website-cache || fl_warn "clear-website-cache failed"
  fl_bench_redis_down
}

fl_pull_step_admin_password() {
  local pw="${ADMIN_PASSWORD:-}"
  if [[ -z "$pw" ]]; then
    if [[ "${FL_ASSUME_YES:-0}" == "1" || ! -t 0 ]]; then
      FL_STEP_RESULT=skipped
      fl_info "the production Administrator password works on the copy (ADMIN_PASSWORD='...' sets a new one)"
      return 0
    fi
    if ! fl_confirm "Set a new Administrator password on ${FL_PULL_AS}? (otherwise the production one works)"; then
      FL_STEP_RESULT=skipped
      return 0
    fi
    fl_ask_secret pw "Administrator password for ${FL_PULL_AS}"
  fi
  FL_PULL_ADMIN_PW="$pw"
  fl_run_long "bench --site ${FL_PULL_AS} set-admin-password" fl__pull_frappe_secret FL_PULL_ADMIN_PW "$FL_PULL_AS" set-admin-password - || { FL_PULL_ADMIN_PW=""; return 1; }
  FL_PULL_ADMIN_PW=""
}

fl_pull_step_hosts() {
  fl_hosts_add_names "$FL_PULL_AS"
  fl_hosts_has_name "$FL_PULL_AS" || FL_STEP_RESULT=skipped
}

fl_pull_step_cleanup() {
  local f
  if [[ "$FL_PULL_KEEP_STAGING" == "1" ]]; then
    FL_STEP_RESULT=skipped
    fl_info "kept ${FL_PULL_STAGING} (--keep-staging)"
    return 0
  fi
  [[ -n "$FL_PULL_STAGING" && -d "$FL_PULL_STAGING" ]] || { FL_STEP_RESULT=unchanged; return 0; }
  # only the files this run put there
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    rm -f "${FL_PULL_STAGING}/${f}" "${FL_PULL_STAGING}/${f/-enc/}"
  done < <(fl_pull_files_list)
  rmdir "$FL_PULL_STAGING" 2>/dev/null || fl_warn "${FL_PULL_STAGING} is not empty; left as it is"
  fl_ok "removed the downloaded backup"
}

fl_pull_step_verify() {
  local out apps want a code
  fl_bench_env_exports
  out="$("${FL_BENCH_DIR}/env/bin/python" -c "$FL_PULL_PY_CONF" "${FL_BENCH_DIR}/sites/${FL_PULL_AS}/site_config.json" has mute_emails pause_scheduler 2>/dev/null || true)"
  case " $out " in *" mute_emails=yes "*) fl_ok "mute_emails is set" ;; *) fl_fail "mute_emails is not set"; return 1 ;; esac
  if [[ "$FL_PULL_KEEP_SCHEDULER" != "1" ]]; then
    case " $out " in *" pause_scheduler=yes "*) fl_ok "pause_scheduler is set" ;; *) fl_fail "pause_scheduler is not set"; return 1 ;; esac
  fi
  apps="$(cd "$FL_BENCH_DIR" && bench --site "$FL_PULL_AS" list-apps 2>/dev/null | awk 'NF { print $1 }' | sort | tr '\n' ' ' || true)"
  if [[ "$FL_PULL_APPS_KNOWN" == "1" ]]; then
    want="$(printf '%s' "$FL_PULL_R_APPS" | cut -d'|' -f1 | while read -r a; do [[ -n "$a" ]] && ! fl_pull_skipped "$a" && printf '%s\n' "$a"; done | sort | tr '\n' ' ' || true)"
    if [[ "$apps" == "$want" ]]; then fl_ok "apps on ${FL_PULL_AS}: ${apps% }"; else fl_pull_warn "apps on ${FL_PULL_AS} are '${apps% }', production had '${want% }'"; fi
  fi
  out="$(cd "${FL_BENCH_DIR}/sites" && "${FL_BENCH_DIR}/env/bin/python" -c "$FL_PULL_PY_PROBE" benchbar-probe "$FL_PULL_AS" 2>>"${FL_LOG_FILE:-/dev/null}" | grep '^benchbar-probe ' | tail -n1 || true)"
  if [[ -n "$out" ]]; then
    # shellcheck disable=SC2086  # "benchbar-probe OK BAD"
    set -- $out
    FL_PULL_PROBE_OK="$2"; FL_PULL_PROBE_BAD="$3"
    if [[ "$FL_PULL_PROBE_BAD" == "0" ]]; then
      fl_ok "stored passwords decrypt: ${FL_PULL_PROBE_OK} of ${FL_PULL_PROBE_OK}"
    else
      fl_pull_warn "${FL_PULL_PROBE_BAD} of $((FL_PULL_PROBE_OK + FL_PULL_PROBE_BAD)) stored passwords do not decrypt with the site's encryption_key (see docs/troubleshooting.md)"
    fi
  else
    fl_warn "the decrypt check did not run; see the log"
  fi
  if fl_bench_is_running; then
    code="$(fl_site_ping_code_for "$FL_PULL_AS")"
    if [[ "$code" == "200" ]]; then fl_ok "http://${FL_PULL_AS}:${FL_WEB_PORT} answers"; else fl_pull_warn "http://${FL_PULL_AS}:${FL_WEB_PORT} answered ${code}; run benchrestart"; fi
  else
    fl_info "the bench is stopped; benchup, then open http://${FL_PULL_AS}:${FL_WEB_PORT}"
  fi
}

# fl_pull_run_step INDEX: runs FL_PULL_STEPS[INDEX] as a numbered step
fl_pull_run_step() {
  local i="$1" id name code=0
  id="${FL_PULL_STEPS[$i]%%|*}"; name="${FL_PULL_STEPS[$i]#*|}"
  fl_step_begin "$i"
  FL_STEP_RESULT="done"
  "fl_pull_step_${id}" || code=$?
  if [[ "$code" != "0" ]]; then
    fl_step_end failed
    fl_pull_emit step ",\"n\":$((i + 1)),\"id\":$(fl_json_str "$id"),\"name\":$(fl_json_str "$name"),\"status\":\"failed\""
    return "$code"
  fi
  [[ "$FL_STEP_RESULT" == "warning" ]] && FL_STEP_RESULT="done"
  fl_step_end "$FL_STEP_RESULT"
  fl_pull_emit step ",\"n\":$((i + 1)),\"id\":$(fl_json_str "$id"),\"name\":$(fl_json_str "$name"),\"status\":$(fl_json_str "$FL_STEP_RESULT")"
}

# ---------------------------------------------------------------- command

fl_cmd_pull() {
  local i labels=() s
  if [[ "${OPT_JSON:-0}" == "1" ]]; then
    # JSON lines on stdout, everything for humans on stderr
    exec 3>&1 1>&2
  fi
  FL_PULL_ACTIVE=1
  fl_require_bench
  fl_pull_parse_args "$@"
  fl_header "benchbar pull" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "$FL_PULL_AS"
  [[ -x "${FL_BENCH_DIR}/env/bin/python" ]] || fl_die "${FL_BENCH_DIR}/env/bin/python is missing." "Run: benchbar repair --bench-dir ${FL_BENCH_DIR}"

  fl_section "CHECK"
  if [[ -n "$FL_PULL_FROM_DIR" ]]; then
    fl_pull_check_dir
    fl_ok "backup set in ${FL_PULL_FROM_DIR}: ${FL_PULL_DB}"
  else
    fl_pull_ssh_init
    fl_pull_check_remote
    if [[ -z "$FL_PULL_DB" && "$FL_PULL_NEW_BACKUP" != "1" ]]; then
      fl_die "No backup of ${FL_PULL_RSITE} in sites/${FL_PULL_RSITE}/private/backups on ${FL_PULL_HOST}." "Take one with --new-backup (writes on the server; asks for the site name), or download one and use --from-dir."
    fi
  fi
  fl_pull_diff_apps
  fl_pull_check_local
  fl_pull_plan_steps
  fl_pull_print_plan
  fl_pull_require_apps
  fl_pull_require_frappe_version
  if [[ "$FL_PULL_NEW_BACKUP" != "1" && -z "$FL_PULL_FROM_DIR" ]]; then
    s="$(fl_pull_age_hours "${FL_PULL_DB%%-*}")"
    [[ -n "$s" && "$s" -ge 48 ]] && fl_pull_warn "the latest backup is about ${s}h old; --new-backup takes a fresh one"
  fi

  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    printf '\n'
    fl_info "dry-run: nothing was downloaded, restored or written, here or on ${FL_PULL_HOST:-the server}"
    FL_PULL_DONE_SENT=1
    fl_pull_emit "done" ",\"exit\":0,\"site\":$(fl_json_str "$FL_PULL_AS"),\"dry_run\":true,\"warnings\":[${FL_PULL_WARNINGS}]"
    return 0
  fi

  [[ "$FL_PULL_NEW_BACKUP" == "1" ]] && fl_pull_gate_new_backup
  fl_pull_gate_apply

  for s in "${FL_PULL_STEPS[@]}"; do labels+=("${s#*|}"); done
  fl_steps_define "${labels[@]}"
  i=0
  while [[ "$i" -lt "${#FL_PULL_STEPS[@]}" ]]; do
    if ! fl_pull_run_step "$i"; then
      fl_steps_summary
      if [[ -d "${FL_BENCH_DIR}/sites/${FL_PULL_AS}" && "$i" -gt 0 ]]; then
        fl_info "site ${FL_PULL_AS} may be half set up; after fixing the cause run the same pull with --replace"
      fi
      exit 1
    fi
    i=$((i + 1))
  done
  fl_steps_summary
  if [[ -z "$FL_PULL_FROM_DIR" ]]; then
    fl_bstate_set PULL_SOURCE "${FL_PULL_HOST}:${FL_PULL_RSITE}"
    fl_bstate_set PULL_REMOTE_BENCH "$FL_PULL_RBENCH"
  fi
  fl_box "Pulled" \
    "site     http://${FL_PULL_AS}:${FL_WEB_PORT}  (benchup, then open it)" \
    "email    muted (mute_emails)$([[ "$FL_PULL_KEEP_SCHEDULER" == "1" ]] || printf ', scheduler paused')" \
    "default  stays ${FL_SITE}; benchbar site default ${FL_PULL_AS} changes it"
  FL_PULL_DONE_SENT=1
  fl_pull_emit "done" ",\"exit\":0,\"site\":$(fl_json_str "$FL_PULL_AS"),\"url\":$(fl_json_str "http://${FL_PULL_AS}:${FL_WEB_PORT}"),\"decrypt\":{\"ok\":$(fl_json_num "$FL_PULL_PROBE_OK"),\"failed\":$(fl_json_num "$FL_PULL_PROBE_BAD")},\"warnings\":[${FL_PULL_WARNINGS}]"
}

#!/usr/bin/env bash
#
# ci-real.sh: the steps of the real install and upgrade jobs (ci.yml, the
# "real" leg, and real-install.yml). Nothing here is mocked: it runs
# `benchbar install`, `up`, `repair` and `down` against the machine, with
# Homebrew or apt, MariaDB, Redis, launchd or systemd --user, the Keychain
# and sudo. So it is for a throwaway GitHub hosted runner only and refuses
# to start anywhere else. Never run it on your own computer.
#
#   scripts/ci-real.sh prepare            make the runner a machine without a bench
#   scripts/ci-real.sh install            benchbar install of this checkout (PROFILE, SITE)
#   scripts/ci-real.sh second-install     a second install changes no file of the bench
#   scripts/ci-real.sh serve              doctor has no FAIL, up, wait, a real request,
#                                         loopback only, status --json
#   scripts/ci-real.sh down               down, and the site no longer answers
#   scripts/ci-real.sh old-install TAG    release TAG through its own install.sh, its
#                                         bench and site, and the bench started
#   scripts/ci-real.sh update             this checkout's install.sh as an update of that CLI
#   scripts/ci-real.sh upgrade-state      the bench is still known, the notices show once
#   scripts/ci-real.sh upgrade-doctor     doctor names what repair must rewrite
#   scripts/ci-real.sh upgrade-repair     repair, restart, the site answers, loopback only
#   scripts/ci-real.sh upgrade-no-uv      macOS: a bench whose Mac has no uv
#   scripts/ci-real.sh upgrade-clean      doctor after the upgrade has no WARN but the listed ones
#   scripts/ci-real.sh logs               what helps after a failure
#
# Environment: ADMIN_PASSWORD (the site's Administrator login, a throwaway
# value of the workflow), SITE (default: the platform's default site),
# PROFILE (default: the CLI's), KNOWN_GAPS (see known_gap below; no workflow
# sets it today, so every check fails the job).
#
# A check prints "[OK]" or "[FAIL]" and the job goes on, so one run shows
# every broken check; the subcommand exits 1 at its end when one failed.

set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"

die() { printf '::error::%s\n' "$1" >&2; exit 1; }

[[ "${GITHUB_ACTIONS:-}" == "true" && "${RUNNER_ENVIRONMENT:-}" == "github-hosted" ]] ||
  die "ci-real.sh installs MariaDB and a bench on the machine it runs on: it only runs on a GitHub hosted runner"

OS="$(uname -s)"
BENCH="$HOME/frappe-bench"
case "$OS" in
  Darwin) SITE="${SITE:-macdev}" ;;
  *) SITE="${SITE:-linuxdev.localhost}" ;;
esac
WEB_PORT=8000
SOCKETIO_PORT=9000
MIRROR="${RUNNER_TEMP}/benchbar-mirror.git"
MANAGED="$HOME/.local/share/benchbar"
# The bench command of the 0.8.3 baseline on macOS, from pipx: the version the
# first green run installed, so the baseline does not move with PyPI. pipx and
# uv themselves come from Homebrew, which has no old versions to name.
BASELINE_BENCH="frappe-bench==5.31.1"
# The doctor checks that may warn after the upgrade, per platform, each with
# its reason. Anything else that is not ok fails upgrade-clean.
#   (none yet)
UPGRADE_WARN_OK_DARWIN=""
UPGRADE_WARN_OK_LINUX=""
# the CLI under test: the checkout's for a fresh install, the installed one
# (the managed checkout the one line installer made) in the upgrade jobs
if [[ -e "${RUNNER_TEMP}/ci-real-installed" ]]; then CLI="$HOME/.local/bin/benchbar"; else CLI="$ROOT/benchbar"; fi

FAILS=0
ok() { printf '[OK] %s\n' "$1"; }
bad() { printf '[FAIL] %s\n' "$1"; printf '::error::%s\n' "$1"; FAILS=$((FAILS + 1)); }
finish() { [[ "$FAILS" == 0 ]] || die "$FAILS check(s) failed in '$1' (the [FAIL] lines above)"; }
group() { printf '::group::%s\n' "$1"; }
endgroup() { printf '::endgroup::\n'; }

# known_gap ID TEXT: a check that fails for a product gap someone is fixing in
# another pull request. With ID in KNOWN_GAPS (space separated, set by the
# workflow) the failure is a warning and the job goes on; without it, it
# fails the job like any other check. gap_closed says the opposite: the check
# passes, so ID can leave KNOWN_GAPS.
known_gap() {
  case " ${KNOWN_GAPS:-} " in
    *" $1 "*) printf '[KNOWN GAP %s] %s\n' "$1" "$2"; printf '::warning title=Known gap %s::%s\n' "$1" "$2" ;;
    *) bad "$2" ;;
  esac
}
gap_closed() {
  ok "$2"
  case " ${KNOWN_GAPS:-} " in
    *" $1 "*) printf '::notice title=Gap %s is closed::%s. Remove %s from KNOWN_GAPS in the workflow.\n' "$1" "$2" "$1" ;;
  esac
}

# py CODE ARGS...: python3 with nothing of the checkout on its path
py() { python3 -I -c "$@"; }

# on_pty COMMAND...: run it with a terminal on stdin, stdout and stderr (the
# one time notices print only when stderr is a terminal), output on stdout
on_pty() {
  env -u BENCHBAR_NONINTERACTIVE -u NO_COLOR python3 -I -c '
import os, pty, sys
status = pty.spawn(sys.argv[1:])
sys.exit(os.waitstatus_to_exitcode(status))' "$@" </dev/null
}

# listen_addrs PORT: the addresses that listen on TCP PORT, one per line
listen_addrs() {
  if [[ "$OS" == Darwin ]]; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $9 }' | sort -u
  else
    ss -Hltn "sport = :$1" | awk '{ print $4 }' | sort -u
  fi
}

# exposed: the listeners on the web and socketio ports that are not on
# loopback, on one line (empty: loopback only)
exposed() {
  local port out=""
  for port in "$WEB_PORT" "$SOCKETIO_PORT"; do
    out="${out} $(listen_addrs "$port" | grep -v -E '^(127\.0\.0\.1|\[::1\]):' | tr '\n' ' ' || true)"
  done
  printf '%s' "$out" | tr -s ' ' | sed 's/^ //; s/ $//'
}

# silent_ports: the web or socketio port that has no listener at all (empty: both listen)
silent_ports() {
  local port out=""
  for port in "$WEB_PORT" "$SOCKETIO_PORT"; do
    [[ -n "$(listen_addrs "$port")" ]] || out="${out}${out:+ }${port}"
  done
  printf '%s' "$out"
}

# get URL: the body of URL on stdout, non zero when the request fails. Into a
# file first: under pipefail a reader that stops early (grep -q) would fail curl.
get() {
  local f="${RUNNER_TEMP}/ci-real-body"
  curl -fsS --max-time 30 -o "$f" "$1" 2>/dev/null || return 1
  cat "$f"
}

# wait_ping SECS: the site answers /api/method/ping by its name
wait_ping() {
  local i=0
  while [[ "$i" -lt "$1" ]]; do
    if [[ "$(get "http://${SITE}:${WEB_PORT}/api/method/ping" || true)" == *pong* ]]; then return 0; fi
    sleep 2; i=$((i + 2))
  done
  return 1
}

# doctor_json FILE: doctor --json into FILE (it exits 1 on a FAIL, which the caller reads from the file)
doctor_json() { "$CLI" doctor --json --bench-dir "$BENCH" >"$1" || true; }

# fingerprint: one line per file a second install or a repair may not change
fingerprint() {
  local f
  for f in "$BENCH/Procfile.lean" "$BENCH/benchbar-run.sh" "$BENCH"/config/benchbar-listen/* \
           "$BENCH/sites/common_site_config.json" "$BENCH/sites/$SITE/site_config.json" "$BENCH/sites/apps.txt" \
           "$HOME"/Library/LaunchAgents/com.benchbar.*.plist "$HOME"/.config/systemd/user/benchbar-*.service; do
    [[ -f "$f" ]] || continue
    printf '%s %s\n' "$(cksum <"$f" | tr ' ' '-')" "$f"
  done
  printf '%s frappe\n' "$(git -C "$BENCH/apps/frappe" rev-parse HEAD)"
}

# ---------------------------------------------------------------- prepare

# The image ships MySQL (stopped) and its /etc/mysql: mariadb-server cannot
# install over them. GitHub's Ubuntu runners boot systemd, but the runner user
# has no user manager until linger starts one (docs/DECISIONS.md, "Linux").
prepare_linux() {
  sudo systemctl stop mysql 2>/dev/null || true
  sudo apt-get purge -y 'mysql-*' >/dev/null
  sudo rm -rf /etc/mysql /var/lib/mysql
  sudo loginctl enable-linger "$USER"
  sudo systemctl start "user@$(id -u).service"
  printf 'XDG_RUNTIME_DIR=/run/user/%s\n' "$(id -u)" >>"$GITHUB_ENV"
  local i
  for i in $(seq 1 20); do
    XDG_RUNTIME_DIR="/run/user/$(id -u)" systemctl --user is-system-running >/dev/null 2>&1 && break
    sleep 1
  done
  XDG_RUNTIME_DIR="/run/user/$(id -u)" systemctl --user is-system-running || true
}

# A new Mac has no uv and no bench, and issue 112 was that path: phase 00
# installed no uv, bench came from pipx, and bench init stopped at "uv venv".
# A uv or a bench that the runner image carries would hide that again, so
# each is uninstalled where a package manager owns it and moved aside
# otherwise, until the name is gone from PATH.
prepare_macos() {
  local tool p i
  for tool in uv bench; do
    for i in 1 2 3 4 5; do
      p="$(command -v "$tool" 2>/dev/null)" || break
      printf 'the image has %s at %s: removing it\n' "$tool" "$p"
      if [[ "$tool" == uv ]] && brew list --formula uv >/dev/null 2>&1; then
        brew uninstall --ignore-dependencies uv
      elif [[ "$tool" == bench ]] && command -v pipx >/dev/null 2>&1 && [[ "$(pipx list --short 2>/dev/null)" == *frappe-bench* ]]; then
        pipx uninstall frappe-bench
      else
        sudo mv "$p" "${p}.hidden-by-ci-real"
      fi
      hash -r
      [[ "$i" != 5 ]] || die "$tool is still on PATH after five tries: $(command -v "$tool")"
    done
    ! command -v "$tool" >/dev/null 2>&1 || die "$tool is still on PATH: $(command -v "$tool")"
  done
  ok "no uv and no bench on PATH, as on a new Mac"
  sw_vers
  brew --version | head -n 1
}

cmd_prepare() {
  [[ ! -e "$BENCH" ]] || die "$BENCH exists already: this is not a fresh runner"
  if [[ "$OS" == Darwin ]]; then prepare_macos; else prepare_linux; fi
}

# ---------------------------------------------------------------- a fresh install

cmd_install() {
  local args=(install --yes --site "$SITE")
  [[ -z "${PROFILE:-}" ]] || args+=(--profile "$PROFILE")
  "$CLI" "${args[@]}"
}

cmd_second_install() {
  local args=(install --yes --site "$SITE") before after
  [[ -z "${PROFILE:-}" ]] || args+=(--profile "$PROFILE")
  before="$(fingerprint)"
  "$CLI" "${args[@]}"
  after="$(fingerprint)"
  if [[ "$before" == "$after" ]]; then
    ok "the second install changed no service file, no site config and no app ($(printf '%s\n' "$before" | grep -c .) files)"
  else
    bad "the second install changed files of the bench"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true
  fi
  finish second-install
}

# loopback_check WHAT: both ports have a listener and none is off loopback
loopback_check() {
  local e silent
  e="$(exposed)"; silent="$(silent_ports)"
  if [[ -n "$silent" ]]; then bad "$1: nothing listens on port(s) ${silent}"
  elif [[ -n "$e" ]]; then bad "$1: the web server or socketio listens on ${e}, not on 127.0.0.1 only"
  else ok "$1: the web server and socketio listen on loopback only"; fi
}

# doctor_no_fail FILE WHAT
doctor_no_fail() {
  local fails
  fails="$(py 'import json, sys
for c in json.load(open(sys.argv[1]))["checks"]:
    if c["status"] == "fail":
        print("%s: %s" % (c["id"], c["message"]))' "$1")"
  if [[ -z "$fails" ]]; then ok "$2: doctor --json has no FAIL"; else bad "$2: doctor --json has a FAIL: ${fails}"; fi
}

cmd_serve() {
  local d="${RUNNER_TEMP}/doctor.json" s="${RUNNER_TEMP}/status.json"
  doctor_json "$d"
  doctor_no_fail "$d" "before the first start"

  "$CLI" up --bench-dir "$BENCH"
  if "$CLI" wait --timeout 180 --bench-dir "$BENCH"; then ok "benchbar wait: the bench is ready"; else bad "benchbar wait: not ready after 180 s"; fi
  if wait_ping 60; then ok "http://${SITE}:${WEB_PORT}/api/method/ping answers pong"; else bad "no pong from http://${SITE}:${WEB_PORT}/api/method/ping"; fi
  # a page, not only the ping: the login page is rendered from the site's database and the built assets
  local page
  page="$(get "http://${SITE}:${WEB_PORT}/login" || true)"
  if [[ "$page" == *"<html"* || "$page" == *"<HTML"* ]]; then ok "the login page renders"; else bad "http://${SITE}:${WEB_PORT}/login is not a page"; fi

  loopback_check "after up"
  doctor_json "$d"
  doctor_no_fail "$d" "while it runs"
  if py 'import json, sys
c = [x for x in json.load(open(sys.argv[1]))["checks"] if x["id"] == "bench_listen"][0]
sys.exit(0 if c["status"] == "ok" else 1)' "$d"; then ok "doctor: bench_listen is ok"; else bad "doctor: bench_listen is not ok"; fi

  "$CLI" status --json --bench-dir "$BENCH" | tee "$s"; printf '\n'
  if py 'import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d["state"] == "running" and d["web_ping_code"] == 200 else 1)' "$s"; then ok "status --json: running, ping 200"; else bad "status --json is not running with ping 200"; fi
  "$CLI" repair --dry-run --bench-dir "$BENCH"
  finish serve
}

cmd_down() {
  "$CLI" down --bench-dir "$BENCH"
  if curl -fsS --max-time 3 "http://${SITE}:${WEB_PORT}/api/method/ping" >/dev/null 2>&1; then bad "the site still answers after down"; else ok "the site no longer answers after down"; fi
  finish down
}

# ---------------------------------------------------------------- the upgrade

# The release the way a person got it: its own install.sh, which clones the
# CLI into ~/.local/share/benchbar from the branch main and links it into
# ~/.local/bin. The clone comes from a mirror of this checkout whose main is
# the release tag, because GitHub's main moves with every release; an update
# is then what it is for a person, a pull of main.
cmd_old_install() {
  local tag="${1:?old-install needs a tag}" old
  git -C "$ROOT" rev-parse -q --verify "${tag}^{commit}" >/dev/null || die "no tag ${tag} in the checkout (fetch-depth: 0 fetches the tags)"
  git clone --quiet --bare "$ROOT" "$MIRROR"
  git -C "$MIRROR" update-ref refs/heads/main "$(git -C "$ROOT" rev-parse "${tag}^{commit}")"
  git -C "$MIRROR" symbolic-ref HEAD refs/heads/main
  git -C "$MIRROR" show "${tag}:install.sh" >"${RUNNER_TEMP}/install-${tag}.sh"

  group "install.sh of ${tag}"
  BENCHBAR_REPO="$MIRROR" BENCHBAR_NONINTERACTIVE=1 bash "${RUNNER_TEMP}/install-${tag}.sh" --yes --no-app
  endgroup
  old="$HOME/.local/bin/benchbar"
  [[ -x "$old" ]] || die "install.sh of ${tag} left no ${old}"
  [[ "$(git -C "$MANAGED" rev-parse HEAD)" == "$(git -C "$ROOT" rev-parse "${tag}^{commit}")" ]] || die "${MANAGED} is not at ${tag}"
  "$old" --version
  : >"${RUNNER_TEMP}/ci-real-installed"

  # macOS: the Mac of the uv gap (upgrade-no-uv) has bench from pipx, as every
  # Mac had that installed before uv was the default, so bench comes from
  # pipx here. Release 0.8.3 installs no uv and today's bench init needs one
  # (issue 112), so the job lends it one for the install and takes it away
  # again in upgrade-no-uv.
  if [[ "$OS" == Darwin ]]; then
    local bindir
    command -v pipx >/dev/null 2>&1 || HOMEBREW_NO_AUTO_UPDATE=1 brew install pipx
    HOMEBREW_NO_AUTO_UPDATE=1 brew install uv
    pipx install "$BASELINE_BENCH"
    bindir="$(pipx environment --value PIPX_BIN_DIR)"
    export PATH="${bindir}:$PATH"
    printf '%s\n' "$bindir" >>"$GITHUB_PATH"
    command -v bench >/dev/null 2>&1 || die "pipx installed no bench into ${bindir}"
  fi

  group "benchbar install (${tag})"
  "$old" install --yes --site "$SITE"
  endgroup
  group "benchbar up (${tag})"
  "$old" up
  endgroup
  wait_ping 180 || die "the ${tag} bench does not answer"
  ok "the ${tag} bench answers at http://${SITE}:${WEB_PORT}"
  # what the upgrade has to change: before 0.9.0 the dev server listened on every interface
  printf 'listeners before the update: %s %s\n' "$(listen_addrs "$WEB_PORT" | tr '\n' ' ')" "$(listen_addrs "$SOCKETIO_PORT" | tr '\n' ' ')"
  [[ -n "$(exposed)" ]] || die "the ${tag} bench already listens on loopback only: this job no longer tests the change of 0.9.0"
}

# The update: main of the mirror moves to the commit under test and the new
# install.sh runs as `benchbar self-update` and the app's Update Now run it
# (--yes on a machine that has the CLI: a pull, no bench is touched).
cmd_update() {
  local sha
  sha="$(git -C "$ROOT" rev-parse HEAD)"
  git -C "$MIRROR" fetch --quiet "$ROOT" HEAD
  git -C "$MIRROR" update-ref refs/heads/main "$sha"
  BENCHBAR_REPO="$MIRROR" BENCHBAR_NONINTERACTIVE=1 bash "$ROOT/install.sh" --yes --no-app
  [[ "$(git -C "$MANAGED" rev-parse HEAD)" == "$sha" ]] || die "${MANAGED} is not at the commit under test (${sha})"
  ok "the installed CLI is the commit under test (${sha:0:9}, $("$CLI" --version))"
}

cmd_upgrade_state() {
  local s="${RUNNER_TEMP}/status.json" state_dir out
  # the first command of the new CLI: the app's would be this one
  "$CLI" status --json --bench-dir "$BENCH" | tee "$s"; printf '\n'
  if py 'import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d["state"] == "running" and d["web_ping_code"] == 200 else 1)' "$s"; then ok "the bench of the old release is still known and running after the update"; else bad "status --json after the update is not running with ping 200"; fi
  if py 'import json, sys
ids = [n["id"] for n in json.load(open(sys.argv[1])).get("notices", [])]
sys.exit(0 if "listen-local" in ids else 1)' "$s"; then ok "status --json carries the notice listen-local"; else bad "status --json has no notice listen-local after the update"; fi
  out="$("$CLI" list --json)"
  if [[ "$out" == *"\"${BENCH}\""* ]]; then ok "list --json names ${BENCH}"; else bad "list --json does not name ${BENCH}"; fi

  state_dir="$("$CLI" where --json | py 'import json, sys; print(json.load(sys.stdin)["state_dir"])')"
  if grep -q '^LAST_VERSION=' "${state_dir}/state.env"; then ok "the state file records the version (LAST_VERSION)"; else bad "${state_dir}/state.env has no LAST_VERSION after a command that ended well"; fi

  # in a terminal the notices print once, and not again
  out="$(on_pty "$CLI" list 2>&1 || true)"
  if [[ "$out" == *'This is shown once'* && "$out" == *'The bench now listens on this computer only'* ]]; then ok "the first command in a terminal prints the notices"; else bad "the first command in a terminal did not print the notices"; printf '%s\n' "$out"; fi
  out="$(on_pty "$CLI" list 2>&1 || true)"
  if [[ "$out" == *'This is shown once'* ]]; then bad "the second command in a terminal printed the notices again"; else ok "the second command in a terminal does not print them again"; fi
  out="$("$CLI" notices --json)"
  if [[ "$out" == *'"id":"listen-local"'* ]]; then ok "benchbar notices still lists them (until dismissed)"; else bad "benchbar notices --json does not list listen-local"; fi
  finish upgrade-state
}

# check_field FILE ID FIELD: one field of a doctor check
check_field() {
  py 'import json, sys
for c in json.load(open(sys.argv[1]))["checks"]:
    if c["id"] == sys.argv[2]:
        print(c.get(sys.argv[3]) or "")' "$1" "$2" "$3"
}

cmd_upgrade_doctor() {
  local d="${RUNNER_TEMP}/doctor.json" id want out
  doctor_json "$d"
  "$CLI" doctor --bench-dir "$BENCH" || true
  # the three service files are from the old release: each is named, with the repair action that rewrites it
  for id in procfile:write_procfile runner:write_runner agent:write_plist; do
    want="${id#*:}"; id="${id%%:*}"
    if [[ "$(check_field "$d" "$id" status)" == warn && "$(check_field "$d" "$id" action)" == "$want" ]]; then
      ok "doctor: ${id} is a WARN with the action ${want}"
    else
      bad "doctor: ${id} is '$(check_field "$d" "$id" status)' with the action '$(check_field "$d" "$id" action)', expected warn and ${want}"
    fi
  done
  if [[ "$(check_field "$d" bench_listen status)" == warn ]]; then ok "doctor: bench_listen warns ($(check_field "$d" bench_listen message))"; else bad "doctor: bench_listen does not warn about a bench that binds every interface"; fi
  if [[ -n "$(exposed)" ]]; then ok "the running bench still listens on every interface, as the notice says"; else bad "the running bench listens on loopback before any repair or restart"; fi
  out="$("$CLI" repair --dry-run --bench-dir "$BENCH" 2>&1)"; printf '%s\n' "$out"
  if [[ "$out" == *Procfile.lean* ]]; then ok "repair --dry-run plans Procfile.lean"; else bad "repair --dry-run does not plan Procfile.lean"; fi

  # Known gap listen-restart: a bench from before 0.9.0 binds every interface at
  # each start until its Procfile.lean is the new one. A restart (and an up) has
  # to deal with that, not only doctor: it writes the file again itself, so the
  # bench comes back on loopback, or at least it names the repair to run.
  out="$("$CLI" restart --for-agent --bench-dir "$BENCH" 2>&1 || true)"; printf '%s\n' "$out"
  wait_ping 180 || bad "the bench does not answer after restart (before repair)"
  # warnings[] and next_actions[] of the done line only: its state_after carries the notices, which name repair
  if [[ -z "$(exposed)" && -z "$(silent_ports)" ]]; then
    gap_closed listen-restart "after a restart the bench from before 0.9.0 listens on loopback only"
  elif printf '%s\n' "$out" | py 'import json, sys
for line in sys.stdin:
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if not isinstance(d, dict) or d.get("event") != "done":
        continue
    said = json.dumps(d.get("warnings", [])) + json.dumps(d.get("next_actions", []))
    sys.exit(0 if "repair" in said else 1)
sys.exit(1)'; then
    gap_closed listen-restart "restart on a bench from before 0.9.0 names benchbar repair"
  else
    known_gap listen-restart "restart on a bench from before 0.9.0 leaves it on every interface ($(exposed)) and names no repair"
  fi
  finish upgrade-doctor
}

cmd_upgrade_repair() {
  local d="${RUNNER_TEMP}/doctor.json" id f
  "$CLI" repair --yes --bench-dir "$BENCH"
  doctor_json "$d"
  for id in procfile runner agent; do
    if [[ "$(check_field "$d" "$id" status)" == ok ]]; then ok "after repair: ${id} is current"; else bad "after repair: ${id} is '$(check_field "$d" "$id" status)' ($(check_field "$d" "$id" message))"; fi
  done
  for f in "$BENCH/config/benchbar-listen/sitecustomize.py" "$BENCH/config/benchbar-listen/socketio.js"; do
    if [[ -s "$f" ]]; then ok "repair wrote ${f#"$BENCH"/}"; else bad "repair did not write ${f#"$BENCH"/}"; fi
  done
  if grep -q 'config/benchbar-listen' "$BENCH/Procfile.lean"; then ok "Procfile.lean starts the web server and socketio with the listen files"; else bad "Procfile.lean does not name config/benchbar-listen"; fi

  # repair never restarts a bench by itself where it can avoid it: the restart is the person's step
  "$CLI" restart --bench-dir "$BENCH"
  if "$CLI" wait --timeout 180 --bench-dir "$BENCH"; then ok "benchbar wait: the bench is ready after repair and restart"; else bad "benchbar wait: not ready after repair and restart"; fi
  if wait_ping 60; then ok "the site answers after the upgrade"; else bad "the site does not answer after the upgrade"; fi
  loopback_check "after repair and restart"
  doctor_json "$d"
  doctor_no_fail "$d" "after the upgrade"
  if [[ "$(check_field "$d" bench_listen status)" == ok ]]; then ok "doctor: bench_listen is ok"; else bad "doctor: bench_listen is '$(check_field "$d" bench_listen status)' ($(check_field "$d" bench_listen message))"; fi
  cp "$d" "${RUNNER_TEMP}/doctor-after-upgrade.json"
  finish upgrade-repair
}

# After repair and a restart the upgraded bench is as good as a new one: no
# check of doctor is left at WARN or FAIL, but the ones listed above for the
# platform. Read from the doctor run upgrade-repair ended with.
cmd_upgrade_clean() {
  local d="${RUNNER_TEMP}/doctor-after-upgrade.json" allowed left
  if [[ "$OS" == Darwin ]]; then allowed="$UPGRADE_WARN_OK_DARWIN"; else allowed="$UPGRADE_WARN_OK_LINUX"; fi
  [[ -s "$d" ]] || die "no doctor run of upgrade-repair to read (${d})"
  left="$(py 'import json, sys
allowed = sys.argv[2].split()
for c in json.load(open(sys.argv[1]))["checks"]:
    if c["status"] != "ok" and c["id"] not in allowed:
        print("%s (%s): %s" % (c["id"], c["status"], c["message"]))' "$d" "$allowed")"
  if [[ -z "$left" ]]; then
    ok "doctor after the upgrade: every check is ok${allowed:+, but the allowed ${allowed}}"
  else
    while IFS= read -r line; do bad "doctor after the upgrade: ${line}"; done <<<"$left"
  fi
  finish upgrade-clean
}

# Known gap uv-missing (macOS). A Mac whose bench was made before
# frappe-bench 5.31 has bench from pipx and no uv, and today's bench runs
# "uv venv" and "uv pip": an env rebuild in repair and app add fail there.
# Phase 00 is the only code that installs uv, and it runs for install only.
# The job has needed uv until here (old-install); it is removed now, the env
# is moved aside as a cleanup tool leaves it, and doctor and repair have to
# cope: doctor names uv, and repair brings the env back.
cmd_upgrade_no_uv() {
  [[ "$OS" == Darwin ]] || { ok "not macOS: phase 00 on Linux installs uv itself"; return 0; }
  local d="${RUNNER_TEMP}/doctor.json" named
  "$CLI" down --bench-dir "$BENCH"
  HOMEBREW_NO_AUTO_UPDATE=1 brew uninstall --ignore-dependencies uv
  hash -r
  ! command -v uv >/dev/null 2>&1 || die "uv is still on PATH: $(command -v uv)"

  doctor_json "$d"
  named="$(py 'import json, re, sys
for c in json.load(open(sys.argv[1]))["checks"]:
    if c["status"] != "ok" and re.search(r"\buv\b", (c.get("message") or "") + " " + (c.get("fix") or "")):
        print(c["id"])' "$d" | tr '\n' ' ')"
  if [[ -n "$named" ]]; then gap_closed uv-missing "doctor names the missing uv (${named% })"; else known_gap uv-missing "doctor has no check that names the missing uv on macOS"; fi

  mv "$BENCH/env" "$BENCH/env.moved-by-ci-real"
  if "$CLI" repair --yes --bench-dir "$BENCH" && [[ -x "$BENCH/env/bin/python" ]]; then
    gap_closed uv-missing "repair rebuilt env on a Mac that had no uv"
    "$CLI" up --bench-dir "$BENCH"
    if wait_ping 180; then ok "the site answers from the rebuilt env"; else bad "the site does not answer from the rebuilt env"; fi
    "$CLI" down --bench-dir "$BENCH"
  else
    known_gap uv-missing "repair cannot rebuild env on a Mac that has no uv (bench runs uv venv)"
  fi
  finish upgrade-no-uv
}

# ---------------------------------------------------------------- logs

cmd_logs() {
  local state="$HOME/.local/state/benchbar" f
  set +e
  "$CLI" status --json --bench-dir "$BENCH"; printf '\n'
  cat "${RUNNER_TEMP}/doctor.json" 2>/dev/null; printf '\n'
  if [[ "$OS" == Darwin ]]; then
    launchctl print "gui/$(id -u)" | grep -i benchbar
    lsof -nP -iTCP -sTCP:LISTEN
    brew services list
  else
    systemctl --user status 'benchbar-*' --no-pager
    journalctl --user --no-pager -n 200
    ss -Hltn
  fi
  ls -la "$state/logs"
  for f in "$state"/logs/*.log; do printf '\n==> %s\n' "$f"; tail -n 150 "$f"; done
  printf '\n==> bench.log\n'; tail -n 150 "$BENCH/logs/bench.log"
  return 0
}

case "${1:-}" in
  prepare) cmd_prepare ;;
  install) cmd_install ;;
  second-install) cmd_second_install ;;
  serve) cmd_serve ;;
  down) cmd_down ;;
  old-install) cmd_old_install "${2:-}" ;;
  update) cmd_update ;;
  upgrade-state) cmd_upgrade_state ;;
  upgrade-doctor) cmd_upgrade_doctor ;;
  upgrade-repair) cmd_upgrade_repair ;;
  upgrade-no-uv) cmd_upgrade_no_uv ;;
  upgrade-clean) cmd_upgrade_clean ;;
  logs) cmd_logs ;;
  *) die "usage: ci-real.sh prepare|install|second-install|serve|down|old-install TAG|update|upgrade-state|upgrade-doctor|upgrade-repair|upgrade-no-uv|upgrade-clean|logs" ;;
esac

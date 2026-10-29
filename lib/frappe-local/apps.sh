#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# apps.sh: the apps of a bench.
#
#   benchbar app list [--json] [--no-sites]
#   benchbar app add NAME|URL [--branch B] [--name N] [--site S | --all-sites]
#   benchbar app install NAME --site S
#   benchbar app update NAME [--skip-backup] [--dry-run --json]
#   benchbar app focus [NAME] | app unfocus NAME   (freshness.sh)
#
# Apps come from bench itself (get-app, install-app, migrate, build); git
# is only used to read an app and to fast forward it. Nothing here ever
# runs bench update, get-app --overwrite or --resolve-deps, drops a site
# or deletes a folder: a half cloned app is moved to the backups.

# ---------------------------------------------------------------- reading

fl_app_path() { printf '%s/apps/%s' "$FL_BENCH_DIR" "$1"; }
fl_app_git() { local app="$1"; shift; git -C "$(fl_app_path "$app")" "$@"; }

# sites/apps.txt, one app per line, in order
fl_apps_txt() {
  local f="${FL_BENCH_DIR}/sites/apps.txt"
  [[ -f "$f" ]] || return 0
  tr -d '\r' <"$f" | awk '{gsub(/^[ \t]+|[ \t]+$/, "")} NF && !seen[$0]++'
}

fl_app_in_apps_txt() { fl_apps_txt | grep -qxF "$1"; }

# A git app: apps/X with a .git and a Python package (stray files and
# tarballs in apps/ are not apps).
fl_app_is_git_app() {
  local d
  d="$(fl_app_path "$1")"
  [[ -e "$d/.git" ]] || return 1
  [[ -f "$d/pyproject.toml" || -f "$d/setup.py" || -f "$d/$1/__init__.py" ]]
}

# git apps that are not in apps.txt
fl_apps_unlisted() {
  local d n listed
  listed="$(fl_apps_txt)"
  for d in "${FL_BENCH_DIR}"/apps/*/; do
    [[ -d "$d" ]] || continue
    n="$(basename "$d")"
    fl_app_is_git_app "$n" || continue
    printf '%s\n' "$listed" | grep -qxF "$n" || printf '%s\n' "$n"
  done
}

fl_apps_all() { fl_apps_txt; fl_apps_unlisted; }

# The folder in apps/ that holds NAME, compared without case (a repo named
# Raven is the app raven), or nothing.
fl_app_existing_dir() {
  local want d n
  want="$(printf '%s' "$1" | tr '[:upper:]-' '[:lower:]_')"
  for d in "${FL_BENCH_DIR}"/apps/*/; do
    [[ -d "$d" ]] || continue
    n="$(basename "$d")"
    [[ "$(printf '%s' "$n" | tr '[:upper:]-' '[:lower:]_')" == "$want" ]] && { printf '%s' "$n"; return 0; }
  done
  return 0
}

fl_app_has_git() { [[ -e "$(fl_app_path "$1")/.git" ]]; }
fl_app_branch() { fl_app_has_git "$1" || return 0; fl_app_git "$1" symbolic-ref --short -q HEAD 2>/dev/null || true; }
fl_app_commit() { fl_app_has_git "$1" || return 0; fl_app_git "$1" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || true; }
fl_app_dirty() { fl_app_has_git "$1" && [[ -n "$(fl_app_git "$1" status --porcelain -uno 2>/dev/null || true)" ]]; }
fl_app_shallow() { fl_app_has_git "$1" && [[ "$(fl_app_git "$1" rev-parse --is-shallow-repository 2>/dev/null || true)" == "true" ]]; }

# The remote an app follows, in bench's order: the branch's remote, else
# upstream, else the first one.
fl_app_remote() {
  local app="$1" b r="" remotes
  fl_app_has_git "$app" || return 0
  b="$(fl_app_branch "$app")"
  [[ -n "$b" ]] && r="$(fl_app_git "$app" config --get "branch.${b}.remote" 2>/dev/null || true)"
  if [[ -z "$r" || "$r" == "." ]]; then
    remotes="$(fl_app_git "$app" remote 2>/dev/null || true)"
    if printf '%s\n' "$remotes" | grep -qx upstream; then r=upstream; else r="$(printf '%s\n' "$remotes" | head -n1)"; fi
  fi
  printf '%s' "$r"
}

# https://user:token@host/x -> https://host/x (never shown, never written)
fl_url_strip_userinfo() { printf '%s' "$1" | sed -E 's#^(https?://)[^/@]*@#\1#'; }

fl_app_remote_url() {
  local app="$1" r
  r="$(fl_app_remote "$app")"
  [[ -n "$r" ]] || return 0
  fl_url_strip_userinfo "$(fl_app_git "$app" remote get-url "$r" 2>/dev/null || true)"
}

# The version bench recorded in sites/apps.json for APP.
fl_app_json_version() {
  local f="${FL_BENCH_DIR}/sites/apps.json"
  [[ -f "$f" ]] || return 0
  awk -v a="\"$1\"" '
    index($0, a) && /:[ \t]*\{/ { f = 1; next }
    f && /"version"/ { v = $0; sub(/.*"version"[ \t]*:[ \t]*"/, "", v); sub(/".*/, "", v); print v; exit }
    f && /^[ \t]?\}/ { exit }' "$f"
}

# The branch config/apps.tsv (or the profile, for frappe) wants for APP.
fl_app_policy_branch() {
  local policy
  if [[ "$1" == "frappe" ]]; then printf '%s' "$FL_FRAPPE_BRANCH"; return 0; fi
  policy="$(fl_lookup_app_policy "$1" "$FL_PROFILE" 2>/dev/null || true)"
  printf '%s' "${policy%%|*}"
}

# required_apps from the app's hooks.py, read like bench does (a Python
# list of strings; "org/app" entries count as "app"), frappe left out.
fl_app_required_apps() { local f; f="$(fl_app_hooks_file "$1")" && fl_hooks_required_apps "$f"; return 0; }

# fl_app_hooks_file APP: apps/APP/<package>/hooks.py. The folder and the
# package can differ (apps/Raven holds raven), so like the app add plan:
# the folder's own name, its lower case form, else the one package there.
fl_app_hooks_file() {
  local d f lower
  d="$(fl_app_path "$1")"
  lower="$(printf '%s' "$1" | tr '[:upper:]-' '[:lower:]_')"
  for f in "$d/$1/hooks.py" "$d/${lower}/hooks.py"; do [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }; done
  for f in "$d"/*/hooks.py; do [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }; done
  return 1
}

# fl_hooks_required_apps FILE: the same read from any hooks.py
fl_hooks_required_apps() {
  local hooks="$1"
  [[ -f "$hooks" ]] || return 0
  awk '
    /^[ \t]*required_apps[ \t]*=/ { f = 1 }
    f { buf = buf " " $0; if (index($0, "]")) exit }
    END {
      while (match(buf, /["\047][^"\047]+["\047]/)) {
        v = substr(buf, RSTART + 1, RLENGTH - 2); buf = substr(buf, RSTART + RLENGTH)
        n = split(v, parts, "/"); v = parts[n]
        if (v != "frappe") print v
      }
    }' "$hooks"
}

# ---------------------------------------------------------------- site app lists
#
# Which apps a site has comes from "bench --site S list-apps --format json",
# which needs MariaDB. The answer is cached next to the bench's state file,
# so doctor, lock check and "app list --no-sites" never touch the database.

fl_site_apps_cache_file() {
  local f
  f="$(fl_bench_state_file_for "$FL_BENCH_DIR")"
  printf '%s.site-apps' "${f%.env}"
}

# fl_site_apps_live SITE: the site's apps, space separated; 1 when bench
# could not tell (MariaDB down, a broken site).
fl_site_apps_live() {
  local out err code=0 apps
  out="$(mktemp "${TMPDIR:-/tmp}/benchbar-apps.XXXXXX")"
  err="$(mktemp "${TMPDIR:-/tmp}/benchbar-apps.XXXXXX")"
  fl_run_capture_timeout "${FL_LIST_APPS_TIMEOUT:-15}" "$out" "$err" fl__in_dir "$FL_BENCH_DIR" bench --site "$1" list-apps --format json || code=$?
  fl_log_file_append "$err"
  rm -f "$err"
  if [[ "$code" != "0" ]] || ! grep -q '{' "$out"; then rm -f "$out"; return 1; fi
  # {"site": ["frappe", "erpnext"]}: the quoted names after the first colon
  apps="$(tr -d '\n' <"$out" | sed 's/^[^{]*{[^:]*://' | grep -o '"[^"]*"' | tr -d '"' | tr '\n' ' ')"
  rm -f "$out"
  printf '%s' "${apps% }"
}

# fl_site_apps_refresh [SITE...]: asks bench for every site (or the given
# ones) and rewrites the cache; other sites keep their cached line.
FL_SITE_APPS_ERROR=""
fl_site_apps_refresh() {
  local file tmp s apps sites=() errors=""
  file="$(fl_site_apps_cache_file)"
  if [[ "$#" -gt 0 ]]; then sites=("$@"); else while IFS= read -r s; do [[ -n "$s" ]] && sites+=("$s"); done < <(fl_sites_list); fi
  fl_bench_env_exports
  tmp="$(mktemp "${TMPDIR:-/tmp}/benchbar-siteapps.XXXXXX")"
  printf '@checked_at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$tmp"
  for s in ${sites[@]+"${sites[@]}"}; do
    if apps="$(fl_site_apps_live "$s")"; then
      printf '%s %s\n' "$s" "$apps" >>"$tmp"
    else
      errors="${errors}${errors:+, }${s}"
      # keep what was known
      [[ -f "$file" ]] && grep "^${s} " "$file" >>"$tmp" 2>/dev/null || true
    fi
  done
  # sites not asked this time keep their line
  if [[ -f "$file" ]]; then
    # a cache with only @ lines (no site yet, or every read failed) is fine:
    # grep finding nothing must not end the run under pipefail
    { grep -v '^@' "$file" 2>/dev/null || true; } | while read -r s apps; do
      case " ${sites[*]:-} " in *" $s "*) ;; *) printf '%s %s\n' "$s" "$apps" ;; esac
    done >>"$tmp"
  fi
  FL_SITE_APPS_ERROR=""
  [[ -n "$errors" ]] && FL_SITE_APPS_ERROR="bench list-apps failed for ${errors} (is MariaDB running?)"
  [[ -n "$FL_SITE_APPS_ERROR" ]] && printf '@error %s\n' "$FL_SITE_APPS_ERROR" >>"$tmp"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    FL_SITE_APPS_DRY="$tmp"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  mv "$tmp" "$file"
}

fl__site_apps_source() {
  if [[ -n "${FL_SITE_APPS_DRY:-}" && -f "$FL_SITE_APPS_DRY" ]]; then printf '%s' "$FL_SITE_APPS_DRY"; else fl_site_apps_cache_file; fi
}

# fl_site_apps_cached SITE: the cached list; 1 when the site was never read
fl_site_apps_cached() {
  local file line
  file="$(fl__site_apps_source)"
  [[ -f "$file" ]] || return 1
  line="$(grep "^$1 " "$file" 2>/dev/null | head -n1)" || return 1
  printf '%s' "${line#* }"
}

fl_site_apps_meta() {
  local file
  file="$(fl__site_apps_source)"
  [[ -f "$file" ]] || return 0
  sed -n "s/^@$1 //p" "$file" | head -n1
}

fl_site_has_app() {
  local apps
  apps="$(fl_site_apps_cached "$1")" || return 1
  case " $apps " in *" $2 "*) return 0 ;; esac
  return 1
}

# the sites (from the cache) that have APP, space separated
fl_app_sites() {
  local s out=""
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    fl_site_has_app "$s" "$1" && out="${out}${out:+ }${s}"
  done < <(fl_sites_list)
  printf '%s' "$out"
}

# ---------------------------------------------------------------- app list

fl_json_str_array() {
  local x sep=""
  printf '['
  for x in "$@"; do printf '%s"%s"' "$sep" "$(fl_json_escape "$x")"; sep=","; done
  printf ']'
}

fl_cmd_app_list() {
  local no_sites=0 a app sep="" rows=() branch commit dirty sites listed policy
  for a in "$@"; do
    case "$a" in
      --no-sites) no_sites=1 ;;
      --json) OPT_JSON=1 ;;
      *) fl_die "Unknown option for app list: $a" "Use: benchbar app list [--json] [--no-sites]" ;;
    esac
  done
  fl_require_bench
  [[ "$no_sites" == "1" ]] || fl_site_apps_refresh
  if [[ "$OPT_JSON" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"profile":%s,"sites_checked_at":%s,"sites_error":%s,"apps":[' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$FL_PROFILE")" \
      "$(fl_json_str "$(fl_site_apps_meta checked_at)")" "$(fl_json_str "$(fl_site_apps_meta error)")"
    FL_FRESHNESS_READY=""; fl_freshness_prepare
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      listed=0; fl_app_in_apps_txt "$app" && listed=1
      dirty=0; fl_app_dirty "$app" && dirty=1
      # shellcheck disable=SC2046  # the site names are words
      printf '%s{"name":%s,"in_apps_txt":%s,"repo":%s,"remote":%s,"branch":%s,"policy_branch":%s,"commit":%s,"dirty":%s,"shallow":%s,"version":%s,"sites":%s,%s}' \
        "$sep" "$(fl_json_str "$app")" "$(fl_json_bool "$listed")" "$(fl_json_str "$(fl_app_remote_url "$app")")" \
        "$(fl_json_str "$(fl_app_remote "$app")")" "$(fl_json_str "$(fl_app_branch "$app")")" \
        "$(fl_json_str "$(fl_app_policy_branch "$app")")" "$(fl_json_str "$(fl_app_commit "$app")")" \
        "$(fl_json_bool "$dirty")" "$(fl_json_bool "$(fl_app_shallow "$app" && printf 1 || printf 0)")" \
        "$(fl_json_str "$(fl_app_json_version "$app")")" "$(fl_json_str_array $(fl_app_sites "$app"))" "$(fl_freshness_app_json "$app")"
      sep=","
    done < <(fl_apps_all)
    printf ']}\n'
    return 0
  fi
  rows+=("App|Branch|Commit|Policy|Version|Sites")
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    branch="$(fl_app_branch "$app")"; commit="$(fl_app_commit "$app")"
    fl_app_has_git "$app" && [[ -z "$branch" ]] && branch="(detached)"
    fl_app_dirty "$app" && branch="${branch} *"
    fl_app_in_apps_txt "$app" || branch="${branch} (not in apps.txt)"
    policy="$(fl_app_policy_branch "$app")"
    sites="$(fl_app_sites "$app")"
    rows+=("${app}|${branch:--}|${commit:0:7}|${policy:--}|$(fl_app_json_version "$app")|${sites:--}")
  done < <(fl_apps_all)
  fl_table "${rows[@]}"
  [[ -n "$(fl_site_apps_meta error)" ]] && fl_warn "$(fl_site_apps_meta error); sites shown from the last good read"
  printf '  %s* local changes%s\n' "$FL_DIM" "$FL_RESET"
}

# ---------------------------------------------------------------- remote access

fl_is_url() {
  case "$1" in
    *://*|*@*:*|/*|./*|../*|*.git) return 0 ;;
  esac
  return 1
}

# the app name a repo URL gives: its last path part, without .git, lower case
fl_app_name_from_url() {
  local n="${1%/}"
  n="${n%.git}"; n="${n##*/}"; n="${n##*:}"
  printf '%s' "$n" | tr '[:upper:]-' '[:lower:]_'
}

# git that never prompts: a missing key or token fails at once
fl_git_batch() { env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' git "$@"; }

fl_url_is_ssh() {
  case "$1" in
    ssh://*) return 0 ;;
    *://*) return 1 ;;
    *@*:*) return 0 ;;
  esac
  return 1
}

# The fix lines for a repo git cannot read (private, no key, no token).
fl_repo_access_hint() {
  local repo="$1" host
  if fl_url_is_ssh "$repo"; then
    host="$(printf '%s' "$repo" | sed -E 's#^ssh://##; s#^[^@]*@##; s#[:/].*##')"
    fl_fix "ssh -T git@${host}   (checks the key; for a host alias from ~/.ssh/config use the alias)"
    if fl_is_linux; then
      fl_fix "ssh-add ~/.ssh/id_ed25519   (loads the key into the agent)"
    else
      fl_fix "ssh-add --apple-use-keychain ~/.ssh/id_ed25519   (loads the key into the agent)"
    fi
  else
    fl_fix "use the SSH URL instead (git@HOST:OWNER/REPO.git), or let git use your GitHub login: gh auth setup-git"
  fi
}

# fl_repo_preflight REPO BRANCH: 0 when the branch (or tag) exists and the
# repo is readable without a prompt; prints the reason and a fix otherwise.
fl_repo_preflight() {
  local repo="$1" branch="$2" code=0 err heads
  err="$(mktemp "${TMPDIR:-/tmp}/benchbar-lsremote.XXXXXX")"
  fl_git_batch ls-remote --exit-code --heads --tags -- "$repo" "$branch" >/dev/null 2>"$err" || code=$?
  fl_log_file_append "$err"
  if [[ "$code" == "0" ]]; then rm -f "$err"; return 0; fi
  if [[ "$code" == "2" ]]; then
    rm -f "$err"
    heads="$(fl_git_batch ls-remote --heads -- "$repo" 2>/dev/null | sed 's#.*refs/heads/##' | head -n 20 | tr '\n' ' ')"
    fl_fail "branch ${branch} not found in ${repo}"
    fl_note "remote branches: ${heads:-none}"
    fl_fix "pass one of them with --branch"
    return 1
  fi
  fl_fail "cannot read ${repo} (git ls-remote exit ${code}): $(grep -v '^[[:space:]]*$' "$err" | head -n1)"
  rm -f "$err"
  fl_repo_access_hint "$repo"
  return 1
}

# ---------------------------------------------------------------- app add

# fl_app_resolve NAME|URL [BRANCH] [NAME_OVERRIDE]: sets FL_RES_NAME,
# FL_RES_REPO, FL_RES_BRANCH. A known name takes repo and branch from
# config/apps.tsv for the profile; a URL takes the remote's default branch.
fl_app_resolve() {
  local target="$1" branch="${2:-}" name="${3:-}" policy repo pbranch
  FL_RES_NAME=""; FL_RES_REPO=""; FL_RES_BRANCH=""
  if fl_is_url "$target"; then
    FL_RES_REPO="$(fl_url_strip_userinfo "$target")"
    [[ "$FL_RES_REPO" == "$target" ]] || fl_die "The repo URL carries a user name or token." "Use the URL without it (git uses your SSH key or: gh auth setup-git)."
    FL_RES_NAME="${name:-$(fl_app_name_from_url "$target")}"
    FL_RES_BRANCH="$branch"
    return 0
  fi
  if [[ "$target" == "frappe" ]]; then
    FL_RES_NAME=frappe; FL_RES_REPO="https://github.com/frappe/frappe"; FL_RES_BRANCH="${branch:-$FL_FRAPPE_BRANCH}"
    return 0
  fi
  policy="$(fl_lookup_app_policy "$target" "$FL_PROFILE" 2>/dev/null || true)"
  [[ -n "$policy" ]] || fl_die "Unknown app '${target}': it is not in $(fl_config_file apps.tsv)." "Pass its git URL: benchbar app add https://github.com/OWNER/${target} --branch BRANCH"
  IFS='|' read -r pbranch repo _ _ <<<"$policy"
  # the official apps bench resolves by name live under github.com/frappe
  FL_RES_NAME="${name:-$target}"
  FL_RES_REPO="${repo:-https://github.com/frappe/${target}}"
  FL_RES_BRANCH="${branch:-$pbranch}"
}

# The sites an app command acts on: --site S, --all-sites, or none.
fl_app_target_sites() {
  local all="$1" s
  if [[ "$all" == "1" ]]; then fl_sites_list; return 0; fi
  if [[ -n "${OPT_SITE:-}" ]]; then fl_site_require "$OPT_SITE"; printf '%s\n' "$OPT_SITE"; fi
  return 0
}

# Lists the folders in apps/, sorted the same way every time.
fl__apps_dirs() {
  local d
  for d in "${FL_BENCH_DIR}"/apps/*/; do [[ -d "$d" ]] && basename "$d"; done | LC_ALL=C sort
}

# A get-app that failed half way. A folder bench did not list yet moves to
# the backups (nothing refers to it). A folder bench already put in
# sites/apps.txt stays, and so does the line: benchbar never edits sites/
# (AGENTS.md), so the fix is printed and doctor's apps_txt check keeps
# reporting it until bench's own remove-app has run.
fl_app_clone_rollback() {
  local d dest
  for d in "$@"; do
    [[ -n "$d" && -d "$(fl_app_path "$d")" ]] || continue
    if fl_app_in_apps_txt "$d"; then
      fl_warn "apps/${d} is half cloned and already listed in sites/apps.txt; benchbar does not edit sites/"
      fl_fix "cd ${FL_BENCH_DIR} && bench remove-app ${d}   (then benchbar app add ${d} again)"
      continue
    fi
    dest="${FL_BACKUP_ROOT}/$(fl_backup_stamp)/apps"
    mkdir -p "$dest"
    mv "$(fl_app_path "$d")" "$dest/$d"
    fl_warn "moved the half cloned apps/${d} to ${dest}/${d}"
  done
}

# fl_app_clone NAME REPO BRANCH: bench get-app, never --overwrite or
# --resolve-deps, assets later. Sets FL_CLONED_DIR (bench may pick the
# folder name, Raven vs raven).
FL_CLONED_DIR=""
fl_app_clone() {
  local name="$1" repo="$2" branch="$3" before after new
  FL_CLONED_DIR=""
  before="$(fl__apps_dirs)"
  fl_bench_env_exports
  if fl_run_long "bench get-app ${name} (${branch})" fl__in_dir "$FL_BENCH_DIR" env GIT_TERMINAL_PROMPT=0 bench get-app --skip-assets --branch "$branch" "$repo"; then
    after="$(fl__apps_dirs)"
    new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -n1)"
    FL_CLONED_DIR="${new:-$(fl_app_existing_dir "$name")}"
    [[ -n "$FL_CLONED_DIR" ]] || { fl_fail "bench get-app finished but no folder for ${name} appeared in apps/"; return 1; }
    return 0
  fi
  after="$(fl__apps_dirs)"
  # shellcheck disable=SC2046  # folder names are words
  fl_app_clone_rollback $(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
  fl_fix "cd ${FL_BENCH_DIR} && bench get-app --skip-assets --branch ${branch} ${repo}"
  return 1
}

# install-app on each site in FL_INSTALL_ON, with the bench's Redis up
# (frappe v16 needs it). Returns 1 when one failed; the others still run.
fl_app_install_on_sites() {
  local app="$1" s code=0
  shift
  [[ "$#" -gt 0 ]] || return 0
  fl_bench_env_exports
  [[ -n "$FL_SETUP_REDIS_PORTS" ]] || fl_bench_redis_up "$FL_BENCH_DIR"
  for s in "$@"; do
    if ! fl_run_long "bench --site ${s} install-app ${app}" fl__in_dir "$FL_BENCH_DIR" bench --site "$s" install-app "$app"; then
      fl_fix "cd ${FL_BENCH_DIR} && bench --site ${s} install-app ${app}   (or run this command again)"
      code=1
    fi
  done
  return "$code"
}

fl_app_build() {
  local apps="$1" args=()
  fl_bench_env_exports
  if [[ "$apps" == *,* ]]; then args=(--apps "$apps"); else args=(--app "$apps"); fi
  fl_run_long "bench build ${args[*]}" fl__in_dir "$FL_BENCH_DIR" bench build "${args[@]}"
}

# restart a running bench so the new code is served; a stopped one stays stopped
fl_app_restart_if_running() {
  fl_bench_is_running || { fl_info "the bench is not running; the change is live on the next benchup"; return 0; }
  ( fl_cmd_restart ) || { fl_warn "restart failed; run: benchbar restart --bench-dir ${FL_BENCH_DIR}"; return 1; }
}

# fl_app_verify APP BRANCH SITE...: apps.txt, the branch, the sites.
fl_app_verify() {
  local app="$1" branch="$2" s code=0 cur
  shift 2
  printf '\n%sVerify%s\n' "$FL_BOLD" "$FL_RESET"
  if fl_app_in_apps_txt "$app"; then fl_ok "${app} is in sites/apps.txt"; else fl_fail "${app} is not in sites/apps.txt"; code=1; fi
  if [[ -n "$branch" ]]; then
    cur="$(fl_app_branch "$app")"
    if [[ "$cur" == "$branch" ]]; then fl_ok "apps/${app} is on ${branch}"; else fl_fail "apps/${app} is on ${cur:-a detached HEAD}, expected ${branch}"; code=1; fi
  fi
  [[ "$#" -gt 0 ]] && fl_site_apps_refresh "$@"
  for s in "$@"; do
    if fl_site_has_app "$s" "$app"; then fl_ok "${app} is installed on ${s}"; else fl_fail "${app} is not installed on ${s}"; code=1; fi
  done
  return "$code"
}

# ---------------------------------------------------------------- app install

fl_cmd_app_install() {
  local app="" a missing="" dep
  for a in "$@"; do
    case "$a" in
      -*) fl_die "Unknown option for app install: $a" "Use: benchbar app install NAME --site SITE" ;;
      *) [[ -z "$app" ]] && app="$a" ;;
    esac
  done
  fl_require_bench
  [[ -n "$app" && -n "${OPT_SITE:-}" ]] || fl_die "Usage: benchbar app install NAME --site SITE"
  fl_site_require "$OPT_SITE"
  fl_app_in_apps_txt "$app" && [[ -d "$(fl_app_path "$app")" ]] || fl_die "${app} is not in this bench (apps/ and sites/apps.txt)." "Get it first: benchbar app add ${app}"
  missing="$(fl_app_required_apps "$app" | while IFS= read -r dep; do fl_app_in_apps_txt "$dep" || printf '%s ' "$dep"; done)"
  if [[ -n "$missing" ]]; then
    fl_fail "${app} requires ${missing% }, which the bench does not have"
    for dep in $missing; do fl_fix "benchbar app add ${dep}"; done
    return 1
  fi
  fl_header "benchbar app install" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "$OPT_SITE"
  fl_site_apps_refresh "$OPT_SITE"
  if fl_site_has_app "$OPT_SITE" "$app"; then
    fl_ok "unchanged: ${app} is already installed on ${OPT_SITE}"
    return 0
  fi
  [[ -n "$(fl_site_apps_meta error)" ]] && fl_warn "$(fl_site_apps_meta error)"
  printf '\n%sPlan%s\n' "$FL_BOLD" "$FL_RESET"
  fl_table "#|Step|Command" "1|Install on ${OPT_SITE}|bench --site ${OPT_SITE} install-app ${app}"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then printf '\n'; fl_info "dry-run: nothing was changed"; return 0; fi
  fl_confirm "Install ${app} on ${OPT_SITE}?" || { fl_warn "Cancelled. Nothing was changed."; return 1; }
  fl_steps_define "Install on ${OPT_SITE}"
  fl_step_begin 0
  if fl_app_install_on_sites "$app" "$OPT_SITE"; then fl_step_end "done"; else fl_step_end failed; fl_bench_redis_down; fl_steps_summary; return 1; fi
  fl_bench_redis_down
  fl_app_verify "$app" "" "$OPT_SITE" || { fl_steps_summary; return 1; }
  fl_steps_summary
}

# ---------------------------------------------------------------- pending operations
#
# A mutating app command that stops half way leaves a record, one per app, in
# the bench's state folder (<name>-<hash>.pending/<app>.json, one line of
# JSON, written through a temp file and mv). It lists the steps that did not
# finish, so the next run finishes them instead of trusting what Git says:
# after a fast forward the app is at its new commit, and a plain "old == new"
# would call a failed migrate "unchanged". The same file serves app update
# (op app_update) and the planned app add (op app_add). Written before the
# first mutating step with every step, rewritten when a step is done, removed
# when all are done and the verify pass is green. doctor and status read it
# with bash builtins only, never git or bench.
#
#   {"schema_version":1,"op":"app_update","app":"acme","branch":"main","from":SHA,"to":SHA,
#    "steps":[{"kind":"migrate","target":"macdev","name":"Migrate macdev"},...],
#    "failed_step":"migrate","reason":"...","started_at":"...Z","updated_at":"...Z"}
#
# The values are benchbar's own (kinds, site and app names, a [FAIL] line
# with quotes and backslashes turned into ' and /), so the reader below needs
# no JSON parser, which bash 3.2 does not have.

# fl_pending_dir_v VAR: the folder of this bench's records. The current bench
# is canonical already and its hash primed, so the name is built here without
# the subshell of fl_bench_state_file_for (status calls this on every poll).
fl_pending_dir_v() {
  local pdn pdf
  fl_bench_hash_prime
  if [[ -n "${FL_BENCH_DIR_CANON:-}" && "$FL_BENCH_DIR" == "$FL_BENCH_DIR_CANON" && -n "$FL_BENCH_HASH" ]]; then
    fl_bench_name_v pdn "$FL_BENCH_DIR"
    printf -v "$1" '%s/benches/%s-%s.pending' "$FL_STATE_DIR" "$pdn" "$FL_BENCH_HASH"
  else
    pdf="$(fl_bench_state_file_for "$FL_BENCH_DIR")"
    printf -v "$1" '%s.pending' "${pdf%.env}"
  fi
}
fl_pending_dir() { local d; fl_pending_dir_v d; printf '%s' "$d"; }

# fl_pending_file APP: the record's path; nothing for a name that is not a
# plain folder name, so no path built here can leave the .pending folder
fl_pending_file() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 0
  printf '%s/%s.json' "$(fl_pending_dir)" "$1"
}

# the text of a step: its label for the steps table
fl_pending_label() {
  case "$1" in
    backup) printf 'Back up %s' "$2" ;;
    fast_forward) printf 'Fast forward' ;;
    requirements_python) printf 'Python requirements' ;;
    requirements_node) printf 'Node requirements' ;;
    migrate) printf 'Migrate %s' "$2" ;;
    build) printf 'Build' ;;
    install) printf 'Install on %s' "$2" ;;
    clone_required) printf 'Clone %s' "$2" ;;
    clone) printf 'Clone %s' "$2" ;;
    restart) printf 'Restart' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fl_pending_clean TEXT: one line without quotes or backslashes, 300 characters at most
fl_pending_clean() {
  local t="$1"
  t="${t//$'\n'/ }"; t="${t//$'\r'/ }"; t="${t//$'\t'/ }"
  t="${t//\"/\'}"; t="${t//\\//}"
  printf '%s' "${t:0:300}"
}

# fl_pending_reason_v VAR LOGLINE: why the step since log line LOGLINE failed,
# its own [FAIL] line without the tag
fl_pending_reason_v() {
  local __m
  __m="$(fl_log_step_message "$2")"
  __m="${__m#*\[FAIL\] }"; __m="${__m#*\[WARN\] }"
  printf -v "$1" '%s' "$__m"
}

# fl_pending_write OP APP BRANCH FROM TO FAILED REASON STEP...: STEP is
# kind|target|name (more fields are ignored). started_at stays what an
# earlier record of this app says.
fl_pending_write() {
  local op="$1" app="$2" branch="$3" from="$4" to="$5" failed="$6" reason="$7" file dir tmp now started="" sep="" st kind target name line
  shift 7
  [[ "${FL_DRY_RUN:-0}" != "1" ]] || return 0
  file="$(fl_pending_file "$app")"; dir="${file%/*}"
  [[ -n "$file" ]] || { fl_fail "cannot keep a pending record for '${app}': not a plain app name"; return 1; }
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ -f "$file" ]]; then
    IFS= read -r line <"$file" || true
    fl__pd_get started started_at "$line"
  fi
  line="$(printf '{"schema_version":1,"op":%s,"app":%s,"branch":%s,"from":%s,"to":%s,"steps":[' \
    "\"$op\"" "\"$(fl_json_escape "$app")\"" "\"$(fl_json_escape "$branch")\"" "\"$from\"" "\"$to\"")"
  for st in "$@"; do
    IFS='|' read -r kind target name _ <<<"$st"
    line="${line}${sep}{\"kind\":\"${kind}\",\"target\":\"$(fl_json_escape "$target")\",\"name\":\"$(fl_json_escape "$name")\"}"; sep=","
  done
  line="${line}],\"failed_step\":$(fl_json_str "$failed"),\"reason\":$(fl_json_str "$(fl_pending_clean "$reason")"),\"started_at\":\"${started:-$now}\",\"updated_at\":\"${now}\"}"
  tmp="${file}.tmp.$$"
  if ! { mkdir -p "$dir" && printf '%s\n' "$line" >"$tmp" && mv "$tmp" "$file"; }; then
    rm -f "$tmp"
    fl_fail "could not write the pending record ${file}"
    return 1
  fi
}

fl_pending_remove() {
  local file
  [[ "${FL_DRY_RUN:-0}" != "1" ]] || return 0
  file="$(fl_pending_file "$1")"
  [[ -n "$file" && -f "$file" ]] || return 0
  rm -f "$file"
  rmdir "${file%/*}" 2>/dev/null || true
}

# fl_pending_read FILE: sets PD_OP, PD_APP, PD_BRANCH, PD_FROM, PD_TO,
# PD_FAILED, PD_REASON, PD_STARTED, PD_UPDATED, PD_LINE and PD_STEPS
# (kind|target|name each); 1 when FILE is not a record of this version.
# bash builtins only: status reads it on every poll.
PD_STEPS=()
fl_pending_read() {
  local line="" rest re
  PD_OP=""; PD_APP=""; PD_BRANCH=""; PD_FROM=""; PD_TO=""; PD_FAILED=""; PD_REASON=""; PD_STARTED=""; PD_UPDATED=""; PD_LINE=""; PD_STEPS=()
  [[ -f "$1" && -r "$1" ]] || return 1
  IFS= read -r line <"$1" || [[ -n "$line" ]] || return 1
  [[ "$line" == '{"schema_version":1,'*'}' ]] || return 1
  PD_LINE="$line"
  fl__pd_get PD_OP op "$line"; fl__pd_get PD_APP app "$line"; fl__pd_get PD_BRANCH branch "$line"
  fl__pd_get PD_FROM from "$line"; fl__pd_get PD_TO to "$line"; fl__pd_get PD_FAILED failed_step "$line"
  fl__pd_get PD_REASON reason "$line"; fl__pd_get PD_STARTED started_at "$line"; fl__pd_get PD_UPDATED updated_at "$line"
  [[ -n "$PD_OP" && -n "$PD_APP" ]] || return 1
  rest="$line"
  re='\{"kind":"([^"]*)","target":"([^"]*)","name":"([^"]*)"\}(.*)'
  while [[ "$rest" =~ $re ]]; do
    PD_STEPS+=("${BASH_REMATCH[1]}|${BASH_REMATCH[2]}|${BASH_REMATCH[3]}")
    rest="${BASH_REMATCH[4]}"
  done
  return 0
}

# fl__pd_get VAR KEY LINE: the string value of KEY (null and absent give nothing)
fl__pd_get() {
  local re="\"$2\":\"([^\"]*)\""
  if [[ "$3" =~ $re ]]; then printf -v "$1" '%s' "${BASH_REMATCH[1]}"; else printf -v "$1" '%s' ""; fi
}

# fl_pending_load APP: fl_pending_read of the app's record
fl_pending_load() { local f; f="$(fl_pending_file "$1")"; [[ -n "$f" ]] && fl_pending_read "$f"; }

# fl_pending_corrupt APP: the app has a record file that cannot be read (cut
# short, another version); it is kept, and nothing runs from it
fl_pending_corrupt() {
  local f
  f="$(fl_pending_file "$1")"
  [[ -n "$f" && -e "$f" ]] && ! fl_pending_read "$f"
}

# fl_pending_json_v VAR: the records of this bench as a JSON array for
# status --json ("[]" when there are none)
fl_pending_json_v() {
  local __out="[" __sep="" dir f st kind target name ssep j_from j_to j_failed j_reason j_updated j_branch j_app j_target j_name
  fl_pending_dir_v dir
  if [[ -d "$dir" ]]; then
    for f in "$dir"/*.json; do
      [[ -f "$f" ]] || continue
      fl_pending_read "$f" || continue
      fl_json_str_v j_branch "$PD_BRANCH"; fl_json_str_v j_from "$PD_FROM"; fl_json_str_v j_to "$PD_TO"
      fl_json_str_v j_failed "$PD_FAILED"; fl_json_str_v j_reason "$PD_REASON"; fl_json_str_v j_updated "$PD_UPDATED"
      fl_json_escape_v j_app "$PD_APP"
      __out="${__out}${__sep}{\"op\":\"${PD_OP}\",\"app\":\"${j_app}\",\"branch\":${j_branch},\"from\":${j_from},\"to\":${j_to},\"steps\":["
      ssep=""
      for st in ${PD_STEPS[@]+"${PD_STEPS[@]}"}; do
        IFS='|' read -r kind target name <<<"$st"
        fl_json_escape_v j_target "$target"; fl_json_escape_v j_name "$name"
        __out="${__out}${ssep}{\"kind\":\"${kind}\",\"target\":\"${j_target}\",\"name\":\"${j_name}\"}"; ssep=","
      done
      __out="${__out}],\"failed_step\":${j_failed},\"reason\":${j_reason},\"updated_at\":${j_updated}}"; __sep=","
    done
  fi
  printf -v "$1" '%s' "${__out}]"
}

# ---------------------------------------------------------------- app update

# fl_app_fetch APP REMOTE BRANCH: FETCH_HEAD is the remote branch. A
# shallow clone fetches back to its own HEAD's date, so old..new exists.
fl_app_fetch() {
  local app="$1" remote="$2" branch="$3" args=() ts err code=0
  if fl_app_shallow "$app"; then
    ts="$(fl_app_git "$app" log -1 --format=%ct HEAD 2>/dev/null || true)"
    [[ "$ts" =~ ^[0-9]+$ ]] && args+=("--shallow-since=@$((ts - 1))")
  fi
  err="$(mktemp "${TMPDIR:-/tmp}/benchbar-fetch.XXXXXX")"
  fl_git_batch -C "$(fl_app_path "$app")" fetch --quiet ${args[@]+"${args[@]}"} "$remote" "$branch" >/dev/null 2>"$err" || code=$?
  fl_log_file_append "$err"
  if [[ "$code" != "0" ]]; then
    fl_fail "git fetch ${remote} ${branch} failed in apps/${app}: $(grep -v '^[[:space:]]*$' "$err" | head -n1)"
    rm -f "$err"
    fl_repo_access_hint "$(fl_app_remote_url "$app")"
    return 1
  fi
  rm -f "$err"
}

# fl__au_command KIND TARGET APP TO: the command a step runs, for the plan
fl__au_command() {
  case "$1" in
    backup) printf 'bench --site %s backup' "$2" ;;
    fast_forward) printf 'git -C apps/%s merge --ff-only %s' "$3" "${4:0:12}" ;;
    requirements_python) printf 'bench setup requirements --python %s' "$3" ;;
    requirements_node) printf 'bench setup requirements --node %s' "$3" ;;
    migrate) printf 'bench --site %s migrate' "$2" ;;
    build) printf 'bench build --app %s' "$3" ;;
    restart) printf 'benchbar restart' ;;
  esac
}

# fl__au_run KIND TARGET APP TO: one step of app update; its own [FAIL] line says why it failed
fl__au_run() {
  local kind="$1" target="$2" app="$3" to="$4"
  case "$kind" in
    backup) fl_bench_redis_up "$FL_BENCH_DIR" >/dev/null 2>&1 || true
      fl_run_long "bench --site ${target} backup" fl__in_dir "$FL_BENCH_DIR" bench --site "$target" backup ;;
    fast_forward) fl_run_long "git merge --ff-only" git -C "$(fl_app_path "$app")" merge --ff-only --quiet "$to" ;;
    requirements_python) fl_run_long "bench setup requirements --python ${app}" fl__in_dir "$FL_BENCH_DIR" bench setup requirements --python "$app" ;;
    requirements_node) fl_run_long "bench setup requirements --node ${app}" fl__in_dir "$FL_BENCH_DIR" bench setup requirements --node "$app" ;;
    migrate) [[ -n "$FL_SETUP_REDIS_PORTS" ]] || fl_bench_redis_up "$FL_BENCH_DIR"
      fl_run_long "bench --site ${target} migrate" fl__in_dir "$FL_BENCH_DIR" bench --site "$target" migrate ;;
    build) fl_bench_redis_down; fl_app_build "$app" ;;
    restart) fl_app_restart_if_running ;;
  esac
}

fl_cmd_app_update() {
  local app="" a skip_backup=0 discard=0 branch remote old new head total=0 newer=0 from to sites=() s rows=() labels=() steps=() i code=0 running=0 sep log
  local ff_left f s pending=0 fetched=1 kind target name cmd reason fail_from
  local pd_failed="" pd_reason="" pd_started="" pd_line="" pd_steps=()
  for a in "$@"; do
    case "$a" in
      --skip-backup) skip_backup=1 ;;
      --discard-pending) discard=1 ;;
      --json) OPT_JSON=1 ;;
      -*) fl_die "Unknown option for app update: $a" "Use: benchbar app update NAME [--skip-backup] [--discard-pending] [--dry-run --json]" ;;
      *) [[ -z "$app" ]] && app="$a" ;;
    esac
  done
  fl_require_bench
  [[ -n "$app" ]] || fl_die "Usage: benchbar app update NAME [--skip-backup]"
  [[ "$OPT_JSON" != "1" || "${FL_DRY_RUN:-0}" == "1" ]] || fl_die "--json shows the plan only; add --dry-run." "benchbar app update ${app} --dry-run --json"
  # --discard-pending only removes benchbar's own record and then stops: no
  # update runs, and a dirty tree or a detached HEAD (an app added from a tag)
  # does not matter. Run benchbar app update again for the update itself.
  if [[ "$discard" == "1" ]]; then
    [[ "$OPT_JSON" != "1" ]] || fl_die "--discard-pending prints text only; leave out --json." "benchbar app update ${app} --discard-pending [--dry-run]"
    f="$(fl_pending_file "$app")"
    if [[ -z "$f" || ! -e "$f" ]]; then
      fl_info "no unfinished update or add of ${app} to discard"
    elif fl_pending_read "$f"; then
      if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then fl_info "dry-run: would drop the unfinished ${PD_OP} of ${app} (${#PD_STEPS[@]} step(s) not run) and stop; nothing is changed"
      else
        fl_warn "dropping the unfinished ${PD_OP} of ${app} (started ${PD_STARTED}, stopped at ${PD_FAILED:-no step}); its ${#PD_STEPS[@]} step(s) will not run, and nothing else runs now"
        fl_log "pending record dropped: ${PD_LINE}"
        fl_pending_remove "$app"
      fi
    elif [[ "${FL_DRY_RUN:-0}" == "1" ]]; then fl_info "dry-run: would drop the unreadable record ${f} and stop; nothing is changed"
    else
      fl_warn "dropping the unreadable record ${f}; nothing else runs now"
      fl_log "pending record dropped (unreadable): ${f}"
      fl_pending_remove "$app"
    fi
    return 0
  fi
  if ! fl_app_has_git "$app" || ! fl_app_in_apps_txt "$app"; then fl_die "${app} is not a git app of this bench." "benchbar app list shows the apps."; fi
  fl_app_dirty "$app" && fl_die "apps/${app} has local changes; update refuses to touch them." "cd ${FL_BENCH_DIR}/apps/${app} && git status   (commit or stash them first)"
  branch="$(fl_app_branch "$app")"
  [[ -n "$branch" ]] || fl_die "apps/${app} is on a detached HEAD; update follows a branch." "cd ${FL_BENCH_DIR}/apps/${app} && git checkout BRANCH"
  remote="$(fl_app_remote "$app")"
  [[ -n "$remote" ]] || fl_die "apps/${app} has no git remote." "cd ${FL_BENCH_DIR}/apps/${app} && git remote add upstream URL"
  head="$(fl_app_commit "$app")"

  # an earlier run that stopped half way: its record is the truth, not Git's position
  if fl_pending_corrupt "$app"; then
    fl_die "the pending record of ${app} cannot be read (cut short or from another version); it is kept, and no step runs from it." \
      "Look at $(fl_pending_file "$app"), then: benchbar app update ${app} --discard-pending   (drops the record and stops; run the update again after)"
  fi
  if fl_pending_load "$app"; then
    pd_failed="$PD_FAILED"; pd_reason="$PD_REASON"; pd_started="$PD_STARTED"; pd_line="$PD_LINE"; pd_steps=(${PD_STEPS[@]+"${PD_STEPS[@]}"})
    # where the app may be: at `from` only while the fast forward is still to do;
    # after it, `from` means someone went back (the reset --hard we print)
    ff_left=0
    for s in ${pd_steps[@]+"${pd_steps[@]}"}; do [[ "${s%%|*}" == "fast_forward" ]] && ff_left=1; done
    if [[ "$PD_OP" != "app_update" ]]; then
      fl_die "apps/${app} has an unfinished app add (stopped at ${PD_FAILED:-?}); update would not finish it." \
        "benchbar app add ${app} ... (the plan lists the steps left), or drop the record without running anything: benchbar app update ${app} --discard-pending"
    elif [[ "$head" != "$PD_TO" && ( "$ff_left" == "0" || "$head" != "$PD_FROM" ) ]]; then
      fl_die "apps/${app} is at ${head:0:12}, not where the unfinished update was going (${PD_TO:0:12})$([[ "$ff_left" == "1" ]] && printf ' or started (%s)' "${PD_FROM:0:12}"); it was moved after that update stopped." \
        "Look at the app yourself, then: benchbar app update ${app} --discard-pending   (drops the record and stops; the steps it lists are not run, and the update itself waits for the next run)"
    else
      pending=1; from="$PD_FROM"; to="$PD_TO"
    fi
  fi

  # the remote: needed to plan a new update; an unfinished one only counts what came after it
  if [[ "$pending" == "1" ]]; then
    fl_app_fetch "$app" "$remote" "$branch" >/dev/null 2>&1 || fetched=0
  elif [[ "$OPT_JSON" == "1" ]]; then fl_app_fetch "$app" "$remote" "$branch" >&2 || exit 1
  else fl_app_fetch "$app" "$remote" "$branch" || exit 1; fi
  old="$head"
  new="$(fl_app_git "$app" rev-parse -q --verify 'FETCH_HEAD^{commit}' 2>/dev/null || true)"
  if [[ "$pending" == "1" ]]; then
    if [[ "$fetched" == "1" && -n "$new" && "$new" != "$to" ]] && fl_app_git "$app" merge-base --is-ancestor "$to" "$new" 2>/dev/null; then
      newer="$(fl_app_git "$app" rev-list --count "${to}..${new}")"
    fi
    old="$from"; new="$to"
    if [[ "$old" != "$new" ]]; then total="$(fl_app_git "$app" rev-list --count "${old}..${new}" 2>/dev/null || printf 0)"; fi
  else
    [[ -n "$new" ]] || fl_die "git fetch gave no FETCH_HEAD for ${remote}/${branch}."
    if [[ "$old" != "$new" ]] && ! fl_app_git "$app" merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
      if fl_app_git "$app" merge-base --is-ancestor "$new" "$old" 2>/dev/null; then
        new="$old"   # local commits on top of the remote: nothing to take
        [[ "$OPT_JSON" == "1" ]] || fl_info "apps/${app} is ahead of ${remote}/${branch}"
      else
        fl_die "apps/${app} and ${remote}/${branch} have diverged, not a fast forward." "Merge or rebase it yourself: cd ${FL_BENCH_DIR}/apps/${app} && git log --oneline --graph HEAD FETCH_HEAD"
      fi
    fi
    [[ "$old" == "$new" ]] || total="$(fl_app_git "$app" rev-list --count "${old}..${new}")"
    from="$old"; to="$new"
  fi

  if [[ "$pending" == "1" ]]; then
    # the steps the record lists (a --skip-backup now leaves the backups out)
    for s in ${pd_steps[@]+"${pd_steps[@]}"}; do
      IFS='|' read -r kind target name <<<"$s"
      [[ "$kind" == "backup" && "$skip_backup" == "1" ]] && continue
      steps+=("${kind}|${target}|${name}|$(fl__au_command "$kind" "$target" "$app" "$to")")
      case "$kind" in backup|migrate) case " ${sites[*]:-} " in *" $target "*) ;; *) sites+=("$target") ;; esac ;; esac
    done
  else
    # which sites to back up and migrate: asked only when there is something to do
    # (every site must answer: a stale list could skip a backup or a migrate)
    if [[ "$total" != "0" ]]; then
      fl_site_apps_refresh >/dev/null 2>&1 || true
      [[ -z "$FL_SITE_APPS_ERROR" ]] || fl_die "Not updating ${app}: ${FL_SITE_APPS_ERROR}." "Start MariaDB (benchbar doctor names the fix), then run benchbar app update ${app} again."
    fi
    while IFS= read -r s; do [[ -n "$s" ]] && fl_site_has_app "$s" "$app" && sites+=("$s"); done < <(fl_sites_list)
    if [[ "$total" != "0" ]]; then
      fl_bench_is_running && running=1
      if [[ "$skip_backup" != "1" ]]; then for s in ${sites[@]+"${sites[@]}"}; do steps+=("backup|${s}|Back up ${s}|$(fl__au_command backup "$s" "$app" "$to")"); done; fi
      steps+=("fast_forward||Fast forward|$(fl__au_command fast_forward "" "$app" "$to")")
      steps+=("requirements_python|${app}|Python requirements|$(fl__au_command requirements_python "" "$app" "$to")")
      steps+=("requirements_node|${app}|Node requirements|$(fl__au_command requirements_node "" "$app" "$to")")
      for s in ${sites[@]+"${sites[@]}"}; do steps+=("migrate|${s}|Migrate ${s}|$(fl__au_command migrate "$s" "$app" "$to")"); done
      steps+=("build|${app}|Build|$(fl__au_command build "" "$app" "$to")")
      [[ "$running" == "1" ]] && steps+=("restart||Restart|benchbar restart")
    fi
  fi

  if [[ "$OPT_JSON" == "1" ]]; then
    if [[ "$pending" == "1" && "$pd_line" != *"}" ]]; then fl_warn "the record of ${app} looks cut short; pending is null here" >&2; fi
    printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"app":%s,"remote":%s,"branch":%s,"from":%s,"to":%s,"commits":[' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$app")" "$(fl_json_str "$remote")" \
      "$(fl_json_str "$branch")" "$(fl_json_str "$from")" "$(fl_json_str "$to")"
    sep=""
    if [[ "$total" != "0" ]]; then
      while IFS=' ' read -r a log; do
        printf '%s{"sha":%s,"subject":%s}' "$sep" "$(fl_json_str "$a")" "$(fl_json_str "$log")"; sep=","
      done < <(fl_app_git "$app" log --format='%h %s' -n 30 "${old}..${new}")
    fi
    printf '],"commits_total":%d,"newer_commits":%d,"pending":%s,"sites":%s,"skip_backup":%s,"steps":[' "$total" "$newer" \
      "$(if [[ "$pending" == "1" && "$pd_line" == *"}" ]]; then printf '%s' "$pd_line"; else printf null; fi)" \
      "$(fl_json_str_array ${sites[@]+"${sites[@]}"})" "$(fl_json_bool "$skip_backup")"
    sep=""
    for a in ${steps[@]+"${steps[@]}"}; do
      IFS='|' read -r kind target name cmd <<<"$a"
      printf '%s{"name":%s,"command":%s,"kind":%s,"target":%s}' "$sep" "$(fl_json_str "$name")" "$(fl_json_str "$cmd")" "$(fl_json_str "$kind")" "\"$(fl_json_escape "$target")\""; sep=","
    done
    printf ']}\n'
    return 0
  fi

  fl_header "benchbar app update" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "${sites[*]:-no site}"
  if [[ "$pending" != "1" && "$total" == "0" ]]; then
    fl_ok "unchanged: ${app} is up to date with ${remote}/${branch} (${old:0:7})"
    return 0
  fi
  if [[ "$pending" == "1" ]]; then
    printf '\n%sUnfinished from the last run%s update of %s, started %s%s\n' "$FL_BOLD" "$FL_RESET" "$app" "$pd_started" "${pd_failed:+, stopped at ${pd_failed}}"
    [[ -z "$pd_reason" ]] || fl_note "$pd_reason"
    [[ "${#steps[@]}" -gt 0 ]] || fl_info "every step is done; the verify pass below decides"
  fi
  if [[ "$total" != "0" ]]; then
    printf '\n%sChanges%s %s..%s on %s/%s, %d commit(s)\n' "$FL_BOLD" "$FL_RESET" "${old:0:7}" "${new:0:7}" "$remote" "$branch" "$total"
    fl_app_git "$app" log --format='%h %s' -n 30 "${old}..${new}" | sed 's/^/    /'
    [[ "$total" -gt 30 ]] && printf '    ... and %d more\n' $((total - 30))
  fi
  [[ "$newer" == "0" ]] || fl_info "${newer} newer commit(s) on ${remote}/${branch} wait for the next app update"
  if [[ "${#steps[@]}" -gt 0 ]]; then
    printf '\n%sPlan%s\n' "$FL_BOLD" "$FL_RESET"
    rows+=("#|Step|Command")
    i=1
    for a in "${steps[@]}"; do IFS='|' read -r kind target name cmd <<<"$a"; rows+=("${i}|${name}|${cmd}"); labels+=("$name"); i=$((i + 1)); done
    fl_table "${rows[@]}"
  fi
  [[ "${#sites[@]}" == "0" ]] && fl_info "no site has ${app} installed (from the last list-apps read): nothing to back up or migrate"
  [[ "$skip_backup" == "1" && "${#sites[@]}" -gt 0 ]] && fl_warn "--skip-backup: the sites are migrated without a backup first"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    printf '\n'; fl_info "dry-run: nothing was changed (git fetch updated only apps/${app}/.git)"
    return 0
  fi
  if [[ "$pending" == "1" ]]; then
    fl_confirm "Finish the unfinished update of ${app} and apply ${#labels[@]} step(s)?" || { fl_warn "Cancelled. Nothing was changed."; return 1; }
  else
    fl_confirm "Update ${app} (${total} commit(s)) and apply ${#labels[@]} step(s)?" || { fl_warn "Cancelled. Nothing was changed."; return 1; }
  fi

  fl_bench_env_exports
  # the record first: a stop anywhere below leaves the steps that did not finish
  fl_pending_write app_update "$app" "$branch" "$from" "$to" "$pd_failed" "$pd_reason" ${steps[@]+"${steps[@]}"} || { fl_fail "nothing was run: without its record a stop could not be finished later"; return 1; }
  fl_steps_define ${labels[@]+"${labels[@]}"}
  i=0
  for a in ${steps[@]+"${steps[@]}"}; do
    IFS='|' read -r kind target name cmd <<<"$a"
    fl_step_begin "$i"
    fl_log_lines_v fail_from
    code=0
    if [[ "$kind" == "restart" && "$pending" == "1" ]] && ! fl_bench_is_running; then
      # decided again on a retry: a bench that has been stopped since stays stopped
      fl_step_end skipped "not running"
    else
      fl__au_run "$kind" "$target" "$app" "$to" || code=1
      if [[ "$code" != "0" ]]; then
        fl_step_end failed
        fl_pending_reason_v reason "$fail_from"
        fl_pending_write app_update "$app" "$branch" "$from" "$to" "$kind" "${reason:-${name} failed}" "${steps[@]:$i}"
        fl_bench_redis_down
        fl_steps_summary
        fl_fail "update of ${app} stopped at: ${name}"
        [[ "$(fl_app_commit "$app")" != "$old" ]] && fl_note "the code is at ${new:0:12}; to go back (not run for you): git -C ${FL_BENCH_DIR}/apps/${app} reset --hard ${old}"
        [[ "$skip_backup" != "1" && "${#sites[@]}" -gt 0 ]] && fl_note "site backups are in ${FL_BENCH_DIR}/sites/<site>/private/backups"
        fl_fix "benchbar app update ${app} --bench-dir ${FL_BENCH_DIR}   (runs the steps that did not finish, nothing else)"
        return 1
      fi
      fl_step_end "done"
    fi
    i=$((i + 1))
    if ! fl_pending_write app_update "$app" "$branch" "$from" "$to" "" "" ${steps[@]+"${steps[@]:$i}"}; then
      # the record is what a retry runs from: a step that cannot be recorded is a failed step
      fl_bench_redis_down; fl_steps_summary
      fl_fail "update of ${app} stopped after: ${name} (its record could not be updated)"
      return 1
    fi
  done
  fl_bench_redis_down
  printf '\n%sVerify%s\n' "$FL_BOLD" "$FL_RESET"
  if [[ "$(fl_app_commit "$app")" == "$new" ]]; then fl_ok "apps/${app} is at ${new:0:7} (${remote}/${branch})"; else fl_fail "apps/${app} is not at ${new:0:7}"; code=1; fi
  if [[ "$code" == "0" ]]; then
    fl_pending_remove "$app"
  else
    fl_pending_write app_update "$app" "$branch" "$from" "$to" "verify" "apps/${app} is not at ${new:0:7}"
    fl_fix "look at apps/${app} yourself; benchbar app update ${app} --discard-pending drops this record and stops (the update itself is a separate run)"
  fi
  fl_steps_summary
  return "$code"
}

fl_cmd_app() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    list|"") fl_cmd_app_list "$@" ;;
    # --json and --apply TOKEN: the plan with a token, and applying it (app-plan.sh)
    add) if [[ "$OPT_JSON" == "1" ]] || fl_app_plan_wanted "$@"; then fl_cmd_app_add_planned "$@"; else fl_cmd_app_add "$@"; fi ;;
    install) fl_cmd_app_install "$@" ;;
    update) fl_cmd_app_update "$@" ;;
    focus|unfocus) fl_cmd_app_focus "$sub" "$@" ;;
    *) fl_die "Unknown app command: ${sub}" "Use: benchbar app list | add NAME|URL | install NAME --site S | update NAME | focus [NAME] | unfocus NAME" ;;
  esac
}

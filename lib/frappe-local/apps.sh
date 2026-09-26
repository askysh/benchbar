#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# apps.sh: the apps of a bench.
#
#   benchbar app list [--json] [--no-sites]
#   benchbar app add NAME|URL [--branch B] [--name N] [--site S | --all-sites]
#   benchbar app install NAME --site S
#   benchbar app update NAME [--skip-backup] [--dry-run --json]
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
fl_app_required_apps() {
  local dir hooks
  dir="$(fl_app_path "$1")"
  hooks="${dir}/$1/hooks.py"
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

# fl_capture_timeout SECS OUT COMMAND...: runs COMMAND in the bench with
# stdout to OUT; kills it after SECS (exit 124).
fl_capture_timeout() {
  local secs="$1" out="$2" pid ticks=0
  shift 2
  (cd "$FL_BENCH_DIR" && exec "$@") </dev/null >"$out" 2>>"${FL_LOG_FILE:-/dev/null}" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$ticks" -ge $((secs * 10)) ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid"
}

# fl_site_apps_live SITE: the site's apps, space separated; 1 when bench
# could not tell (MariaDB down, a broken site).
fl_site_apps_live() {
  local out code=0 apps
  out="$(mktemp "${TMPDIR:-/tmp}/benchbar-apps.XXXXXX")"
  fl_capture_timeout "${FL_LIST_APPS_TIMEOUT:-15}" "$out" bench --site "$1" list-apps --format json || code=$?
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
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      listed=0; fl_app_in_apps_txt "$app" && listed=1
      dirty=0; fl_app_dirty "$app" && dirty=1
      # shellcheck disable=SC2046  # the site names are words
      printf '%s{"name":%s,"in_apps_txt":%s,"repo":%s,"remote":%s,"branch":%s,"policy_branch":%s,"commit":%s,"dirty":%s,"shallow":%s,"version":%s,"sites":%s}' \
        "$sep" "$(fl_json_str "$app")" "$(fl_json_bool "$listed")" "$(fl_json_str "$(fl_app_remote_url "$app")")" \
        "$(fl_json_str "$(fl_app_remote "$app")")" "$(fl_json_str "$(fl_app_branch "$app")")" \
        "$(fl_json_str "$(fl_app_policy_branch "$app")")" "$(fl_json_str "$(fl_app_commit "$app")")" \
        "$(fl_json_bool "$dirty")" "$(fl_json_bool "$(fl_app_shallow "$app" && printf 1 || printf 0)")" \
        "$(fl_json_str "$(fl_app_json_version "$app")")" "$(fl_json_str_array $(fl_app_sites "$app"))"
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
    fl_fix "ssh-add --apple-use-keychain ~/.ssh/id_ed25519   (loads the key into the agent)"
  else
    fl_fix "use the SSH URL instead (git@HOST:OWNER/REPO.git), or let git use your GitHub login: gh auth setup-git"
  fi
}

# fl_repo_default_branch REPO: the remote's HEAD branch, or nothing
fl_repo_default_branch() {
  fl_git_batch ls-remote --symref -- "$1" HEAD 2>/dev/null | sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$#\1#p' | head -n1
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
  if fl_run_long "bench get-app ${name} (${branch})" fl__in_dir "$FL_BENCH_DIR" bench get-app --skip-assets --branch "$branch" "$repo"; then
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

# Required apps of DIR that are not in the bench yet, one per line.
fl_app_missing_required() {
  local dep
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    [[ -n "$(fl_app_existing_dir "$dep")" ]] || printf '%s\n' "$dep"
  done < <(fl_app_required_apps "$1")
}

# fl_app_clone_required DIR: clones what DIR (and what those need) requires,
# after a second plan and question. Returns 1 when one cannot be resolved.
FL_CLONED_DEPS=()
fl_app_clone_required() {
  local queue=() dep specs=() spec rows=() n policy repo branch code=0
  local saved_name="$FL_RES_NAME" saved_repo="$FL_RES_REPO" saved_branch="$FL_RES_BRANCH"
  while IFS= read -r dep; do [[ -n "$dep" ]] && queue+=("$dep"); done < <(fl_app_missing_required "$1")
  [[ "${#queue[@]}" -gt 0 ]] || return 0
  fl__app_clone_required "$1" "${queue[@]}" || code=$?
  FL_RES_NAME="$saved_name"; FL_RES_REPO="$saved_repo"; FL_RES_BRANCH="$saved_branch"
  return "$code"
}

fl__app_clone_required() {
  local parent="$1" dep specs=() spec rows=() n policy repo branch queue
  shift
  queue=("$@")
  # resolve everything first: an unknown one stops before any clone
  for dep in "${queue[@]}"; do
    policy="$(fl_lookup_app_policy "$dep" "$FL_PROFILE" 2>/dev/null || true)"
    if [[ -z "$policy" ]]; then
      fl_fail "${parent} requires ${dep}, which is not in the bench and not in $(fl_config_file apps.tsv)"
      fl_fix "benchbar app add <git URL of ${dep}> --branch BRANCH, then run this command again"
      return 1
    fi
    fl_app_resolve "$dep" "" ""
    specs+=("${FL_RES_NAME}|${FL_RES_REPO}|${FL_RES_BRANCH}")
  done
  rows+=("Required app|Branch|Repo")
  for spec in "${specs[@]}"; do IFS='|' read -r dep repo branch <<<"$spec"; rows+=("${dep}|${branch}|${repo}"); done
  printf '\n'
  fl_info "${parent} requires apps that are not in the bench yet (hooks.py required_apps):"
  fl_table "${rows[@]}"
  fl_confirm "Clone ${#specs[@]} required app(s)?" || { fl_warn "cancelled; ${parent} stays cloned but is not installed on any site"; return 1; }
  for spec in "${specs[@]}"; do
    IFS='|' read -r dep repo branch <<<"$spec"
    fl_repo_preflight "$repo" "$branch" || return 1
    fl_app_clone "$dep" "$repo" "$branch" || return 1
    FL_CLONED_DEPS+=("$FL_CLONED_DIR")
    # and what that one needs
    n="$(fl_app_missing_required "$FL_CLONED_DIR")"
    if [[ -n "$n" ]]; then fl_app_clone_required "$FL_CLONED_DIR" || return 1; fi
  done
  return 0
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

fl_cmd_app_add() {
  local target="" branch="" name="" all=0 sites=() s existing="" state="clone" cur to_install=() missing_deps=""
  local rows=() labels=() i code=0 build_apps running=0 dep
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --branch) branch="${2:-}"; shift 2 ;;
      --branch=*) branch="${1#*=}"; shift ;;
      --name) name="${2:-}"; shift 2 ;;
      --name=*) name="${1#*=}"; shift ;;
      --all-sites) all=1; shift ;;
      -*) fl_die "Unknown option for app add: $1" "Use: benchbar app add NAME|URL [--branch B] [--name N] [--site S | --all-sites]" ;;
      *) [[ -z "$target" ]] && target="$1"; shift ;;
    esac
  done
  fl_require_bench
  [[ -n "$target" ]] || fl_die "Usage: benchbar app add NAME|URL [--branch B] [--name N] [--site S | --all-sites]"
  [[ "$all" == "1" && -n "${OPT_SITE:-}" ]] && fl_die "Pass --site or --all-sites, not both."
  [[ -z "$name" || "$name" =~ ^[a-z][a-z0-9_]*$ ]] || fl_die "Invalid app name: '${name}'." "Use a Python package name: lowercase letters, digits and '_'."
  fl_app_resolve "$target" "$branch" "$name"
  while IFS= read -r s; do [[ -n "$s" ]] && sites+=("$s"); done < <(fl_app_target_sites "$all")
  fl_header "benchbar app add" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "${sites[*]:-no site}"

  existing="$(fl_app_existing_dir "$FL_RES_NAME")"
  if [[ -n "$existing" ]]; then
    FL_RES_NAME="$existing"
    fl_app_in_apps_txt "$existing" || fl_die "apps/${existing} exists but is not in sites/apps.txt (a get-app that did not finish?)." \
      "Move it aside (mv ${FL_BENCH_DIR}/apps/${existing} ~/${existing}.aside), then run this command again."
    cur="$(fl_app_branch "$existing")"
    if [[ -z "$FL_RES_BRANCH" ]]; then FL_RES_BRANCH="$cur"; fi
    if [[ "$cur" != "$FL_RES_BRANCH" ]]; then
      fl_die "apps/${existing} is on ${cur:-a detached HEAD}, not ${FL_RES_BRANCH}." \
        "benchbar never replaces an app. To switch it yourself: cd ${FL_BENCH_DIR}/apps/${existing} && git fetch $(fl_app_remote "$existing") ${FL_RES_BRANCH} && git checkout ${FL_RES_BRANCH}"
    fi
    state="unchanged"
    fl_ok "apps/${existing} is already on ${cur}"
    fl_app_dirty "$existing" && fl_warn "apps/${existing} has local changes; add only installs it on sites (app update and lock apply refuse a dirty app)"
    missing_deps="$(fl_app_missing_required "$existing" | tr '\n' ' ')"
  else
    if [[ -z "$FL_RES_BRANCH" ]]; then
      FL_RES_BRANCH="$(fl_repo_default_branch "$FL_RES_REPO")"
      if [[ -z "$FL_RES_BRANCH" ]]; then
        fl_repo_preflight "$FL_RES_REPO" HEAD || exit 1
        fl_die "Could not tell the default branch of ${FL_RES_REPO}." "Pass it: --branch BRANCH"
      fi
    fi
    fl_repo_preflight "$FL_RES_REPO" "$FL_RES_BRANCH" || exit 1
    fl_ok "${FL_RES_REPO} has ${FL_RES_BRANCH}"
  fi

  if [[ "${#sites[@]}" -gt 0 ]]; then
    fl_site_apps_refresh "${sites[@]}"
    for s in "${sites[@]}"; do
      if [[ "$state" == "unchanged" ]] && fl_site_has_app "$s" "$FL_RES_NAME"; then fl_ok "${FL_RES_NAME} is already installed on ${s}"; continue; fi
      to_install+=("$s")
    done
  fi
  if [[ "$state" == "unchanged" && -z "${missing_deps// /}" && "${#to_install[@]}" == "0" ]]; then
    printf '\n'
    fl_ok "unchanged: ${FL_RES_NAME} is on ${FL_RES_BRANCH}${sites[*]:+ and installed on ${sites[*]}}, nothing to do"
    [[ "${#sites[@]}" == "0" ]] && fl_info "install it on a site with: benchbar app install ${FL_RES_NAME} --site SITE"
    return 0
  fi
  if [[ -n "${missing_deps// /}" ]]; then
    fl_fail "${FL_RES_NAME} requires ${missing_deps% }, which the bench does not have"
    for dep in $missing_deps; do fl_fix "benchbar app add ${dep}"; done
    return 1
  fi

  fl_bench_is_running && running=1
  printf '\n%sPlan%s\n' "$FL_BOLD" "$FL_RESET"
  rows+=("#|Step|Command")
  i=1
  if [[ "$state" == "clone" ]]; then
    rows+=("${i}|Clone ${FL_RES_NAME}|bench get-app --skip-assets --branch ${FL_RES_BRANCH} ${FL_RES_REPO}"); labels+=("Clone ${FL_RES_NAME}"); i=$((i + 1))
    rows+=("${i}|Required apps|read from hooks.py after the clone; a second plan asks before cloning them"); labels+=("Required apps"); i=$((i + 1))
  fi
  for s in ${to_install[@]+"${to_install[@]}"}; do
    rows+=("${i}|Install on ${s}|bench --site ${s} install-app ${FL_RES_NAME}"); labels+=("Install on ${s}"); i=$((i + 1))
  done
  if [[ "$state" == "clone" ]]; then
    rows+=("${i}|Build|bench build --app ${FL_RES_NAME}"); labels+=("Build"); i=$((i + 1))
    [[ "$running" == "1" ]] && { rows+=("${i}|Restart|benchbar restart (the bench is running)"); labels+=("Restart"); }
  fi
  fl_table "${rows[@]}"
  [[ "${#sites[@]}" == "0" ]] && fl_info "no --site given: the app is cloned and built, not installed on a site"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    printf '\n'; fl_info "dry-run: nothing was changed"
    return 0
  fi
  fl_confirm "Apply $((${#labels[@]})) step(s)?" || { fl_warn "Cancelled. Nothing was changed."; return 1; }

  fl_steps_define "${labels[@]}"
  i=0
  if [[ "$state" == "clone" ]]; then
    fl_step_begin "$i"
    if fl_app_clone "$FL_RES_NAME" "$FL_RES_REPO" "$FL_RES_BRANCH"; then fl_step_end "done"; else fl_step_end failed; fl_steps_summary; return 1; fi
    FL_RES_NAME="$FL_CLONED_DIR"
    i=$((i + 1))
    fl_step_begin "$i"
    FL_CLONED_DEPS=()
    if [[ -z "$(fl_app_missing_required "$FL_RES_NAME")" ]]; then
      fl_step_end unchanged "none missing"
    elif fl_app_clone_required "$FL_RES_NAME"; then
      fl_step_end "done" "${FL_CLONED_DEPS[*]}"
    else
      fl_step_end failed; fl_steps_summary; return 1
    fi
    i=$((i + 1))
  fi
  for s in ${to_install[@]+"${to_install[@]}"}; do
    fl_step_begin "$i"
    if fl_app_install_on_sites "$FL_RES_NAME" "$s"; then fl_step_end "done"; else fl_step_end failed; code=1; fi
    i=$((i + 1))
  done
  fl_bench_redis_down
  if [[ "$state" == "clone" ]]; then
    fl_step_begin "$i"
    build_apps="$FL_RES_NAME"
    for dep in ${FL_CLONED_DEPS[@]+"${FL_CLONED_DEPS[@]}"}; do build_apps="${dep},${build_apps}"; done
    if fl_app_build "$build_apps"; then fl_step_end "done"; else fl_step_end failed; fl_fix "cd ${FL_BENCH_DIR} && bench build --app ${FL_RES_NAME}"; code=1; fi
    i=$((i + 1))
    if [[ "$running" == "1" ]]; then
      fl_step_begin "$i"
      if fl_app_restart_if_running; then fl_step_end "done"; else fl_step_end failed; code=1; fi
    fi
  fi
  fl_app_verify "$FL_RES_NAME" "$FL_RES_BRANCH" ${to_install[@]+"${to_install[@]}"} || code=1
  fl_steps_summary
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

fl_cmd_app_update() {
  local app="" a skip_backup=0 branch remote old new total sites=() s rows=() labels=() steps=() i code=0 running=0 sep log
  for a in "$@"; do
    case "$a" in
      --skip-backup) skip_backup=1 ;;
      --json) OPT_JSON=1 ;;
      -*) fl_die "Unknown option for app update: $a" "Use: benchbar app update NAME [--skip-backup] [--dry-run --json]" ;;
      *) [[ -z "$app" ]] && app="$a" ;;
    esac
  done
  fl_require_bench
  [[ -n "$app" ]] || fl_die "Usage: benchbar app update NAME [--skip-backup]"
  [[ "$OPT_JSON" != "1" || "${FL_DRY_RUN:-0}" == "1" ]] || fl_die "--json shows the plan only; add --dry-run." "benchbar app update ${app} --dry-run --json"
  if ! fl_app_has_git "$app" || ! fl_app_in_apps_txt "$app"; then fl_die "${app} is not a git app of this bench." "benchbar app list shows the apps."; fi
  fl_app_dirty "$app" && fl_die "apps/${app} has local changes; update refuses to touch them." "cd ${FL_BENCH_DIR}/apps/${app} && git status   (commit or stash them first)"
  branch="$(fl_app_branch "$app")"
  [[ -n "$branch" ]] || fl_die "apps/${app} is on a detached HEAD; update follows a branch." "cd ${FL_BENCH_DIR}/apps/${app} && git checkout BRANCH"
  remote="$(fl_app_remote "$app")"
  [[ -n "$remote" ]] || fl_die "apps/${app} has no git remote." "cd ${FL_BENCH_DIR}/apps/${app} && git remote add upstream URL"
  if [[ "$OPT_JSON" == "1" ]]; then fl_app_fetch "$app" "$remote" "$branch" >&2 || exit 1; else fl_app_fetch "$app" "$remote" "$branch" || exit 1; fi
  old="$(fl_app_commit "$app")"
  new="$(fl_app_git "$app" rev-parse -q --verify 'FETCH_HEAD^{commit}' 2>/dev/null || true)"
  [[ -n "$new" ]] || fl_die "git fetch gave no FETCH_HEAD for ${remote}/${branch}."
  if [[ "$old" != "$new" ]] && ! fl_app_git "$app" merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
    if fl_app_git "$app" merge-base --is-ancestor "$new" "$old" 2>/dev/null; then
      new="$old"   # local commits on top of the remote: nothing to take
      [[ "$OPT_JSON" == "1" ]] || fl_info "apps/${app} is ahead of ${remote}/${branch}"
    else
      fl_die "apps/${app} and ${remote}/${branch} have diverged, not a fast forward." "Merge or rebase it yourself: cd ${FL_BENCH_DIR}/apps/${app} && git log --oneline --graph HEAD FETCH_HEAD"
    fi
  fi
  total=0
  [[ "$old" == "$new" ]] || total="$(fl_app_git "$app" rev-list --count "${old}..${new}")"
  # which sites to back up and migrate: asked only when there is something to do
  [[ "$total" == "0" ]] || fl_site_apps_refresh >/dev/null 2>&1 || true
  while IFS= read -r s; do [[ -n "$s" ]] && fl_site_has_app "$s" "$app" && sites+=("$s"); done < <(fl_sites_list)
  if [[ "$total" != "0" ]]; then
    fl_bench_is_running && running=1
    if [[ "$skip_backup" != "1" ]]; then for s in ${sites[@]+"${sites[@]}"}; do steps+=("Back up ${s}|bench --site ${s} backup"); done; fi
    steps+=("Fast forward|git -C apps/${app} merge --ff-only ${new:0:12}")
    steps+=("Python requirements|bench setup requirements --python ${app}")
    steps+=("Node requirements|bench setup requirements --node ${app}")
    for s in ${sites[@]+"${sites[@]}"}; do steps+=("Migrate ${s}|bench --site ${s} migrate"); done
    steps+=("Build|bench build --app ${app}")
    [[ "$running" == "1" ]] && steps+=("Restart|benchbar restart")
  fi

  if [[ "$OPT_JSON" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"app":%s,"remote":%s,"branch":%s,"from":%s,"to":%s,"commits":[' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$app")" "$(fl_json_str "$remote")" \
      "$(fl_json_str "$branch")" "$(fl_json_str "$old")" "$(fl_json_str "$new")"
    sep=""
    if [[ "$total" != "0" ]]; then
      while IFS=' ' read -r a log; do
        printf '%s{"sha":%s,"subject":%s}' "$sep" "$(fl_json_str "$a")" "$(fl_json_str "$log")"; sep=","
      done < <(fl_app_git "$app" log --format='%h %s' -n 30 "${old}..${new}")
    fi
    printf '],"commits_total":%d,"sites":%s,"skip_backup":%s,"steps":[' "$total" "$(fl_json_str_array ${sites[@]+"${sites[@]}"})" "$(fl_json_bool "$skip_backup")"
    sep=""
    for a in ${steps[@]+"${steps[@]}"}; do
      printf '%s{"name":%s,"command":%s}' "$sep" "$(fl_json_str "${a%%|*}")" "$(fl_json_str "${a#*|}")"; sep=","
    done
    printf ']}\n'
    return 0
  fi

  fl_header "benchbar app update" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "${sites[*]:-no site}"
  if [[ "$total" == "0" ]]; then
    fl_ok "unchanged: ${app} is up to date with ${remote}/${branch} (${old:0:7})"
    return 0
  fi
  printf '\n%sChanges%s %s..%s on %s/%s, %d commit(s)\n' "$FL_BOLD" "$FL_RESET" "${old:0:7}" "${new:0:7}" "$remote" "$branch" "$total"
  fl_app_git "$app" log --format='%h %s' -n 30 "${old}..${new}" | sed 's/^/    /'
  [[ "$total" -gt 30 ]] && printf '    ... and %d more\n' $((total - 30))
  printf '\n%sPlan%s\n' "$FL_BOLD" "$FL_RESET"
  rows+=("#|Step|Command")
  i=1
  for a in "${steps[@]}"; do rows+=("${i}|${a%%|*}|${a#*|}"); labels+=("${a%%|*}"); i=$((i + 1)); done
  fl_table "${rows[@]}"
  [[ "${#sites[@]}" == "0" ]] && fl_info "no site has ${app} installed (from the last list-apps read): nothing to back up or migrate"
  [[ "$skip_backup" == "1" && "${#sites[@]}" -gt 0 ]] && fl_warn "--skip-backup: the sites are migrated without a backup first"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    printf '\n'; fl_info "dry-run: nothing was changed (git fetch updated only apps/${app}/.git)"
    return 0
  fi
  fl_confirm "Update ${app} (${total} commit(s)) and apply ${#labels[@]} step(s)?" || { fl_warn "Cancelled. Nothing was changed."; return 1; }

  fl_bench_env_exports
  fl_steps_define "${labels[@]}"
  i=0
  for a in "${steps[@]}"; do
    fl_step_begin "$i"
    case "${a%%|*}" in
      "Back up "*) s="${a%%|*}"; s="${s#Back up }"; fl_bench_redis_up "$FL_BENCH_DIR" >/dev/null 2>&1 || true
        fl_run_long "bench --site ${s} backup" fl__in_dir "$FL_BENCH_DIR" bench --site "$s" backup || code=1 ;;
      "Fast forward") fl_run_long "git merge --ff-only" git -C "$(fl_app_path "$app")" merge --ff-only --quiet "$new" || code=1 ;;
      "Python requirements") fl_run_long "bench setup requirements --python ${app}" fl__in_dir "$FL_BENCH_DIR" bench setup requirements --python "$app" || code=1 ;;
      "Node requirements") fl_run_long "bench setup requirements --node ${app}" fl__in_dir "$FL_BENCH_DIR" bench setup requirements --node "$app" || code=1 ;;
      "Migrate "*) s="${a%%|*}"; s="${s#Migrate }"; [[ -n "$FL_SETUP_REDIS_PORTS" ]] || fl_bench_redis_up "$FL_BENCH_DIR"
        fl_run_long "bench --site ${s} migrate" fl__in_dir "$FL_BENCH_DIR" bench --site "$s" migrate || code=1 ;;
      Build) fl_bench_redis_down; fl_app_build "$app" || code=1 ;;
      Restart) fl_app_restart_if_running || code=1 ;;
    esac
    if [[ "$code" != "0" ]]; then
      fl_step_end failed
      fl_bench_redis_down
      fl_steps_summary
      fl_fail "update of ${app} stopped at: ${a%%|*}"
      [[ "$(fl_app_commit "$app")" != "$old" ]] && fl_note "the code is at ${new:0:12}; to go back (not run for you): git -C ${FL_BENCH_DIR}/apps/${app} reset --hard ${old}"
      [[ "$skip_backup" != "1" && "${#sites[@]}" -gt 0 ]] && fl_note "site backups are in ${FL_BENCH_DIR}/sites/<site>/private/backups"
      return 1
    fi
    fl_step_end "done"
    i=$((i + 1))
  done
  fl_bench_redis_down
  printf '\n%sVerify%s\n' "$FL_BOLD" "$FL_RESET"
  if [[ "$(fl_app_commit "$app")" == "$new" ]]; then fl_ok "apps/${app} is at ${new:0:7} (${remote}/${branch})"; else fl_fail "apps/${app} is not at ${new:0:7}"; code=1; fi
  fl_steps_summary
  return "$code"
}

fl_cmd_app() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    list|"") fl_cmd_app_list "$@" ;;
    add) fl_cmd_app_add "$@" ;;
    install) fl_cmd_app_install "$@" ;;
    update) fl_cmd_app_update "$@" ;;
    *) fl_die "Unknown app command: ${sub}" "Use: benchbar app list | add NAME|URL | install NAME --site S | update NAME" ;;
  esac
}

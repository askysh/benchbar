#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153  # globals are shared with the other lib files (FL_PROFILE: version-policy.sh)
#
# teamlock.sh: benchbar.toml, the team lockfile. (lock.sh is the checkout's
# run lock; this is the other kind.)
#
#   benchbar lock write [--lock PATH] [--no-commits] [--allow-dirty]
#   benchbar lock check [--lock PATH] [--json]
#   benchbar lock apply [--lock PATH] [--dry-run] [--yes]
#
# The file pins each app's repo, branch and (optionally) commit, in the
# order of sites/apps.txt, plus the sites and the apps each one has:
#
#   schema = 1
#   [bench]
#   profile = "v15-lts"
#   frappe_bench = "5.31.0"
#   [[app]]
#   name = "erpnext"
#   repo = "https://github.com/frappe/erpnext"
#   branch = "version-15"
#   commit = "b5f784612d5b7969b72848dda5b22f10d3a8f764"
#   [[site]]
#   name = "acme.localhost"
#   default = true
#   apps = ["erpnext", "acme"]
#
# Lookup: --lock PATH, BENCHBAR_LOCK, LOCK_FILE in the bench's state, then
# <bench>/benchbar.toml. A bench is rarely a git repo, so a team commits the
# file in its main custom app and passes --lock apps/acme/benchbar.toml once.
#
# apply changes code only: it clones missing apps, switches branches on a
# clean tree and fast forwards to a pinned commit. It never runs new-site,
# install-app, migrate or bench update, and never resets local work.

FL_LOCK_KEYS="top.schema=i bench.profile=s bench.frappe_bench=s bench.bundle=s app.name=s app.repo=s app.branch=s app.commit=s site.name=s site.default=b site.apps=a"
FL_LOCK_REQUIRED="top.schema app.name app.repo app.branch site.name"

FL_LOCK_FILE=""
FL_LOCK_SOURCE=""
FL_LOCK_ERROR=""
LK_PROFILE=""; LK_FRAPPE_BENCH=""; LK_BUNDLE=""
LK_APP_NAME=(); LK_APP_REPO=(); LK_APP_BRANCH=(); LK_APP_COMMIT=()
LK_SITE_NAME=(); LK_SITE_DEFAULT=(); LK_SITE_APPS=()

# fl_lock_file_resolve [FLAG] [no-env]: sets FL_LOCK_FILE (maybe a file
# that does not exist yet) and FL_LOCK_SOURCE (flag, env, state, bench, or
# none when nothing names one and <bench>/benchbar.toml does not exist).
fl_lock_file_resolve() {
  local flag="${1:-}" noenv="${2:-}" v
  FL_LOCK_SOURCE=""
  if [[ -n "$flag" ]]; then
    case "$flag" in
      /*) FL_LOCK_FILE="$flag" ;;
      '~/'*) FL_LOCK_FILE="${HOME}/${flag#'~/'}" ;;
      *) if [[ -e "${PWD}/${flag}" ]]; then FL_LOCK_FILE="${PWD}/${flag}"; else FL_LOCK_FILE="${FL_BENCH_DIR}/${flag}"; fi ;;
    esac
    FL_LOCK_SOURCE=flag
  elif [[ -z "$noenv" && -n "${BENCHBAR_LOCK:-}" ]]; then
    FL_LOCK_FILE="$BENCHBAR_LOCK"; FL_LOCK_SOURCE="env"
  elif v="$(fl_bstate_get LOCK_FILE 2>/dev/null)" && [[ -n "$v" ]]; then
    FL_LOCK_FILE="$v"; FL_LOCK_SOURCE=state
  else
    FL_LOCK_FILE="${FL_BENCH_DIR}/benchbar.toml"
    FL_LOCK_SOURCE=bench
    [[ -f "$FL_LOCK_FILE" ]] || FL_LOCK_SOURCE=none
  fi
  return 0
}

# fl_lock_load FILE: the LK_* globals; 1 with FL_LOCK_ERROR set
fl_lock_load() {
  local file="$1" out err sec idx key val
  LK_PROFILE=""; LK_FRAPPE_BENCH=""; LK_BUNDLE=""
  LK_APP_NAME=(); LK_APP_REPO=(); LK_APP_BRANCH=(); LK_APP_COMMIT=()
  LK_SITE_NAME=(); LK_SITE_DEFAULT=(); LK_SITE_APPS=()
  FL_LOCK_ERROR=""
  err="$(mktemp "${TMPDIR:-/tmp}/benchbar-toml.XXXXXX")"
  if ! out="$(fl_toml_parse "$file" "$FL_LOCK_KEYS" "bench" "app site" "$FL_LOCK_REQUIRED" 2>"$err")"; then
    FL_LOCK_ERROR="$(head -n1 "$err")"; rm -f "$err"
    return 1
  fi
  rm -f "$err"
  while IFS=$'\t' read -r sec idx key val; do
    [[ -n "$sec" ]] || continue
    case "$sec.$key" in
      top.schema) [[ "$val" == "1" ]] || { FL_LOCK_ERROR="$(basename "$file"): not supported: schema ${val} (this benchbar reads schema 1)"; return 1; } ;;
      bench.profile) LK_PROFILE="$val" ;;
      bench.frappe_bench) LK_FRAPPE_BENCH="$val" ;;
      bench.bundle) LK_BUNDLE="$val" ;;
      app.name) LK_APP_NAME[idx - 1]="$val" ;;
      app.repo) LK_APP_REPO[idx - 1]="$val" ;;
      app.branch) LK_APP_BRANCH[idx - 1]="$val" ;;
      app.commit) LK_APP_COMMIT[idx - 1]="$val" ;;
      site.name) LK_SITE_NAME[idx - 1]="$val" ;;
      site.default) LK_SITE_DEFAULT[idx - 1]="$val" ;;
      site.apps) LK_SITE_APPS[idx - 1]="$val" ;;
    esac
  done <<<"$out"
  return 0
}

fl_lock_app_commit() { printf '%s' "${LK_APP_COMMIT[$1]:-}"; }

# A repo URL reduced to host/path, so https and SSH spellings of one repo
# compare equal (github.com/frappe/erpnext).
fl_repo_key() {
  printf '%s' "$1" | sed -E 's#^[a-zA-Z+]+://##; s#^[^@/]*@##; s#^([^/:]+):([^/0-9])#\1/\2#; s#/+$##; s#\.git$##' | tr '[:upper:]' '[:lower:]'
}

# fl_lock_commit_state APP SHA: equal, unknown (not in the local history),
# behind (the pin is ahead of HEAD), ahead or diverged
fl_lock_commit_state() {
  local app="$1" want="$2" head full
  head="$(fl_app_commit "$app")"
  [[ -n "$head" && "$head" == "$want"* ]] && { printf 'equal'; return 0; }
  full="$(fl_app_git "$app" rev-parse -q --verify "${want}^{commit}" 2>/dev/null || true)"
  [[ -n "$full" ]] || { printf 'unknown'; return 0; }
  if fl_app_git "$app" merge-base --is-ancestor "$head" "$full" 2>/dev/null; then printf 'behind'
  elif fl_app_git "$app" merge-base --is-ancestor "$full" "$head" 2>/dev/null; then printf 'ahead'
  else printf 'diverged'; fi
}

# ---------------------------------------------------------------- drift

DR_KIND=(); DR_APP=(); DR_SITE=(); DR_EXPECTED=(); DR_ACTUAL=(); DR_LEVEL=(); DR_FIX=()
DR_OK=0

fl__drift() {
  DR_KIND+=("$1"); DR_APP+=("$2"); DR_SITE+=("$3"); DR_EXPECTED+=("$4"); DR_ACTUAL+=("$5"); DR_LEVEL+=("$6"); DR_FIX+=("$7")
}

fl_drift_count() {
  local want="$1" n=0 l
  for l in ${DR_LEVEL[@]+"${DR_LEVEL[@]}"}; do [[ "$l" == "$want" ]] && n=$((n + 1)); done
  printf '%d' "$n"
}

# fl_lock_drift [with-bench-version]: compares the loaded lock with the
# bench. Local reads only (git, apps.txt, the site app cache); the bench
# version needs "bench --version" and is only asked for by lock check.
fl_lock_drift() {
  local with_version="${1:-}" i name dir cur state n=0 before apps a s listed ver remote
  DR_KIND=(); DR_APP=(); DR_SITE=(); DR_EXPECTED=(); DR_ACTUAL=(); DR_LEVEL=(); DR_FIX=(); DR_OK=0
  if [[ -n "$LK_PROFILE" ]]; then
    if [[ "$LK_PROFILE" == "$FL_PROFILE" ]]; then DR_OK=$((DR_OK + 1)); else fl__drift profile_mismatch "" "" "$LK_PROFILE" "$FL_PROFILE" warn ""; fi
  fi
  if [[ -n "$with_version" && -n "$LK_FRAPPE_BENCH" ]]; then
    ver="$(fl_bench_cli_version)"
    if [[ -z "$ver" || "$ver" == "$LK_FRAPPE_BENCH" ]]; then DR_OK=$((DR_OK + 1)); else fl__drift bench_version_mismatch "" "" "$LK_FRAPPE_BENCH" "$ver" warn "uv tool install frappe-bench==${LK_FRAPPE_BENCH}   (or pipx install frappe-bench==${LK_FRAPPE_BENCH})"; fi
  fi
  listed=" $(fl_apps_txt | tr '\n' ' ') "
  i=0
  n="${#LK_APP_NAME[@]}"
  while [[ "$i" -lt "$n" ]]; do
    name="${LK_APP_NAME[$i]}"
    before="${#DR_KIND[@]}"
    dir="$(fl_app_existing_dir "$name")"
    if [[ -z "$dir" || "$listed" != *" ${dir} "* ]]; then
      fl__drift app_missing "$name" "" "${LK_APP_BRANCH[$i]}" "" fail "benchbar lock apply"
      i=$((i + 1)); continue
    fi
    if ! fl_app_has_git "$dir"; then
      fl__drift repo_mismatch "$name" "" "${LK_APP_REPO[$i]}" "not a git checkout" warn ""
      i=$((i + 1)); continue
    fi
    cur="$(fl_app_remote_url "$dir")"
    if [[ "$(fl_repo_key "$cur")" != "$(fl_repo_key "${LK_APP_REPO[$i]}")" ]]; then
      remote="$(fl_app_remote "$dir")"
      fl__drift repo_mismatch "$name" "" "${LK_APP_REPO[$i]}" "$cur" warn "git -C ${FL_BENCH_DIR}/apps/${dir} remote set-url ${remote:-upstream} ${LK_APP_REPO[$i]}"
    fi
    fl_app_dirty "$dir" && fl__drift dirty "$name" "" "clean" "local changes" warn "git -C ${FL_BENCH_DIR}/apps/${dir} status"
    cur="$(fl_app_branch "$dir")"
    [[ "$cur" == "${LK_APP_BRANCH[$i]}" ]] || fl__drift branch_mismatch "$name" "" "${LK_APP_BRANCH[$i]}" "${cur:-detached}" warn "benchbar lock apply"
    if [[ -n "$(fl_lock_app_commit "$i")" ]]; then
      state="$(fl_lock_commit_state "$dir" "$(fl_lock_app_commit "$i")")"
      cur="$(fl_app_commit "$dir")"; cur="${cur:0:7}"; a="$(fl_lock_app_commit "$i")"; a="${a:0:7}"
      case "$state" in
        behind) fl__drift commit_behind "$name" "" "$a" "$cur" warn "benchbar lock apply" ;;
        unknown) fl__drift commit_unknown "$name" "" "$a" "$cur" warn "benchbar lock apply" ;;
        ahead) fl__drift commit_ahead "$name" "" "$a" "$cur" warn "benchbar lock write   (when the newer code is what the team should get)" ;;
        diverged) fl__drift commit_diverged "$name" "" "$a" "$cur" warn "git -C ${FL_BENCH_DIR}/apps/${dir} log --oneline --graph HEAD ${a}" ;;
      esac
    fi
    [[ "${#DR_KIND[@]}" == "$before" ]] && DR_OK=$((DR_OK + 1))
    i=$((i + 1))
  done
  # apps the bench has and the lock does not
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    case " ${LK_APP_NAME[*]:-} " in *" $a "*) continue ;; esac
    fl__drift app_extra "$a" "" "" "$a" warn "benchbar lock write   (to add it for the team)"
  done < <(fl_apps_txt)
  i=0
  n="${#LK_SITE_NAME[@]}"
  while [[ "$i" -lt "$n" ]]; do
    s="${LK_SITE_NAME[$i]}"
    before="${#DR_KIND[@]}"
    apps="${LK_SITE_APPS[$i]:-}"
    if [[ ! -f "${FL_BENCH_DIR}/sites/${s}/site_config.json" ]]; then
      fl__drift site_missing "" "$s" "$s" "" warn "benchbar site add ${s}${apps:+ --apps \"${apps}\"}"
    elif fl_site_apps_cached "$s" >/dev/null; then
      for a in $apps; do
        fl_site_has_app "$s" "$a" || fl__drift site_app_missing "$a" "$s" "$a" "" warn "benchbar app install ${a} --site ${s}"
      done
    fi
    [[ "${#DR_KIND[@]}" == "$before" ]] && DR_OK=$((DR_OK + 1))
    i=$((i + 1))
  done
  return 0
}

# The frappe-bench CLI version ("5.31.0"), or nothing.
fl_bench_cli_version() {
  local out v
  command -v bench >/dev/null 2>&1 || return 0
  out="$(mktemp "${TMPDIR:-/tmp}/benchbar-benchver.XXXXXX")"
  fl_capture_timeout 15 "$out" bench --version || true
  v="$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' "$out" | head -n1)"
  rm -f "$out"
  printf '%s' "$v"
}

# ---------------------------------------------------------------- commands

# fl__lock_args ARGS...: --lock PATH and the flags of each command
fl__lock_args() {
  LOCK_FLAG=""; LOCK_NO_COMMITS=0; LOCK_ALLOW_DIRTY=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --lock) LOCK_FLAG="${2:-}"; shift 2 ;;
      --lock=*) LOCK_FLAG="${1#*=}"; shift ;;
      --no-commits) LOCK_NO_COMMITS=1; shift ;;
      --allow-dirty) LOCK_ALLOW_DIRTY=1; shift ;;
      --json) OPT_JSON=1; shift ;;
      *) fl_die "Unknown option for lock: $1" "Use: benchbar lock write|check|apply [--lock PATH]" ;;
    esac
  done
}

# fl__lock_remember: a --lock path is kept for this bench (not in a dry run)
fl__lock_remember() {
  [[ "$FL_LOCK_SOURCE" == "flag" ]] || return 0
  [[ "$(fl_bstate_get LOCK_FILE)" == "$FL_LOCK_FILE" ]] && return 0
  fl_bstate_set LOCK_FILE "$FL_LOCK_FILE"
  [[ "${FL_DRY_RUN:-0}" == "1" ]] || fl_info "remembered ${FL_LOCK_FILE} as this bench's lockfile"
}

fl__lock_require() {
  [[ "$FL_LOCK_SOURCE" != "none" && -f "$FL_LOCK_FILE" ]] || fl_die "No lockfile for ${FL_BENCH_DIR} (looked for ${FL_LOCK_FILE})." \
    "Write one with: benchbar lock write, or point at the team's: benchbar lock $1 --lock apps/APP/benchbar.toml"
  fl_lock_load "$FL_LOCK_FILE" || fl_die "${FL_LOCK_ERROR}" "benchbar.toml takes a strict subset of TOML: strings without escapes, true/false, integers, one line string lists."
}

# The app folder the lockfile lives in, if any: its own commit cannot be
# pinned (committing the lockfile moves it).
fl__lock_home_app() {
  local rel
  case "$FL_LOCK_FILE" in
    "${FL_BENCH_DIR}"/apps/*/*) rel="${FL_LOCK_FILE#"${FL_BENCH_DIR}"/apps/}"; printf '%s' "${rel%%/*}" ;;
  esac
}

fl_lock_render() {
  local app url branch commit problems="" home s apps default cached ver
  home="$(fl__lock_home_app)"
  printf '# benchbar.toml: the apps and sites of this bench, pinned for the team.\n'
  printf '# Written by benchbar lock write; check with benchbar lock check, apply with benchbar lock apply.\n'
  printf 'schema = 1\n\n[bench]\nprofile = "%s"\n' "$FL_PROFILE"
  ver="$(fl_bench_cli_version)"
  [[ -n "$ver" ]] && printf 'frappe_bench = "%s"\n' "$ver"
  [[ -n "$(fl_bstate_get APP_BUNDLE)" ]] && printf 'bundle = "%s"\n' "$(fl_bstate_get APP_BUNDLE)"
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    if ! fl_app_has_git "$app"; then problems="${problems}apps/${app} is not a git checkout; "; continue; fi
    url="$(fl_app_remote_url "$app")"
    [[ -n "$url" ]] || { problems="${problems}apps/${app} has no git remote; "; continue; }
    branch="$(fl_app_branch "$app")"
    if [[ -z "$branch" ]]; then
      [[ "$LOCK_ALLOW_DIRTY" == "1" ]] && branch="$(fl_app_policy_branch "$app")"
      [[ -n "$branch" ]] || { problems="${problems}apps/${app} is on a detached HEAD; "; continue; }
    fi
    if fl_app_dirty "$app" && [[ "$LOCK_ALLOW_DIRTY" != "1" ]]; then problems="${problems}apps/${app} has local changes; "; continue; fi
    printf '\n[[app]]\nname = "%s"\nrepo = "%s"\nbranch = "%s"\n' "$app" "$url" "$branch"
    commit="$(fl_app_commit "$app")"
    [[ "$LOCK_NO_COMMITS" == "1" || "$app" == "$home" || -z "$commit" ]] || printf 'commit = "%s"\n' "$commit"
  done < <(fl_apps_txt)
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    default=false; [[ "$s" == "$FL_SITE" ]] && default=true
    printf '\n[[site]]\nname = "%s"\ndefault = %s\n' "$s" "$default"
    if cached="$(fl_site_apps_cached "$s")"; then
      apps=""
      for app in $cached; do [[ "$app" == "frappe" ]] || apps="${apps}${apps:+, }\"${app}\""; done
      printf 'apps = [%s]\n' "$apps"
    fi
  done < <(fl_sites_list)
  if [[ -n "$problems" ]]; then printf '%s\n' "${problems%; }" >&2; return 1; fi
  return 0
}

fl_cmd_lock_write() {
  local tmp err code=0
  fl__lock_args "$@"
  fl_require_bench
  fl_lock_file_resolve "$LOCK_FLAG"
  fl_header "benchbar lock write" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "$FL_SITE"
  fl_site_apps_refresh
  [[ -n "$FL_SITE_APPS_ERROR" ]] && fl_warn "${FL_SITE_APPS_ERROR}; the sites' apps come from the last good read"
  tmp="$(mktemp "${TMPDIR:-/tmp}/benchbar-lock.XXXXXX")"; err="$(mktemp "${TMPDIR:-/tmp}/benchbar-lock.XXXXXX")"
  if ! fl_lock_render >"$tmp" 2>"$err"; then
    fl_fail "not written: $(cat "$err")"
    rm -f "$tmp" "$err"
    fl_fix "commit or stash local changes and check out a branch first, or pass --allow-dirty to pin what is there"
    return 1
  fi
  rm -f "$err"
  fl_lock_load "$tmp" || { rm -f "$tmp"; fl_die "the lockfile would not parse: ${FL_LOCK_ERROR}"; }
  [[ -n "$(fl__lock_home_app)" && "$LOCK_NO_COMMITS" != "1" ]] && fl_info "apps/$(fl__lock_home_app) holds the lockfile, so its commit is not pinned (committing the file moves it)"
  fl_write_reviewed "$FL_LOCK_FILE" "$tmp" "the lockfile" || code=1
  rm -f "$tmp"
  [[ "$code" == "0" ]] && fl__lock_remember
  return "$code"
}

fl_lock_print_drift_json() {
  local i=0 sep=""
  printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"lock_file":%s,"in_sync":%s,"drift":[' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$FL_LOCK_FILE")" \
    "$(fl_json_bool "$([[ "${#DR_KIND[@]}" == "0" ]] && printf 1 || printf 0)")"
  while [[ "$i" -lt "${#DR_KIND[@]}" ]]; do
    printf '%s{"kind":"%s","app":%s,"site":%s,"expected":%s,"actual":%s,"level":"%s","fix_command":%s}' "$sep" "${DR_KIND[$i]}" \
      "$(fl_json_str "${DR_APP[$i]}")" "$(fl_json_str "${DR_SITE[$i]}")" "$(fl_json_str "${DR_EXPECTED[$i]}")" \
      "$(fl_json_str "${DR_ACTUAL[$i]}")" "${DR_LEVEL[$i]}" "$(fl_json_str "${DR_FIX[$i]}")"
    sep=","
    i=$((i + 1))
  done
  printf '],"summary":{"ok":%d,"warn":%d,"fail":%d}}\n' "$DR_OK" "$(fl_drift_count warn)" "$(fl_drift_count fail)"
}

fl_lock_drift_line() {
  local i="$1" what
  what="${DR_APP[$i]:-${DR_SITE[$i]:-bench}}"
  [[ -n "${DR_SITE[$i]}" && -n "${DR_APP[$i]}" ]] && what="${DR_APP[$i]} on ${DR_SITE[$i]}"
  printf '%s: %s (lock: %s, bench: %s)' "${DR_KIND[$i]}" "$what" "${DR_EXPECTED[$i]:--}" "${DR_ACTUAL[$i]:--}"
}

fl_cmd_lock_check() {
  local i=0
  fl__lock_args "$@"
  fl_require_bench
  fl_lock_file_resolve "$LOCK_FLAG"
  fl__lock_require check
  fl__lock_remember
  fl_lock_drift with-bench-version
  if [[ "$OPT_JSON" == "1" ]]; then
    fl_lock_print_drift_json
  else
    fl_header "benchbar lock check" "read-only" "$FL_PROFILE" "$FL_BENCH_DIR" "$FL_SITE"
    fl_info "lockfile ${FL_LOCK_FILE} (${#LK_APP_NAME[@]} apps, ${#LK_SITE_NAME[@]} sites)"
    while [[ "$i" -lt "${#DR_KIND[@]}" ]]; do
      if [[ "${DR_LEVEL[$i]}" == "fail" ]]; then fl_fail "$(fl_lock_drift_line "$i")"; else fl_warn "$(fl_lock_drift_line "$i")"; fi
      [[ -n "${DR_FIX[$i]}" ]] && fl_fix "${DR_FIX[$i]}"
      i=$((i + 1))
    done
    if [[ "${#DR_KIND[@]}" == "0" ]]; then fl_ok "in sync: the bench matches ${FL_LOCK_FILE}"; fi
    printf '\n  %s%d ok, %d warn, %d fail%s\n' "$FL_BOLD" "$DR_OK" "$(fl_drift_count warn)" "$(fl_drift_count fail)" "$FL_RESET"
  fi
  [[ "${#DR_KIND[@]}" == "0" ]]
}

# ---------------------------------------------------------------- apply

# fl_lock_reach_commit APP SHA: fast forwards APP to SHA, fetching it when
# it is not local. 0 done, 1 failed, 2 skipped (ahead or diverged).
fl_lock_reach_commit() {
  local app="$1" sha="$2" remote state
  remote="$(fl_app_remote "$app")"
  state="$(fl_lock_commit_state "$app" "$sha")"
  if [[ "$state" == "unknown" ]]; then
    fl_git_batch -C "$(fl_app_path "$app")" fetch --quiet "$remote" "$sha" >>"${FL_LOG_FILE:-/dev/null}" 2>&1 \
      || { fl_app_shallow "$app" && fl_git_batch -C "$(fl_app_path "$app")" fetch --quiet --unshallow "$remote" >>"${FL_LOG_FILE:-/dev/null}" 2>&1; } || true
    state="$(fl_lock_commit_state "$app" "$sha")"
  fi
  case "$state" in
    equal) return 0 ;;
    behind) fl_run_long "git merge --ff-only ${sha:0:7} (${app})" git -C "$(fl_app_path "$app")" merge --ff-only --quiet "$sha" ;;
    unknown) fl_fail "${app}: commit ${sha:0:7} is not on ${remote}"; return 1 ;;
    *) fl_warn "${app}: the local code is ${state} of ${sha:0:7}; left as it is (local work outranks the lock)"; return 2 ;;
  esac
}

# fl_lock_switch_branch APP REMOTE BRANCH: a clean app onto BRANCH, its
# local branch when it has one, else a new one tracking the remote's
fl_lock_switch_branch() {
  local app="$1" remote="$2" branch="$3" args=()
  fl_app_shallow "$app" && args=(--depth 1)
  fl_run_long "git fetch ${remote} ${branch} (${app})" fl_git_batch -C "$(fl_app_path "$app")" fetch --quiet ${args[@]+"${args[@]}"} "$remote" "+refs/heads/${branch}:refs/remotes/${remote}/${branch}" || return 1
  if fl_app_git "$app" show-ref --verify --quiet "refs/heads/${branch}"; then
    fl_run_long "git checkout ${branch} (${app})" git -C "$(fl_app_path "$app")" checkout --quiet "$branch"
  else
    fl_run_long "git checkout -b ${branch} (${app})" git -C "$(fl_app_path "$app")" checkout --quiet -b "$branch" --track "${remote}/${branch}"
  fi
}

fl_cmd_lock_apply() {
  local i n name dir cur state rows=() plan=() skipped=() changed=() cloned=() a s code=0 r kind sha step
  fl__lock_args "$@"
  fl_require_bench
  fl_lock_file_resolve "$LOCK_FLAG"
  fl__lock_require apply
  fl_header "benchbar lock apply" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "$FL_SITE"
  fl_info "lockfile ${FL_LOCK_FILE}"
  fl_lock_drift
  [[ -n "$LK_PROFILE" && "$LK_PROFILE" != "$FL_PROFILE" ]] && fl_warn "the lock was written on profile ${LK_PROFILE}, this bench is ${FL_PROFILE}; apply changes apps only"
  # the plan: one entry per app that needs something, "kind|app|dir|detail"
  n="${#LK_APP_NAME[@]}"; i=0
  while [[ "$i" -lt "$n" ]]; do
    name="${LK_APP_NAME[$i]}"
    dir="$(fl_app_existing_dir "$name")"
    sha="$(fl_lock_app_commit "$i")"
    if [[ -z "$dir" ]]; then
      plan+=("clone|${i}|${name}|bench get-app --skip-assets --branch ${LK_APP_BRANCH[$i]} ${LK_APP_REPO[$i]}${sha:+, then ${sha:0:7}}")
    elif ! fl_app_in_apps_txt "$dir" || ! fl_app_has_git "$dir"; then
      skipped+=("${name}: apps/${dir} is there but not a listed git app; see benchbar doctor")
    elif fl_app_dirty "$dir"; then
      cur="$(fl_app_branch "$dir")"
      if [[ "$cur" != "${LK_APP_BRANCH[$i]}" ]] || { [[ -n "$sha" ]] && [[ "$(fl_lock_commit_state "$dir" "$sha")" != "equal" ]]; }; then
        skipped+=("${name}: local changes in apps/${dir}; commit or stash them, then apply again")
      fi
    else
      cur="$(fl_app_branch "$dir")"
      if [[ "$cur" != "${LK_APP_BRANCH[$i]}" ]]; then
        plan+=("branch|${i}|${dir}|${cur:-detached} -> ${LK_APP_BRANCH[$i]}${sha:+, then ${sha:0:7}}")
      elif [[ -n "$sha" ]]; then
        state="$(fl_lock_commit_state "$dir" "$sha")"
        case "$state" in
          equal) ;;
          behind|unknown) plan+=("commit|${i}|${dir}|fast forward to ${sha:0:7}") ;;
          *) skipped+=("${name}: apps/${dir} is ${state} of the pinned ${sha:0:7}; local work outranks the lock (benchbar lock write pins it)") ;;
        esac
      fi
    fi
    i=$((i + 1))
  done
  printf '\n%sPlan%s\n' "$FL_BOLD" "$FL_RESET"
  for s in ${skipped[@]+"${skipped[@]}"}; do fl_warn "skipped: ${s}"; done
  for i in "${!DR_KIND[@]}"; do
    [[ "${DR_KIND[$i]}" == "app_extra" ]] && fl_info "${DR_APP[$i]} is in the bench but not in the lock; it stays"
  done
  if [[ "${#plan[@]}" == "0" ]]; then
    fl_ok "unchanged: the apps match ${FL_LOCK_FILE}"
    fl_lock_site_steps
    fl__lock_remember
    return 0
  fi
  rows+=("#|App|Change")
  i=1
  for step in "${plan[@]}"; do IFS='|' read -r kind r name a <<<"$step"; rows+=("${i}|${name}|${a}"); i=$((i + 1)); done
  fl_table "${rows[@]}"
  fl_info "then bench setup requirements and bench build --app for each changed app; no site is touched"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then printf '\n'; fl_info "dry-run: nothing was changed"; return 0; fi
  fl_confirm "Apply ${#plan[@]} change(s) to the apps?" || { fl_warn "Cancelled. Nothing was changed."; return 1; }
  fl_bench_env_exports
  rows=(); for step in "${plan[@]}"; do IFS='|' read -r kind r name a <<<"$step"; rows+=("${name}"); done
  rows+=("Requirements and build")
  fl_steps_define "${rows[@]}"
  i=0
  for step in "${plan[@]}"; do
    IFS='|' read -r kind r name a <<<"$step"
    sha="$(fl_lock_app_commit "$r")"
    fl_step_begin "$i"
    state=0
    case "$kind" in
      clone)
        if fl_repo_preflight "${LK_APP_REPO[$r]}" "${LK_APP_BRANCH[$r]}" && fl_app_clone "$name" "${LK_APP_REPO[$r]}" "${LK_APP_BRANCH[$r]}"; then
          name="$FL_CLONED_DIR"; cloned+=("$name")
          # a clone made just now holds no local work: its branch may start at the pin
          if [[ -n "$sha" && "$(fl_lock_commit_state "$name" "$sha")" != "equal" ]]; then
            fl_lock_reach_commit "$name" "$sha" || true
            if [[ "$(fl_lock_commit_state "$name" "$sha")" == "ahead" ]]; then
              fl_run_long "git checkout -B ${LK_APP_BRANCH[$r]} ${sha:0:7} (${name}, fresh clone)" git -C "$(fl_app_path "$name")" checkout --quiet -B "${LK_APP_BRANCH[$r]}" "$sha" || state=1
            fi
          fi
        else
          state=1
        fi ;;
      branch)
        if fl_lock_switch_branch "$name" "$(fl_app_remote "$name")" "${LK_APP_BRANCH[$r]}"; then
          changed+=("$name")
          if [[ -n "$sha" ]]; then fl_lock_reach_commit "$name" "$sha" || state=$?; fi
        else
          state=1
        fi ;;
      commit)
        fl_lock_reach_commit "$name" "$sha" || state=$?
        [[ "$state" == "1" ]] || changed+=("$name") ;;
    esac
    case "$state" in
      0) fl_step_end "done" ;;
      2) fl_step_end skipped ;;
      *) fl_step_end failed; code=1 ;;
    esac
    i=$((i + 1))
  done
  fl_step_begin "$i"
  state=0
  for a in ${changed[@]+"${changed[@]}"}; do
    fl_run_long "bench setup requirements --python ${a}" fl__in_dir "$FL_BENCH_DIR" bench setup requirements --python "$a" || state=1
    fl_run_long "bench setup requirements --node ${a}" fl__in_dir "$FL_BENCH_DIR" bench setup requirements --node "$a" || state=1
  done
  a="$(printf '%s\n' ${changed[@]+"${changed[@]}"} ${cloned[@]+"${cloned[@]}"} | awk 'NF && !seen[$0]++' | paste -sd, -)"
  if [[ -n "$a" ]]; then fl_app_build "$a" || state=1; fi
  if [[ "$state" == "0" ]]; then fl_step_end "done"; else fl_step_end failed; code=1; fi
  printf '\n%sVerify%s\n' "$FL_BOLD" "$FL_RESET"
  fl_lock_drift
  i=0
  while [[ "$i" -lt "${#DR_KIND[@]}" ]]; do
    case "${DR_KIND[$i]}" in site_*|app_extra|profile_mismatch) ;; *) fl_warn "$(fl_lock_drift_line "$i")" ;; esac
    i=$((i + 1))
  done
  fl_lock_site_steps
  fl_steps_summary
  fl__lock_remember
  if [[ -n "${changed[*]:-}${cloned[*]:-}" ]]; then
    fl_info "the code changed: migrate the sites that have these apps (bench --site SITE migrate), then benchbar restart"
  fi
  return "$code"
}

# Site level changes are printed, never run: sites hold data.
fl_lock_site_steps() {
  local i=0 printed=0
  while [[ "$i" -lt "${#DR_KIND[@]}" ]]; do
    case "${DR_KIND[$i]}" in
      site_missing|site_app_missing)
        [[ "$printed" == "1" ]] || { printf '\n%sNext steps for the sites (not run)%s\n' "$FL_BOLD" "$FL_RESET"; printed=1; }
        fl_note "${DR_FIX[$i]}" ;;
    esac
    i=$((i + 1))
  done
  return 0
}

fl_cmd_lock() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    write) fl_cmd_lock_write "$@" ;;
    check) fl_cmd_lock_check "$@" ;;
    apply) fl_cmd_lock_apply "$@" ;;
    *) fl_die "Unknown lock command: ${sub:-none}" "Use: benchbar lock write | check | apply [--lock PATH]" ;;
  esac
}

# ---------------------------------------------------------------- doctor

chk_lock_parse() {
  fl_lock_file_resolve ""
  if [[ "$FL_LOCK_SOURCE" == "none" ]]; then chk__set ok "no benchbar.toml for this bench"; return 0; fi
  if [[ ! -f "$FL_LOCK_FILE" ]]; then
    chk__set warn "the lockfile ${FL_LOCK_FILE} (${FL_LOCK_SOURCE}) does not exist" "benchbar lock write --lock ${FL_LOCK_FILE}"
    return 0
  fi
  if fl_lock_load "$FL_LOCK_FILE"; then
    chk__set ok "${FL_LOCK_FILE} parses (${#LK_APP_NAME[@]} apps, ${#LK_SITE_NAME[@]} sites)"
  else
    chk__set fail "${FL_LOCK_ERROR}" "fix ${FL_LOCK_FILE} by hand, or rewrite it: benchbar lock write"
  fi
}

chk_lock_drift() {
  local i=0 what=""
  fl_lock_file_resolve ""
  if [[ "$FL_LOCK_SOURCE" == "none" || ! -f "$FL_LOCK_FILE" ]] || ! fl_lock_load "$FL_LOCK_FILE"; then
    chk__set ok "skipped: no readable lockfile"
    return 0
  fi
  fl_lock_drift
  if [[ "${#DR_KIND[@]}" == "0" ]]; then chk__set ok "the bench matches $(basename "$FL_LOCK_FILE")"; return 0; fi
  while [[ "$i" -lt "${#DR_KIND[@]}" && "$i" -lt 3 ]]; do
    what="${what}${what:+, }${DR_KIND[$i]} ${DR_APP[$i]:-${DR_SITE[$i]}}"
    i=$((i + 1))
  done
  [[ "${#DR_KIND[@]}" -gt 3 ]] && what="${what}, and $((${#DR_KIND[@]} - 3)) more"
  chk__set warn "${#DR_KIND[@]} difference(s) from $(basename "$FL_LOCK_FILE"): ${what}" "benchbar lock apply   (benchbar lock check lists them)"
}

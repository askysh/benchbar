#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# app-plan.sh: app add as a reviewed plan with an approval token (0.6.0).
#
#   benchbar app add NAME|URL [--branch B] [--name N] [--site S | --all-sites] --dry-run --json
#   benchbar app add NAME|URL [same args] --apply TOKEN --yes [--json]
#
# The plan is read only: it resolves the app, asks the remote (git
# ls-remote under BatchMode, with a timeout), reads hooks.py from a
# shallow clone in a temp folder outside the bench (removed right after)
# for required_apps, and lists the steps. Its token is a hash of the plan
# and of the bench's apps.txt, apps/ folders and site list, like the ports
# token. --apply recomputes the plan under the CLI lock and runs exactly
# that plan, required apps included, without reading stdin; a token that
# no longer matches is refused before anything changes.

# fl_app_plan_wanted ARGS...: the args ask for --apply
fl_app_plan_wanted() {
  local a
  for a in "$@"; do case "$a" in --apply|--apply=*) return 0 ;; esac; done
  return 1
}

# fl__ap_timeout SECS OUT ERR COMMAND...: COMMAND with stdin closed, killed after SECS (exit 124)
fl__ap_timeout() {
  local secs="$1" out="$2" err="$3" pid ticks=0 code=0
  shift 3
  ( exec "$@" ) </dev/null >"$out" 2>"$err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$ticks" -ge $((secs * 10)) ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      printf 'timed out after %ss\n' "$secs" >>"$err"
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid" || code=$?
  return "$code"
}

# git with the user's own credentials that never prompts, with a timeout
fl__ap_git() {
  local secs="$1" out="$2" err="$3"
  shift 3
  fl__ap_timeout "$secs" "$out" "$err" env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' git "$@"
}

fl__ap_first_line() { grep -v '^[[:space:]]*$' "$1" 2>/dev/null | grep -v '^warning:' | head -n1 || true; }

# fl__ap_remote REPO [BRANCH]: 0 when the repo is readable without a prompt
# and BRANCH (a branch or tag, when given) exists; else 1 with AP__ERR.
# Without BRANCH it asks for the remote HEAD and sets AP__DEFAULT.
fl__ap_remote() {
  local repo="$1" branch="${2:-}" tmp code=0
  AP__DEFAULT=""; AP__ERR=""
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-plan.XXXXXX")"
  if [[ -z "$branch" ]]; then
    fl__ap_git "${FL_GIT_TIMEOUT:-30}" "$tmp/out" "$tmp/err" ls-remote --symref -- "$repo" HEAD || code=$?
  else
    fl__ap_git "${FL_GIT_TIMEOUT:-30}" "$tmp/out" "$tmp/err" ls-remote --exit-code --heads --tags -- "$repo" "$branch" || code=$?
  fi
  fl_log_file_append "$tmp/err"
  if [[ "$code" == "2" && -n "$branch" ]]; then AP__ERR="branch ${branch} not found in ${repo}"
  elif [[ "$code" != "0" ]]; then AP__ERR="cannot read ${repo} (git ls-remote exit ${code}): $(fl__ap_first_line "$tmp/err")"
  elif [[ -z "$branch" ]]; then
    AP__DEFAULT="$(sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$#\1#p' "$tmp/out" | head -n1)"
  fi
  rm -rf "$tmp"
  [[ -z "$AP__ERR" ]]
}

# fl__ap_read_hooks REPO BRANCH NAME: a shallow, blobless clone into a temp
# folder outside the bench, only hooks.py read from it. Sets AP__PKG (the
# package folder that holds hooks.py), AP__REQ (its required_apps, one
# per line) and AP__SHA (the commit it read); 1 with AP__ERR when it cannot
# be read.
fl__ap_read_hooks() {
  local repo="$1" branch="$2" name="$3" tmp code=0 path=""
  AP__PKG=""; AP__REQ=""; AP__ERR=""; AP__SHA=""
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-plan.XXXXXX")"
  fl__ap_git "${FL_GIT_CLONE_TIMEOUT:-120}" "$tmp/out" "$tmp/err" \
    clone --quiet --depth 1 --filter=blob:none --no-checkout --branch "$branch" -- "$repo" "$tmp/repo" || code=$?
  fl_log_file_append "$tmp/err"
  if [[ "$code" != "0" ]]; then
    AP__ERR="could not read hooks.py of ${repo} (git clone exit ${code}): $(fl__ap_first_line "$tmp/err")"
    rm -rf "$tmp"; return 1
  fi
  AP__SHA="$(git -C "$tmp/repo" rev-parse HEAD 2>/dev/null || true)"
  git -C "$tmp/repo" ls-tree -r --name-only HEAD >"$tmp/tree" 2>/dev/null || true
  if grep -qxF "${name}/hooks.py" "$tmp/tree"; then path="${name}/hooks.py"
  else path="$(grep -E '^[^/]+/hooks\.py$' "$tmp/tree" | head -n1 || true)"; fi
  if [[ -z "$path" ]]; then
    AP__ERR="${repo} (${branch}) has no <package>/hooks.py: not a Frappe app?"
    rm -rf "$tmp"; return 1
  fi
  code=0
  fl__ap_git "${FL_GIT_CLONE_TIMEOUT:-120}" "$tmp/hooks.py" "$tmp/err" -C "$tmp/repo" show "HEAD:${path}" || code=$?
  if [[ "$code" != "0" ]]; then
    AP__ERR="could not read ${path} from ${repo}: $(fl__ap_first_line "$tmp/err")"
    rm -rf "$tmp"; return 1
  fi
  AP__PKG="${path%/hooks.py}"
  AP__REQ="$(fl_hooks_required_apps "$tmp/hooks.py")"
  rm -rf "$tmp"
  return 0
}

# ---------------------------------------------------------------- the plan

fl__ap_err() { AP_ERRORS+=("$1"); AP_CAN_APPLY=0; }

# fl__ap_plain APP REPO BRANCH: 0 when neither holds '|', the separator of
# the plan's records; git allows it in a branch, the plan refuses it rather
# than run get-app with a branch it split differently
fl__ap_plain() {
  [[ "$2$3" != *"|"* ]] && return 0
  fl__ap_err "${1}: the repo or branch contains '|', which benchbar app add does not handle; add it with bench get-app yourself"
  return 1
}

# fl__ap_on_tag DIR TAG: 0 when apps/DIR is a detached HEAD at TAG's commit
# (git checks a tag out detached, so there is no branch to compare)
fl__ap_on_tag() {
  local head want
  [[ -z "$(fl_app_branch "$1")" && -n "$2" ]] || return 1
  head="$(git -C "$(fl_app_path "$1")" rev-parse -q --verify HEAD 2>/dev/null)" || return 1
  want="$(git -C "$(fl_app_path "$1")" rev-parse -q --verify "refs/tags/${2}^{commit}" 2>/dev/null)" || return 1
  [[ "$head" == "$want" ]]
}

# fl__ap_at_commit DIR SHA: 0 when the clone in apps/DIR is at SHA; sets AP__GOT
fl__ap_at_commit() {
  AP__GOT="$(git -C "$(fl_app_path "$1")" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "$2" && "$AP__GOT" == "$2" ]]
}

# fl__ap_required PARENT LIST: walks required_apps breadth first. A dep in
# the bench is noted; one config/apps.tsv or the team profile resolves is
# planned and its own hooks.py read; any other one blocks the plan.
fl__ap_required() {
  local queue=() qi=0 item dep parent seen=" " policy source present resolves repo branch line
  local saved_name="$FL_RES_NAME" saved_repo="$FL_RES_REPO" saved_branch="$FL_RES_BRANCH"
  while IFS= read -r dep; do [[ -n "$dep" ]] && queue+=("${dep}|$1"); done <<<"$2"
  while [[ "$qi" -lt "${#queue[@]}" ]]; do
    item="${queue[$qi]}"; qi=$((qi + 1))
    dep="${item%%|*}"; parent="${item#*|}"
    case "$seen" in *" $dep "*) continue ;; esac
    seen="${seen}${dep} "
    [[ "$dep" != -* ]] || { fl__ap_err "${parent} requires '${dep}', which is not a valid app name"; continue; }
    present=0; resolves=0; source=""; repo=""; branch=""
    if [[ -n "$(fl_app_existing_dir "$dep")" ]]; then present=1
    else
      policy="$(fl_lookup_app_policy "$dep" "$FL_PROFILE" 2>/dev/null || true)"
      if [[ -n "$policy" ]]; then
        resolves=1
        case "$policy" in *"|team profile "*) source="team_profile" ;; *) source="apps_tsv" ;; esac
        fl_app_resolve "$dep" "" ""
        repo="$FL_RES_REPO"; branch="$FL_RES_BRANCH"
      else
        fl__ap_err "${parent} requires ${dep}, which is not in the bench and not in $(fl_config_file apps.tsv) or the team profile"
      fi
    fi
    if [[ "$resolves" == "1" ]] && ! fl__ap_plain "$dep" "$repo" "$branch"; then repo="${repo//|/}"; branch="${branch//|/}"; resolves=0; fi
    if [[ "$resolves" != "1" ]]; then
      AP_REQ+=("${dep}|${parent}|${present}|${resolves}|${source}|${repo}|${branch}|")
      # a present app's own required_apps count too: one of them may be missing
      if [[ "$present" == "1" ]]; then
        while IFS= read -r line; do [[ -n "$line" ]] && queue+=("${line}|${dep}"); done < <(fl_app_required_apps "$(fl_app_existing_dir "$dep")")
      fi
      continue
    fi
    if fl__ap_read_hooks "$repo" "$branch" "$dep"; then
      AP_REQ+=("${dep}|${parent}|${present}|${resolves}|${source}|${repo}|${branch}|${AP__SHA}")
      AP_DEPS=("${dep}|${repo}|${branch}|${AP__SHA}" ${AP_DEPS[@]+"${AP_DEPS[@]}"})
      while IFS= read -r line; do [[ -n "$line" ]] && queue+=("${line}|${dep}"); done <<<"$AP__REQ"
    else
      AP_REQ+=("${dep}|${parent}|${present}|${resolves}|${source}|${repo}|${branch}|")
      fl__ap_err "$AP__ERR"
    fi
  done
  FL_RES_NAME="$saved_name"; FL_RES_REPO="$saved_repo"; FL_RES_BRANCH="$saved_branch"
}

# fl_app_add_plan TARGET BRANCH NAME ALL: sets the AP_* globals, AP_JSON and AP_TOKEN.
# Refusals that the plain app add also refuses exit 1 with the reason.
fl_app_add_plan() {
  local target="$1" branch="$2" name="$3" all="$4" s policy cur reqs="" sep i entry body state default
  local n by pr rs src rp br kind label cmd note
  AP_NAME=""; AP_REPO=""; AP_BRANCH=""; AP_BRANCH_SOURCE=""; AP_PRESENT=0; AP_REACHABLE=""; AP_PKG=""; AP_COMMIT=""
  AP_SITES=(); AP_INSTALL=(); AP_REQ=(); AP_DEPS=(); AP_ERRORS=(); AP_STEPS=(); AP_CAN_APPLY=1
  [[ "$all" == "1" && -n "${OPT_SITE:-}" ]] && fl_die "Pass --site or --all-sites, not both."
  [[ -z "$name" || "$name" =~ ^[a-z][a-z0-9_]*$ ]] || fl_die "Invalid app name: '${name}'." "Use a Python package name: lowercase letters, digits and '_'."
  [[ "$branch" != -* ]] || fl_die "Invalid branch: '${branch}'."
  fl_app_resolve "$target" "$branch" "$name"
  AP_NAME="$FL_RES_NAME"; AP_REPO="$FL_RES_REPO"; AP_BRANCH="$FL_RES_BRANCH"
  if [[ -n "$branch" ]]; then AP_BRANCH_SOURCE="given"; elif [[ -n "$AP_BRANCH" ]]; then AP_BRANCH_SOURCE="policy"; fi
  while IFS= read -r s; do [[ -n "$s" ]] && AP_SITES+=("$s"); done < <(fl_app_target_sites "$all")

  cur="$(fl_app_existing_dir "$AP_NAME")"
  if [[ -n "$cur" ]]; then
    AP_NAME="$cur"; AP_PRESENT=1; AP_PKG="$cur"
    fl_app_in_apps_txt "$cur" || fl_die "apps/${cur} exists but is not in sites/apps.txt (a get-app that did not finish?)." \
      "Move it aside (mv ${FL_BENCH_DIR}/apps/${cur} ~/${cur}.aside), then run this command again."
    s="$(fl_app_branch "$cur")"
    [[ -n "$AP_BRANCH" ]] || { AP_BRANCH="$s"; AP_BRANCH_SOURCE="present"; }
    [[ "$s" == "$AP_BRANCH" ]] || fl__ap_on_tag "$cur" "$AP_BRANCH" || fl_die "apps/${cur} is on ${s:-a detached HEAD}, not ${AP_BRANCH}." \
      "benchbar never replaces an app. To switch it yourself: cd ${FL_BENCH_DIR}/apps/${cur} && git fetch $(fl_app_remote "$cur") ${AP_BRANCH} && git checkout ${AP_BRANCH}"
    reqs="$(fl_app_required_apps "$cur")"
  else
    AP_REACHABLE=0
    if [[ -n "$AP_BRANCH" ]]; then
      if fl__ap_remote "$AP_REPO" "$AP_BRANCH"; then AP_REACHABLE=1
      else case "$AP__ERR" in "branch "*) AP_REACHABLE=1 ;; esac; fl__ap_err "$AP__ERR"; fi
    elif fl__ap_remote "$AP_REPO"; then
      AP_REACHABLE=1
      default="$AP__DEFAULT"
      # like app add: a URL for a known app follows the known branch when the remote has it
      policy="$(fl_lookup_app_policy "$AP_NAME" "$FL_PROFILE" 2>/dev/null || true)"; policy="${policy%%|*}"
      if [[ -n "$policy" ]] && fl__ap_remote "$AP_REPO" "$policy"; then AP_BRANCH="$policy"; AP_BRANCH_SOURCE="policy"
      elif [[ -n "$default" ]]; then AP_BRANCH="$default"; AP_BRANCH_SOURCE="remote_default"
      else fl__ap_err "could not tell the default branch of ${AP_REPO}; pass --branch"; fi
    else
      fl__ap_err "$AP__ERR"
    fi
    if [[ "$AP_CAN_APPLY" == "1" ]] && fl__ap_plain "$AP_NAME" "$AP_REPO" "$AP_BRANCH"; then
      if fl__ap_read_hooks "$AP_REPO" "$AP_BRANCH" "$AP_NAME"; then
        AP_PKG="$AP__PKG"; reqs="$AP__REQ"; AP_COMMIT="$AP__SHA"
        # bench names the folder after the package, so that is the app
        if [[ -z "$name" && "$AP_PKG" != "$AP_NAME" ]]; then
          AP_NAME="$AP_PKG"
          [[ -z "$(fl_app_existing_dir "$AP_NAME")" ]] || fl__ap_err "the package is ${AP_NAME}, which the bench already has: run benchbar app add ${AP_NAME}"
        fi
      else
        fl__ap_err "$AP__ERR"
      fi
    fi
  fi
  [[ -z "$reqs" ]] || fl__ap_required "$AP_NAME" "$reqs"

  # which target sites still need it (a fresh read of their app lists)
  if [[ "${#AP_SITES[@]}" -gt 0 ]]; then
    fl_site_apps_refresh "${AP_SITES[@]}" >/dev/null 2>&1 || true
    for s in "${AP_SITES[@]}"; do
      if [[ "$AP_PRESENT" == "1" ]] && fl_site_has_app "$s" "$AP_NAME"; then continue; fi
      AP_INSTALL+=("$s")
    done
  fi

  # the steps, in the order --apply runs them
  for entry in ${AP_DEPS[@]+"${AP_DEPS[@]}"}; do
    IFS='|' read -r n rp br _ <<<"$entry"
    AP_STEPS+=("clone_required|${n}|Clone ${n}|bench get-app --skip-assets --branch ${br} ${rp}|required app of ${AP_NAME} (hooks.py required_apps); get-app also pip installs it into the bench env")
  done
  if [[ "$AP_PRESENT" == "0" ]]; then
    AP_STEPS+=("clone|${AP_NAME}|Clone ${AP_NAME}|bench get-app --skip-assets --branch ${AP_BRANCH:-?} ${AP_REPO}|get-app clones into apps/${AP_NAME}, pip installs it into the bench env and adds it to sites/apps.txt; never --overwrite or --resolve-deps")
  fi
  if [[ "$AP_PRESENT" == "0" || "${#AP_DEPS[@]}" -gt 0 ]]; then
    # the required apps first, like app add
    s=""
    for entry in ${AP_DEPS[@]+"${AP_DEPS[@]}"}; do s="${s:+${s},}${entry%%|*}"; done
    [[ "$AP_PRESENT" == "0" ]] && s="${s:+${s},}${AP_NAME}"
    if [[ "$s" == *,* ]]; then cmd="bench build --apps ${s}"; else cmd="bench build --app ${s}"; fi
    AP_STEPS+=("build|${s}|Build|${cmd}|the new apps' JS and CSS")
  fi
  for s in ${AP_INSTALL[@]+"${AP_INSTALL[@]}"}; do
    AP_STEPS+=("install|${s}|Install on ${s}|bench --site ${s} install-app ${AP_NAME}|changes the site's database: installs ${AP_NAME} (and its required apps) and syncs their DocTypes and patches, like a migrate of these apps only; no backup is taken first")
  done
  if [[ "$AP_PRESENT" == "0" || "${#AP_DEPS[@]}" -gt 0 ]]; then
    AP_STEPS+=("restart||Restart|benchbar restart|only when the bench is running, so the new code is served")
  fi

  # JSON
  body="$(printf '"bench":%s,"profile":%s,"target":%s,"app":%s,"package":%s,"repo":%s,"branch":%s,"commit":%s,"branch_source":%s,"present":%s,"reachable":%s,' \
    "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$FL_PROFILE")" "$(fl_json_str "$(fl_url_strip_userinfo "$target")")" \
    "$(fl_json_str "$AP_NAME")" "$(fl_json_str "$AP_PKG")" "$(fl_json_str "$AP_REPO")" "$(fl_json_str "$AP_BRANCH")" "$(fl_json_str "$AP_COMMIT")" \
    "$(fl_json_str "$AP_BRANCH_SOURCE")" "$(fl_json_bool "$AP_PRESENT")" \
    "$(if [[ -z "$AP_REACHABLE" ]]; then printf null; else fl_json_bool "$AP_REACHABLE"; fi)")"
  body="${body}\"sites\":["; sep=""
  for s in ${AP_SITES[@]+"${AP_SITES[@]}"}; do
    i=1; case " ${AP_INSTALL[*]:-} " in *" $s "*) i=0 ;; esac
    body="${body}${sep}{\"name\":$(fl_json_str "$s"),\"installed\":$(fl_json_bool "$i")}"; sep=","
  done
  body="${body}],\"sites_error\":$(fl_json_str "${FL_SITE_APPS_ERROR:-}"),\"required_apps\":["; sep=""
  for entry in ${AP_REQ[@]+"${AP_REQ[@]}"}; do
    IFS='|' read -r n by pr rs src rp br sha <<<"$entry"
    body="${body}${sep}{\"name\":$(fl_json_str "$n"),\"required_by\":$(fl_json_str "$by"),\"present\":$(fl_json_bool "$pr"),\"resolves\":$(fl_json_bool "$rs"),\"source\":$(fl_json_str "$src"),\"repo\":$(fl_json_str "$rp"),\"branch\":$(fl_json_str "$br"),\"commit\":$(fl_json_str "$sha")}"; sep=","
  done
  body="${body}],\"missing_required\":["; sep=""
  for entry in ${AP_REQ[@]+"${AP_REQ[@]}"}; do
    IFS='|' read -r n by pr _ <<<"$entry"
    [[ "$pr" == "1" ]] && continue
    body="${body}${sep}$(fl_json_str "$n")"; sep=","
  done
  body="${body}],\"steps\":["; sep=""
  for entry in ${AP_STEPS[@]+"${AP_STEPS[@]}"}; do
    IFS='|' read -r kind _ label cmd note <<<"$entry"
    body="${body}${sep}{\"kind\":$(fl_json_str "$kind"),\"name\":$(fl_json_str "$label"),\"command\":$(fl_json_str "$cmd"),\"note\":$(fl_json_str "$note")}"; sep=","
  done
  body="${body}],\"errors\":$(fl_json_str_array ${AP_ERRORS[@]+"${AP_ERRORS[@]}"}),\"changes\":$(fl_json_bool "$([[ "${#AP_STEPS[@]}" -gt 0 ]] && printf 1 || printf 0)"),\"can_apply\":$(fl_json_bool "$AP_CAN_APPLY")"
  # the bench state the plan was made against: a changed apps.txt, apps/
  # folder or site list makes the token stale
  state="$(printf 'apps.txt\n%s\napps\n%s\nsites\n%s\n' "$(fl_apps_txt)" "$(fl__apps_dirs)" "$(fl_sites_list)")"
  AP_TOKEN="$(printf '%s\n%s\n' "$body" "$state" | shasum -a 256 | awk '{print $1}')"
  AP_JSON="$(printf '{"schema_version":%d,"cli_version":"%s",%s,"token":"%s"}' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$body" "$AP_TOKEN")"
}

fl__ap_print_plan() {
  local rows=("#|Step|Command") i=1 entry label cmd e
  printf '\n%sPlan%s %s (%s) from %s\n' "$FL_BOLD" "$FL_RESET" "$AP_NAME" "${AP_BRANCH:-?}" "$AP_REPO"
  for entry in ${AP_STEPS[@]+"${AP_STEPS[@]}"}; do
    IFS='|' read -r _ _ label cmd _ <<<"$entry"
    rows+=("${i}|${label}|${cmd}"); i=$((i + 1))
  done
  [[ "${#AP_STEPS[@]}" -gt 0 ]] && fl_table "${rows[@]}"
  for e in ${AP_ERRORS[@]+"${AP_ERRORS[@]}"}; do fl_fail "$e"; done
  return 0
}

# ---------------------------------------------------------------- the command

fl_cmd_app_add_planned() {
  local target="" branch="" name="" all=0 token="" json="$OPT_JSON" apply=0 code=0 i entry kind arg label s built=() sep=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --branch) branch="${2:-}"; shift 2 ;;
      --branch=*) branch="${1#*=}"; shift ;;
      --name) name="${2:-}"; shift 2 ;;
      --name=*) name="${1#*=}"; shift ;;
      --all-sites) all=1; shift ;;
      --apply) apply=1; token="${2:-}"; shift 2 || shift ;;
      --apply=*) apply=1; token="${1#*=}"; shift ;;
      -*) fl_die "Unknown option for app add: $1" "Use: benchbar app add NAME|URL [--branch B] [--name N] [--site S | --all-sites] --dry-run --json, then --apply TOKEN --yes" ;;
      *) [[ -z "$target" ]] && target="$1"; shift ;;
    esac
  done
  # JSON on fd 3, every line of text on stderr
  if [[ "$json" == "1" ]]; then exec 3>&1 1>&2; FL_PLAIN=1; fl_ui_init; else exec 3>&1; fi
  fl_require_bench
  [[ -n "$target" ]] || fl_die "Usage: benchbar app add NAME|URL [--branch B] [--name N] [--site S | --all-sites] --dry-run --json"
  if [[ "$apply" == "1" ]]; then
    [[ "${FL_DRY_RUN:-0}" != "1" ]] || fl_die "--apply runs the plan; --dry-run shows it. Pass one of them."
    [[ "$token" =~ ^[0-9a-f]{64}$ ]] || fl_die "--apply needs the token of a plan." "benchbar app add ${target} ... --dry-run --json prints it"
    [[ "${FL_ASSUME_YES:-0}" == "1" ]] || fl_die "Review the plan (--dry-run --json), then pass its token with --apply TOKEN --yes."
  else
    [[ "${FL_DRY_RUN:-0}" == "1" ]] || fl_die "--json shows the plan only; add --dry-run (then --apply TOKEN --yes to run it)." "benchbar app add ${target} --dry-run --json"
  fi
  # never a question on stdin: the plan was shown and approved already
  exec 0</dev/null
  fl_app_add_plan "$target" "$branch" "$name" "$all"
  if [[ "$apply" == "0" ]]; then
    printf '%s\n' "$AP_JSON" >&3
    return 0
  fi

  fl_header "benchbar app add --apply" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "${AP_INSTALL[*]:-no site}"
  [[ "$token" == "$AP_TOKEN" ]] || fl_die "The app add plan changed since it was shown (apps.txt, apps/, the sites or the remote). Nothing was changed." \
    "Review a fresh plan: benchbar app add ${target} ... --dry-run --json, then pass its token."
  fl__ap_print_plan
  [[ "$AP_CAN_APPLY" == "1" ]] || fl_die "The plan cannot be applied (see above). Nothing was changed."
  if [[ "${#AP_STEPS[@]}" == "0" ]]; then
    printf '\n'; fl_ok "unchanged: ${AP_NAME} is on ${AP_BRANCH}${AP_SITES[*]:+ and installed on ${AP_SITES[*]}}, nothing to do"
    [[ "$json" == "1" ]] && fl__ap_result_json 0 >&3
    return 0
  fi

  local labels=() stop=0 e rp br sha
  for entry in "${AP_STEPS[@]}"; do IFS='|' read -r _ _ label _ _ <<<"$entry"; labels+=("$label"); done
  fl_steps_define "${labels[@]}"
  i=0
  for entry in "${AP_STEPS[@]}"; do
    IFS='|' read -r kind arg label _ _ <<<"$entry"
    # a failed clone stops the run: the steps after it are skipped
    if [[ "$stop" == "1" ]]; then FL_STEP_STATUS[i]="skipped"; i=$((i + 1)); continue; fi
    fl_step_begin "$i"
    case "$kind" in
      clone_required|clone)
        rp=""; br=""; sha=""
        for e in ${AP_DEPS[@]+"${AP_DEPS[@]}"} "${AP_NAME}|${AP_REPO}|${AP_BRANCH}|${AP_COMMIT}"; do
          [[ "${e%%|*}" == "$arg" ]] && { IFS='|' read -r _ rp br sha <<<"$e"; break; }
        done
        if ! fl_app_clone "$arg" "$rp" "$br"; then fl_step_end failed; code=1; stop=1
        elif ! fl__ap_at_commit "$FL_CLONED_DIR" "$sha"; then
          # the branch moved between the plan and get-app: build and install
          # would run code nobody reviewed
          fl_step_end failed; code=1; stop=1
          fl_fail "${arg}: ${br} moved after the plan was made (planned ${sha:0:12}, cloned ${AP__GOT:0:12}); nothing was built or installed."
          fl_fix "Review a fresh plan: benchbar app add ${target} ... --dry-run --json"
        else built+=("$FL_CLONED_DIR"); fl_step_end "done"; fi ;;
      build)
        s="$arg"
        [[ "${#built[@]}" -gt 0 ]] && s="$(IFS=,; printf '%s' "${built[*]}")"
        if fl_app_build "$s"; then fl_step_end "done"; else fl_step_end failed; fl_fix "cd ${FL_BENCH_DIR} && bench build --apps ${s}"; code=1; fi ;;
      install)
        if fl_app_install_on_sites "$AP_NAME" "$arg"; then fl_step_end "done"; else fl_step_end failed; code=1; fi ;;
      restart)
        fl_bench_redis_down
        if ! fl_bench_is_running; then fl_step_end skipped "not running"
        elif fl_app_restart_if_running; then fl_step_end "done"
        else fl_step_end failed; code=1; fi ;;
    esac
    i=$((i + 1))
  done
  fl_bench_redis_down
  if [[ -d "$(fl_app_path "$AP_NAME")" ]]; then
    s="$AP_BRANCH"
    # a tag is checked out detached: its commit is the check, not a branch name
    if fl__ap_on_tag "$AP_NAME" "$AP_BRANCH"; then fl_ok "apps/${AP_NAME} is at tag ${AP_BRANCH}"; s=""; fi
    fl_app_verify "$AP_NAME" "$s" ${AP_INSTALL[@]+"${AP_INSTALL[@]}"} || code=1
  fi
  fl_steps_summary
  [[ "$json" == "1" ]] && fl__ap_result_json "$code" >&3
  return "$code"
}

# the result of --apply --json: the plan's app, the token and each step's status
fl__ap_result_json() {
  local ok=1 i=0 sep="" out entry kind label
  [[ "$1" == "0" ]] || ok=0
  out="$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"app":%s,"branch":%s,"token":"%s","applied":true,"ok":%s,"steps":[' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$AP_NAME")" "$(fl_json_str "$AP_BRANCH")" "$AP_TOKEN" "$(fl_json_bool "$ok")")"
  for entry in ${AP_STEPS[@]+"${AP_STEPS[@]}"}; do
    IFS='|' read -r kind _ label _ _ <<<"$entry"
    out="${out}${sep}{\"kind\":$(fl_json_str "$kind"),\"name\":$(fl_json_str "$label"),\"status\":$(fl_json_str "${FL_STEP_STATUS[$i]:-pending}")}"; sep=","
    i=$((i + 1))
  done
  printf '%s]}\n' "$out"
}

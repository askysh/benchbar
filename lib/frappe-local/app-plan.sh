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

# git with the user's own credentials that never prompts, with a timeout
fl__ap_git() {
  local secs="$1" out="$2" err="$3"
  shift 3
  fl_run_capture_timeout "$secs" "$out" "$err" env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' git "$@"
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
# planned and its own hooks.py read; any other one blocks the plan. Every
# "PARENT requires DEP" met on the way goes to AP_EDGES (PARENT|DEP), which
# fl__ap_toposort orders AP_DEPS by.
fl__ap_required() {
  local queue=() qi=0 item dep parent seen=" " policy source present resolves repo branch line
  local saved_name="$FL_RES_NAME" saved_repo="$FL_RES_REPO" saved_branch="$FL_RES_BRANCH"
  while IFS= read -r dep; do [[ -n "$dep" ]] && queue+=("${dep}|$1"); done <<<"$2"
  while [[ "$qi" -lt "${#queue[@]}" ]]; do
    item="${queue[$qi]}"; qi=$((qi + 1))
    dep="${item%%|*}"; parent="${item#*|}"
    AP_EDGES+=("${parent}|${dep}")
    # the app being added is a node of the graph, not something to clone first
    [[ "$AP_PRESENT" == "0" && "$dep" == "$AP_NAME" ]] && continue
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

# fl__ap_blockers NODE ALL: sets AP_BLK to the apps to clone that NODE has to
# wait for: the ones it requires, and the ones an app already in the bench
# between them requires (A requires P, P is in the bench, P requires B: B
# goes in before A)
fl__ap_blockers() {
  local queue=("$1") qi=0 seen=" $1 " cur edge d
  AP_BLK=""
  while [[ "$qi" -lt "${#queue[@]}" ]]; do
    cur="${queue[$qi]}"; qi=$((qi + 1))
    for edge in ${AP_EDGES[@]+"${AP_EDGES[@]}"}; do
      [[ "${edge%%|*}" == "$cur" ]] || continue
      d="${edge#*|}"
      # an app that requires itself is a cycle of one
      if [[ "$d" == "$1" && "$cur" == "$1" ]]; then AP_BLK="${AP_BLK}${d} "; continue; fi
      case "$seen" in *" $d "*) continue ;; esac
      seen="${seen}${d} "
      case "$2" in *" $d "*) AP_BLK="${AP_BLK}${d} " ;; *) queue+=("$d") ;; esac
    done
  done
}

# fl__ap_toposort: puts AP_DEPS in an order where every app comes after the
# apps it requires (Kahn's algorithm over AP_EDGES; get-app pip installs as it
# clones, so a dependency has to be in the bench first). Among the apps that
# are ready the one earliest in the list goes first, and the list is the walk
# reversed with the main app last, so a plan that was already in a valid
# order does not change. Sets AP_ORDER (names, the main app last when it is
# cloned). A cycle is a plan error that names it.
fl__ap_toposort() {
  local nodes=() placed=" " all=" " entry n pick d blocked total deps=()
  for entry in ${AP_DEPS[@]+"${AP_DEPS[@]}"}; do nodes+=("${entry%%|*}"); done
  [[ "$AP_PRESENT" == "1" ]] || nodes+=("$AP_NAME")
  AP_ORDER=()
  for n in ${nodes[@]+"${nodes[@]}"}; do all="${all}${n} "; done
  total="${#nodes[@]}"
  while [[ "${#AP_ORDER[@]}" -lt "$total" ]]; do
    pick=""
    for n in "${nodes[@]}"; do
      case "$placed" in *" $n "*) continue ;; esac
      blocked=0
      fl__ap_blockers "$n" "$all"
      for d in $AP_BLK; do
        case "$placed" in *" $d "*) ;; *) blocked=1; break ;; esac
      done
      if [[ "$blocked" == "0" ]]; then pick="$n"; break; fi
    done
    if [[ -z "$pick" ]]; then
      # the old order, so the rest of the plan still reads; the error stops it
      AP_ORDER=()
      for n in "${nodes[@]}"; do AP_ORDER+=("$n"); done
      fl__ap_cycle "$placed" "$all"
      return 1
    fi
    placed="${placed}${pick} "
    AP_ORDER+=("$pick")
  done
  # AP_DEPS in that order (the main app, last, is not one of them)
  for n in ${AP_ORDER[@]+"${AP_ORDER[@]}"}; do
    for entry in ${AP_DEPS[@]+"${AP_DEPS[@]}"}; do
      if [[ "${entry%%|*}" == "$n" ]]; then deps+=("$entry"); fi
    done
  done
  AP_DEPS=(${deps[@]+"${deps[@]}"})
  return 0
}

# fl__ap_cycle PLACED ALL: walks from an app that could not be placed along
# the requirements that could not be placed either until one repeats, and
# names the loop: "a -> b -> a"
fl__ap_cycle() {
  local placed="$1" all="$2" start="" n path="" cur next p d seen loop=""
  for n in $all; do
    case "$placed" in *" $n "*) ;; *) start="$n"; break ;; esac
  done
  cur="$start"; path="$start"
  while true; do
    next=""
    fl__ap_blockers "$cur" "$all"
    for d in $AP_BLK; do
      case "$placed" in *" $d "*) continue ;; esac
      next="$d"; break
    done
    [[ -n "$next" ]] || break
    seen=0
    for n in $path; do [[ "$n" == "$next" ]] && seen=1; done
    path="${path} ${next}"
    [[ "$seen" == "0" ]] || break
    cur="$next"
  done
  # from the first visit of the repeated app to the second
  n="${path##* }"
  for p in $path; do
    if [[ -n "$loop" || "$p" == "$n" ]]; then loop="${loop}${loop:+ -> }${p}"; fi
  done
  fl__ap_err "required_apps cycle: ${loop}"
}

# fl_app_add_plan TARGET BRANCH NAME ALL: sets the AP_* globals, AP_JSON and AP_TOKEN.
# Refusals that the plain app add also refuses exit 1 with the reason.
fl_app_add_plan() {
  local target="$1" branch="$2" name="$3" all="$4" s policy cur reqs="" sep i entry body state default
  local n by pr rs src rp br kind label cmd note st pd_build="" pd_py="" pd_restart=0 pd_sites=() a
  AP_NAME=""; AP_REPO=""; AP_BRANCH=""; AP_BRANCH_SOURCE=""; AP_PRESENT=0; AP_REACHABLE=""; AP_PKG=""; AP_COMMIT=""
  AP_SITES=(); AP_INSTALL=(); AP_REQ=(); AP_DEPS=(); AP_ERRORS=(); AP_STEPS=(); AP_CAN_APPLY=1
  AP_EDGES=(); AP_ORDER=(); AP_PENDING=0; AP_REASON=""
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
  fl__ap_toposort || true

  # an earlier app add of this app that stopped half way: what it did not
  # finish (build, install, restart) is part of this plan
  if [[ -n "$AP_NAME" ]] && fl_pending_corrupt "$AP_NAME"; then
    fl__ap_err "the pending record of ${AP_NAME} cannot be read (cut short or from another version); it is kept and nothing runs from it: benchbar app update ${AP_NAME} --discard-pending drops it and stops"
  elif [[ -n "$AP_NAME" ]] && fl_pending_load "$AP_NAME" && [[ "$PD_OP" == "app_add" ]]; then
    AP_PENDING=1
    AP_REASON="an earlier app add of ${AP_NAME} stopped at ${PD_FAILED:-an unknown step}${PD_REASON:+ (${PD_REASON})}; the steps it did not finish are in this plan"
    # shellcheck disable=SC2153  # PD_STEPS is set by fl_pending_load (apps.sh)
    for st in ${PD_STEPS[@]+"${PD_STEPS[@]}"}; do
      IFS='|' read -r kind n _ <<<"$st"
      case "$kind" in
        build) for a in ${n//,/ }; do [[ -z "$(fl_app_existing_dir "$a")" ]] || pd_build="${pd_build}${pd_build:+,}$(fl_app_existing_dir "$a")"; done ;;
        install) fl_sites_list | grep -qxF "$n" && pd_sites+=("$n") ;;
        requirements_python) for a in ${n//,/ }; do [[ -z "$(fl_app_existing_dir "$a")" ]] || pd_py="${pd_py}${pd_py:+,}$(fl_app_existing_dir "$a")"; done ;;
        restart) pd_restart=1 ;;
      esac
    done
    for s in ${pd_sites[@]+"${pd_sites[@]}"}; do
      case " ${AP_SITES[*]:-} " in *" $s "*) ;; *) AP_SITES+=("$s") ;; esac
    done
  fi

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
  s=""
  if [[ "$AP_PRESENT" == "0" || "${#AP_DEPS[@]}" -gt 0 ]]; then
    # the required apps first, like app add
    for entry in ${AP_DEPS[@]+"${AP_DEPS[@]}"}; do s="${s:+${s},}${entry%%|*}"; done
    [[ "$AP_PRESENT" == "0" ]] && s="${s:+${s},}${AP_NAME}"
  fi
  # an app whose get-app cloned it and then failed (its pip install, typically)
  # has no Python requirements in the env yet: they come before the build
  if [[ -n "$pd_py" ]]; then
    AP_STEPS+=("requirements_python|${pd_py}|Python requirements|bench setup requirements --python ${pd_py//,/ && bench setup requirements --python }|a get-app that failed after the clone may not have installed the app into the bench env")
  fi
  # apps a stopped run cloned but never built come first
  for a in ${pd_build//,/ }; do
    case ",${s}," in *",${a},"*) ;; *) s="${a}${s:+,${s}}" ;; esac
  done
  if [[ -n "$s" ]]; then
    if [[ "$s" == *,* ]]; then cmd="bench build --apps ${s}"; else cmd="bench build --app ${s}"; fi
    AP_STEPS+=("build|${s}|Build|${cmd}|the new apps' JS and CSS")
  fi
  for s in ${AP_INSTALL[@]+"${AP_INSTALL[@]}"}; do
    AP_STEPS+=("install|${s}|Install on ${s}|bench --site ${s} install-app ${AP_NAME}|changes the site's database: installs ${AP_NAME} (and its required apps) and syncs their DocTypes and patches, like a migrate of these apps only; no backup is taken first")
  done
  if [[ "$AP_PRESENT" == "0" || "${#AP_DEPS[@]}" -gt 0 || "$pd_restart" == "1" ]]; then
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
  body="${body}],\"order\":$(fl_json_str_array ${AP_ORDER[@]+"${AP_ORDER[@]}"}),\"steps\":["; sep=""
  for entry in ${AP_STEPS[@]+"${AP_STEPS[@]}"}; do
    IFS='|' read -r kind _ label cmd note <<<"$entry"
    body="${body}${sep}{\"kind\":$(fl_json_str "$kind"),\"name\":$(fl_json_str "$label"),\"command\":$(fl_json_str "$cmd"),\"note\":$(fl_json_str "$note")}"; sep=","
  done
  body="${body}],\"errors\":$(fl_json_str_array ${AP_ERRORS[@]+"${AP_ERRORS[@]}"}),\"changes\":$(fl_json_bool "$([[ "${#AP_STEPS[@]}" -gt 0 ]] && printf 1 || printf 0)"),\"can_apply\":$(fl_json_bool "$AP_CAN_APPLY"),\"reason\":$(fl_json_str "$AP_REASON")"
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
  [[ -z "$AP_REASON" ]] || fl_warn "$AP_REASON"
  [[ "${#AP_STEPS[@]}" -gt 0 ]] && fl_table "${rows[@]}"
  for e in ${AP_ERRORS[@]+"${AP_ERRORS[@]}"}; do fl_fail "$e"; done
  return 0
}

# ---------------------------------------------------------------- the plain command

# fl__ap_error_hints: what to do about the plan's errors, as app add always
# said: the remote's branches for a branch it lacks, the way to give git
# access for a repo it cannot read, how to add a required app benchbar has no
# URL for
fl__ap_error_hints() {
  local e heads entry n pr rs
  for e in ${AP_ERRORS[@]+"${AP_ERRORS[@]}"}; do
    case "$e" in
      "branch ${AP_BRANCH} not found in "*)
        heads="$(fl_git_batch ls-remote --heads -- "$AP_REPO" 2>/dev/null | sed 's#.*refs/heads/##' | head -n 20 | tr '\n' ' ')"
        fl_note "remote branches: ${heads:-none}"
        fl_fix "pass one of them with --branch" ;;
      "cannot read ${AP_REPO} "*) fl_repo_access_hint "$AP_REPO" ;;
    esac
  done
  for entry in ${AP_REQ[@]+"${AP_REQ[@]}"}; do
    IFS='|' read -r n _ pr rs _ <<<"$entry"
    [[ "$pr" == "0" && "$rs" == "0" ]] || continue
    fl_fix "benchbar app add <git URL of ${n}> --branch BRANCH, then run this command again"
  done
}

# fl_cmd_app_add: app add from a terminal. The same plan the agents review
# (--dry-run --json, then --apply TOKEN), printed, asked once, and applied by
# the same loop, so both ways clone, build and install in the same order and
# leave the same record behind when a step fails.
fl_cmd_app_add() {
  local target="" branch="" name="" all=0 code=0 entry dep_list=""
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
  fl_app_add_plan "$target" "$branch" "$name" "$all"
  fl_header "benchbar app add" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "${AP_SITES[*]:-no site}"
  if [[ "$AP_PRESENT" == "1" ]]; then
    fl_ok "apps/${AP_NAME} is already on ${AP_BRANCH}"
    fl_app_dirty "$AP_NAME" && fl_warn "apps/${AP_NAME} has local changes; add only installs it on sites (app update and lock apply refuse a dirty app)"
  fi
  if [[ "${#AP_STEPS[@]}" == "0" && "${#AP_ERRORS[@]}" == "0" ]]; then
    fl__ap_settle || return 1
    printf '\n'
    fl_ok "unchanged: ${AP_NAME} is on ${AP_BRANCH}${AP_SITES[*]:+ and installed on ${AP_SITES[*]}}, nothing to do"
    [[ "${#AP_SITES[@]}" != "0" ]] || fl_info "install it on a site with: benchbar app install ${AP_NAME} --site SITE"
    return 0
  fi
  if [[ "${#AP_DEPS[@]}" -gt 0 ]]; then
    for entry in "${AP_DEPS[@]}"; do dep_list="${dep_list}${dep_list:+, }${entry%%|*}"; done
    fl_info "${AP_NAME} requires apps that are not in the bench yet (hooks.py required_apps): ${dep_list}"
  fi
  fl__ap_print_plan
  fl__ap_error_hints
  [[ "$AP_CAN_APPLY" == "1" ]] || return 1
  [[ "${#AP_SITES[@]}" != "0" ]] || fl_info "no --site given: the app is cloned and built, not installed on a site"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    printf '\n'; fl_info "dry-run: nothing was changed"
    return 0
  fi
  fl_confirm "Apply ${#AP_STEPS[@]} step(s)?" || { fl_warn "Cancelled. Nothing was changed."; return 1; }
  fl__ap_apply "$target" || code=$?
  return "$code"
}

# ---------------------------------------------------------------- the command

fl_cmd_app_add_planned() {
  local target="" branch="" name="" all=0 token="" json="$OPT_JSON" apply=0 code=0
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
  if [[ "$json" == "1" ]]; then fl_json_doc_begin; elif [[ "${FL_JSONL:-0}" != "1" ]]; then exec 3>&1; fi
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
    fl_doc_emit 0 "$AP_JSON" plan
    return 0
  fi

  fl_header "benchbar app add --apply" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "${AP_INSTALL[*]:-no site}"
  [[ "$token" == "$AP_TOKEN" ]] || fl_die "The app add plan changed since it was shown (apps.txt, apps/, the sites or the remote). Nothing was changed." \
    "Review a fresh plan: benchbar app add ${target} ... --dry-run --json, then pass its token."
  fl__ap_print_plan
  [[ "$AP_CAN_APPLY" == "1" ]] || fl_die "The plan cannot be applied (see above). Nothing was changed."
  if [[ "${#AP_STEPS[@]}" == "0" ]]; then
    fl__ap_settle || { [[ "$json" == "1" ]] && fl_doc_emit 1 "$(fl__ap_result_json 1)"; return 1; }
    printf '\n'; fl_ok "unchanged: ${AP_NAME} is on ${AP_BRANCH}${AP_SITES[*]:+ and installed on ${AP_SITES[*]}}, nothing to do"
    [[ "$json" == "1" ]] && fl_doc_emit 0 "$(fl__ap_result_json 0)"
    return 0
  fi

  fl__ap_apply "$target" || code=$?
  [[ "$json" == "1" ]] && fl_doc_emit "$code" "$(fl__ap_result_json "$code")"
  return "$code"
}

# fl__ap_record FAILED REASON DONE: the pending record of this app add, with
# the steps of AP_STEPS whose index is not in DONE (a string like " 0 1 ")
fl__ap_record() {
  local left=() entry kind arg label i=0
  for entry in "${AP_STEPS[@]}"; do
    case "$3" in *" $i "*) ;; *) IFS='|' read -r kind arg label _ <<<"$entry"; left+=("${kind}|${arg}|${label}") ;; esac
    i=$((i + 1))
  done
  fl_pending_write app_add "$AP_NAME" "$AP_BRANCH" "" "$AP_COMMIT" "$1" "$2" ${left[@]+"${left[@]}"}
}

# fl__ap_verify SITE...: the verify pass of the app: apps.txt, its branch (or
# tag) and the sites
fl__ap_verify() {
  local b="$AP_BRANCH"
  # a tag is checked out detached: its commit is the check, not a branch name
  if fl__ap_on_tag "$AP_NAME" "$AP_BRANCH"; then fl_ok "apps/${AP_NAME} is at tag ${AP_BRANCH}"; b=""; fi
  fl_app_verify "$AP_NAME" "$b" "$@"
}

# fl__ap_settle: a record of an earlier add and no step left to run (the
# install was done by hand, a site was dropped, or only the verify failed):
# verify, and clear the record when it passes; otherwise say what is wrong.
# Returns 1 when the app does not verify.
fl__ap_settle() {
  [[ "$AP_PENDING" == "1" && "${#AP_STEPS[@]}" == "0" ]] || return 0
  if [[ -d "$(fl_app_path "$AP_NAME")" ]] && fl__ap_verify ${AP_SITES[@]+"${AP_SITES[@]}"}; then
    fl_pending_remove "$AP_NAME"
    if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then fl_ok "the unfinished app add of ${AP_NAME} is complete; its record would be removed"
    else fl_ok "the unfinished app add of ${AP_NAME} is complete; its record is removed"; fi
    return 0
  fi
  fl_fail "the unfinished app add of ${AP_NAME} has no step left, but ${AP_NAME} does not verify (above)"
  fl_fix "benchbar app update ${AP_NAME} --discard-pending   (drops the record and stops; nothing else runs)"
  return 1
}

# fl__ap_apply TARGET: runs AP_STEPS in order, with the dependencies
# clone_required -> clone -> build -> install and restart. A step whose
# requirement failed is skipped ("after failed <step>"); installs on
# different sites do not depend on each other, and a failed install does not
# keep the restart from running. The steps that did not finish stay in the
# pending record, which goes away only when all are done and verify is green.
# Returns 1 when a step or the verify pass failed.
fl__ap_apply() {
  local target="$1" labels=() entry kind arg label i=0 code=0 e rp br sha s a res fail_from reason
  local clone_failed="" build_failed="" py_failed="" first_kind="" first_reason="" done_set=" " cloned=() ids=()
  AP_STEP_NOTE=()
  for entry in "${AP_STEPS[@]}"; do
    IFS='|' read -r kind arg label _ <<<"$entry"
    labels+=("$label")
    # the stream's step ids, KIND_TARGET as app update names its own
    ids+=("${kind}${arg:+_${arg}}")
  done
  fl_steps_define "${labels[@]}"
  fl_steps_ids "${ids[@]}"
  # the record first: whatever stops this run leaves what is still to do
  fl__ap_record "" "" "$done_set" || { fl_fail "nothing was run: without its record a stop could not be finished later"; return 1; }
  for entry in "${AP_STEPS[@]}"; do
    IFS='|' read -r kind arg label _ <<<"$entry"
    res=""
    if [[ -n "$clone_failed" ]]; then res="after failed ${clone_failed}"
    elif [[ -n "$py_failed" && ( "$kind" == "build" || "$kind" == "install" || "$kind" == "restart" ) ]]; then res="after failed requirements_python"
    elif [[ -n "$build_failed" && ( "$kind" == "install" || "$kind" == "restart" ) ]]; then res="after failed build"; fi
    if [[ -n "$res" ]]; then
      FL_STEP_CURRENT="$i"; FL_STEP_START="$SECONDS"
      fl_step_end skipped "$res"
      AP_STEP_NOTE[i]="$res"
      i=$((i + 1)); continue
    fi
    fl_step_begin "$i"
    fl_log_lines_v fail_from
    res="done"
    case "$kind" in
      clone_required|clone)
        rp=""; br=""; sha=""
        for e in ${AP_DEPS[@]+"${AP_DEPS[@]}"} "${AP_NAME}|${AP_REPO}|${AP_BRANCH}|${AP_COMMIT}"; do
          [[ "${e%%|*}" == "$arg" ]] && { IFS='|' read -r _ rp br sha <<<"$e"; break; }
        done
        if ! fl_app_clone "$arg" "$rp" "$br"; then res="failed"
        elif ! fl__ap_at_commit "$FL_CLONED_DIR" "$sha"; then
          # the branch moved between the plan and get-app: build and install
          # would run code nobody reviewed
          res="failed"
          fl_fail "${arg}: ${br} moved after the plan was made (planned ${sha:0:12}, cloned ${AP__GOT:0:12}); nothing was built or installed."
          fl_fix "Review a fresh plan: benchbar app add ${target} ... --dry-run --json"
        else cloned+=("$FL_CLONED_DIR"); fi ;;
      build)
        # the folders of the apps to build, as bench named them
        s=""
        for a in ${arg//,/ }; do
          e="$(fl_app_existing_dir "$a")"
          [[ -z "$e" ]] || s="${s}${s:+,}${e}"
        done
        s="${s:-$arg}"
        fl_app_build "$s" || { res="failed"; fl_fix "cd ${FL_BENCH_DIR} && bench build --apps ${s}"; } ;;
      requirements_python)
        for a in ${arg//,/ }; do
          fl_run_long "bench setup requirements --python ${a}" fl__in_dir "$FL_BENCH_DIR" bench setup requirements --python "$a" || { res="failed"; break; }
        done ;;
      install)
        fl_app_install_on_sites "$AP_NAME" "$arg" || res="failed" ;;
      restart)
        fl_bench_redis_down
        if ! fl_bench_is_running; then res="skipped"
        else fl_app_restart_if_running || res="failed"; fi ;;
    esac
    case "$res" in
      done)
        fl_step_end "done"; done_set="${done_set}${i} "
        # what the run changed, for the done line
        case "$kind" in
          clone_required|clone) fl_changed app "$arg" "cloned" ;;
          install) fl_changed app "$AP_NAME" "installed on ${arg}" ;;
          restart) fl_changed process "$FL_BENCH_NAME" "restarted" ;;
        esac ;;
      skipped) fl_step_end skipped "not running"; done_set="${done_set}${i} " ;;
      *)
        fl_step_end failed
        code=1
        fl_pending_reason_v reason "$fail_from"
        if [[ -z "$first_kind" ]]; then first_kind="$kind"; first_reason="${reason:-${label} failed}"; fi
        case "$kind" in clone_required|clone) clone_failed="$kind" ;; build) build_failed=1 ;; requirements_python) py_failed=1 ;; esac ;;
    esac
    if [[ -n "$clone_failed" && "$res" == "failed" && ( "$kind" == "clone_required" || "$kind" == "clone" ) ]]; then
      # a clone that failed was rolled back: the record keeps only the build
      # of the apps this run did clone, or goes away when there are none
      s=""
      for a in ${cloned[@]+"${cloned[@]}"}; do s="${s}${s:+,}${a}"; done
      # a folder get-app left behind (listed in apps.txt) was not pip installed
      e="$(fl_app_existing_dir "$arg")"
      [[ -z "$e" ]] || { case ",${s}," in *",${e},"*) ;; *) s="${s}${s:+,}${e}" ;; esac; }
      if [[ -n "$s" && -n "$e" ]]; then
        fl_pending_write app_add "$AP_NAME" "$AP_BRANCH" "" "$AP_COMMIT" "$first_kind" "$first_reason" "requirements_python|${e}|Python requirements" "build|${s}|Build" "restart||Restart" || code=1
      elif [[ -n "$s" ]]; then
        fl_pending_write app_add "$AP_NAME" "$AP_BRANCH" "" "$AP_COMMIT" "$first_kind" "$first_reason" "build|${s}|Build" "restart||Restart" || code=1
      else
        fl_pending_remove "$AP_NAME"
      fi
    elif ! fl__ap_record "$first_kind" "$first_reason" "$done_set"; then
      # the record is what a retry runs from: a step that cannot be recorded is a failed step
      code=1; clone_failed="pending record"
    fi
    i=$((i + 1))
  done
  fl_bench_redis_down
  if [[ -d "$(fl_app_path "$AP_NAME")" ]]; then
    if ! fl__ap_verify ${AP_INSTALL[@]+"${AP_INSTALL[@]}"}; then
      code=1
      # a failed step is already in the record; a verify that fails on its own is the news
      [[ -n "$first_kind" ]] || fl__ap_record "verify" "apps/${AP_NAME} did not pass the verify pass after the steps" "$done_set"
    fi
  fi
  [[ "$code" != "0" ]] || fl_pending_remove "$AP_NAME"
  fl_steps_summary
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
    out="${out}${sep}{\"kind\":$(fl_json_str "$kind"),\"name\":$(fl_json_str "$label"),\"status\":$(fl_json_str "${FL_STEP_STATUS[$i]:-pending}"),\"reason\":$(fl_json_str "${AP_STEP_NOTE[$i]:-}")}"; sep=","
    i=$((i + 1))
  done
  printf '%s]}\n' "$out"
}

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

# fl__ap_pin_resolve DIR PIN: PIN (7 to 40 hex characters) as a full commit
# of the clone in DIR, in AP__FULL; 1 when the clone cannot reach it. The
# shallow clone has the branch tip only: a full hash is fetched by id (GitHub
# hands out any commit it has), and an abbreviated one has to resolve once
# the rest of the history of the clone's remote is in.
fl__ap_pin_resolve() {
  local dir="$1" pin="$2" tmp
  AP__FULL=""
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-plan.XXXXXX")"
  AP__FULL="$(git -C "$dir" rev-parse -q --verify "${pin}^{commit}" 2>/dev/null || true)"
  if [[ -z "$AP__FULL" && "${#pin}" == "40" ]]; then
    fl__ap_git "${FL_GIT_CLONE_TIMEOUT:-120}" "$tmp/out" "$tmp/err" -C "$dir" fetch --quiet --depth 1 --filter=blob:none origin "$pin" || true
    fl_log_file_append "$tmp/err"
    AP__FULL="$(git -C "$dir" rev-parse -q --verify "${pin}^{commit}" 2>/dev/null || true)"
  fi
  if [[ -z "$AP__FULL" ]]; then
    if [[ "$(git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null || true)" == "true" ]]; then
      fl__ap_git "${FL_GIT_CLONE_TIMEOUT:-120}" "$tmp/out" "$tmp/err" -C "$dir" fetch --quiet --unshallow --tags --filter=blob:none origin '+refs/heads/*:refs/remotes/origin/*' || true
    else
      fl__ap_git "${FL_GIT_CLONE_TIMEOUT:-120}" "$tmp/out" "$tmp/err" -C "$dir" fetch --quiet --tags --filter=blob:none origin '+refs/heads/*:refs/remotes/origin/*' || true
    fi
    fl_log_file_append "$tmp/err"
    AP__FULL="$(git -C "$dir" rev-parse -q --verify "${pin}^{commit}" 2>/dev/null || true)"
  fi
  rm -rf "$tmp"
  [[ -n "$AP__FULL" ]]
}

# fl__ap_read_hooks REPO BRANCH NAME [PIN]: a shallow, blobless clone into a
# temp folder outside the bench, only hooks.py read from it (at PIN when
# given, else at the branch tip). Sets AP__PKG (the package folder that holds
# hooks.py), AP__REQ (its required_apps, one per line) and AP__SHA (the
# commit it read); 1 with AP__ERR when it cannot be read.
fl__ap_read_hooks() {
  local repo="$1" branch="$2" name="$3" pin="${4:-}" tmp code=0 path="" ref="HEAD"
  AP__PKG=""; AP__REQ=""; AP__ERR=""; AP__SHA=""
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-plan.XXXXXX")"
  fl__ap_git "${FL_GIT_CLONE_TIMEOUT:-120}" "$tmp/out" "$tmp/err" \
    clone --quiet --depth 1 --filter=blob:none --no-checkout --branch "$branch" -- "$repo" "$tmp/repo" || code=$?
  fl_log_file_append "$tmp/err"
  if [[ "$code" != "0" ]]; then
    AP__ERR="could not read hooks.py of ${repo} (git clone exit ${code}): $(fl__ap_first_line "$tmp/err")"
    rm -rf "$tmp"; return 1
  fi
  if [[ -n "$pin" ]]; then
    if ! fl__ap_pin_resolve "$tmp/repo" "$pin"; then
      AP__ERR="the commit ${pin} is not in ${repo}: it must be a commit of one of its branches or tags$([[ "${#pin}" == "40" ]] || printf '; the remote does not hand out an abbreviated hash, so use the full 40 characters if it is not found')"
      rm -rf "$tmp"; return 1
    fi
    ref="$AP__FULL"
  fi
  AP__SHA="$(git -C "$tmp/repo" rev-parse "${ref}^{commit}" 2>/dev/null || true)"
  git -C "$tmp/repo" ls-tree -r --name-only "$ref" >"$tmp/tree" 2>/dev/null || true
  if grep -qxF "${name}/hooks.py" "$tmp/tree"; then path="${name}/hooks.py"
  else path="$(grep -E '^[^/]+/hooks\.py$' "$tmp/tree" | head -n1 || true)"; fi
  if [[ -z "$path" ]]; then
    AP__ERR="${repo} (${branch}${pin:+ at ${pin}}) has no <package>/hooks.py: not a Frappe app?"
    rm -rf "$tmp"; return 1
  fi
  code=0
  fl__ap_git "${FL_GIT_CLONE_TIMEOUT:-120}" "$tmp/hooks.py" "$tmp/err" -C "$tmp/repo" show "${ref}:${path}" || code=$?
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

# fl__ap_new_main NAME: 0 when NAME is a target of this add that is not in the bench yet
fl__ap_new_main() {
  local i
  for ((i = 0; i < ${#M_NAME[@]}; i++)); do
    [[ "${M_NAME[$i]}" == "$1" && "${M_PRESENT[$i]}" == "0" ]] && return 0
  done
  return 1
}

# fl__ap_required PARENT LIST: walks required_apps breadth first. A dep in
# the bench is noted; one config/apps.tsv or the team profile resolves is
# planned and its own hooks.py read; any other one blocks the plan. Every
# "PARENT requires DEP" met on the way goes to AP_EDGES (PARENT|DEP), which
# fl__ap_toposort orders AP_DEPS by.
fl__ap_required() {
  local queue=() qi=0 item dep parent policy source present resolves repo branch line
  local saved_name="$FL_RES_NAME" saved_repo="$FL_RES_REPO" saved_branch="$FL_RES_BRANCH"
  while IFS= read -r dep; do [[ -n "$dep" ]] && queue+=("${dep}|$1"); done <<<"$2"
  while [[ "$qi" -lt "${#queue[@]}" ]]; do
    item="${queue[$qi]}"; qi=$((qi + 1))
    dep="${item%%|*}"; parent="${item#*|}"
    AP_EDGES+=("${parent}|${dep}")
    # an app being added is a node of the graph, not something to clone first
    fl__ap_new_main "$dep" && continue
    case "$AP_SEEN" in *" $dep "*) continue ;; esac
    AP_SEEN="${AP_SEEN}${dep} "
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
# order does not change. Sets AP_ORDER (names, the targets last when they are
# cloned). A cycle is a plan error that names it.
fl__ap_toposort() {
  local nodes=() placed=" " all=" " entry n pick d blocked total deps=() i
  for entry in ${AP_DEPS[@]+"${AP_DEPS[@]}"}; do nodes+=("${entry%%|*}"); done
  for ((i = 0; i < ${#M_NAME[@]}; i++)); do [[ "${M_PRESENT[$i]}" == "1" ]] || nodes+=("${M_NAME[$i]}"); done
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

# fl__ap_parse USAGE ARGS...: the targets of the add and their options.
# --branch, --name, --commit and --install-on belong to the target they
# follow (to the first one when they come before every target); --all-sites
# and --apply are for the whole add (--site is read by benchbar itself and
# also applies to every target that has no --install-on). Sets AP_T_TARGET,
# AP_T_BRANCH, AP_T_NAME, AP_T_COMMIT and AP_T_ON (a comma separated list of
# sites), AP_ALL, AP_APPLY and AP_TOKEN_IN.
fl__ap_parse() {
  local usage="$1" cur=-1 idx opt val
  shift
  AP_T_TARGET=(""); AP_T_BRANCH=(""); AP_T_NAME=(""); AP_T_COMMIT=(""); AP_T_ON=("")
  AP_ALL=0; AP_APPLY=0; AP_TOKEN_IN=""
  while [[ "$#" -gt 0 ]]; do
    opt=""; val=""
    case "$1" in
      --branch|--name|--commit|--install-on) opt="$1"; val="${2:-}"; shift; [[ "$#" -eq 0 ]] || shift ;;
      --branch=*|--name=*|--commit=*|--install-on=*) opt="${1%%=*}"; val="${1#*=}"; shift ;;
      --all-sites) AP_ALL=1; shift ;;
      --apply) AP_APPLY=1; AP_TOKEN_IN="${2:-}"; shift; [[ "$#" -eq 0 ]] || shift ;;
      --apply=*) AP_APPLY=1; AP_TOKEN_IN="${1#*=}"; shift ;;
      -*) fl_die "Unknown option for app add: $1" "$usage" ;;
      *)
        cur=$((cur + 1)); AP_T_TARGET[cur]="$1"
        if [[ "$cur" -gt 0 ]]; then AP_T_BRANCH[cur]=""; AP_T_NAME[cur]=""; AP_T_COMMIT[cur]=""; AP_T_ON[cur]=""; fi
        shift ;;
    esac
    [[ -n "$opt" ]] || continue
    [[ -n "$val" && "$val" != -* ]] || fl_die "${opt} needs a value." "$usage"
    idx="$cur"; [[ "$idx" -ge 0 ]] || idx=0
    case "$opt" in
      --branch) AP_T_BRANCH[idx]="$val" ;;
      --name) AP_T_NAME[idx]="$val" ;;
      --commit) AP_T_COMMIT[idx]="$val" ;;
      --install-on) AP_T_ON[idx]="$val" ;;
    esac
  done
}

# fl__ap_target I: resolves target I (AP_T_*) and stores what it finds in
# M_*. Its required apps are walked in a second pass, when every target is
# known (one of them may be what another requires).
fl__ap_target() {
  local i="$1" target="${AP_T_TARGET[$1]}" branch="${AP_T_BRANCH[$1]:-}" name="${AP_T_NAME[$1]:-}" pin="${AP_T_COMMIT[$1]:-}"
  local a_name a_repo a_branch a_bsrc="" a_present=0 a_reach="" a_pkg="" a_commit="" a_csrc="branch" a_reqs="" s policy cur default full head pre='^[0-9a-fA-F]{7,40}$'
  [[ -n "$target" ]] || fl_die "Usage: benchbar app add NAME|URL [--branch B] [--name N] [--commit SHA] [--install-on SITES]..."
  [[ -z "$name" || "$name" =~ ^[a-z][a-z0-9_]*$ ]] || fl_die "Invalid app name: '${name}'." "Use a Python package name: lowercase letters, digits and '_'."
  [[ "$branch" != -* ]] || fl_die "Invalid branch: '${branch}'."
  if [[ -n "$pin" ]]; then
    [[ "$pin" =~ $pre ]] || fl_die "Invalid commit: '${pin}'." "Pass a commit hash of 7 to 40 hex characters: --commit 0123abc"
    pin="$(printf '%s' "$pin" | tr 'A-F' 'a-f')"
  fi
  fl_app_resolve "$target" "$branch" "$name"
  a_name="$FL_RES_NAME"; a_repo="$FL_RES_REPO"; a_branch="$FL_RES_BRANCH"
  if [[ -n "$branch" ]]; then a_bsrc="given"; elif [[ -n "$a_branch" ]]; then a_bsrc="policy"; fi

  cur="$(fl_app_existing_dir "$a_name")"
  if [[ -n "$cur" ]]; then
    a_name="$cur"; a_present=1; a_pkg="$cur"
    fl_app_in_apps_txt "$cur" || fl_die "apps/${cur} exists but is not in sites/apps.txt (a get-app that did not finish?)." \
      "Move it aside (mv ${FL_BENCH_DIR}/apps/${cur} ~/${cur}.aside), then run this command again."
    s="$(fl_app_branch "$cur")"
    [[ -n "$a_branch" ]] || { a_branch="$s"; a_bsrc="present"; }
    if [[ -n "$pin" ]]; then
      head="$(git -C "$(fl_app_path "$cur")" rev-parse -q --verify HEAD 2>/dev/null || true)"
      full="$(git -C "$(fl_app_path "$cur")" rev-parse -q --verify "${pin}^{commit}" 2>/dev/null || true)"
      if [[ -n "$full" && "$full" == "$head" ]]; then a_commit="$full"; a_csrc="pin"
      else
        a_commit="${full:-$pin}"; a_csrc="pin"
        fl__ap_err "apps/${cur} is at ${head:0:12}, not the pinned commit ${pin}: benchbar never moves an app that is there (check the commit out yourself, or use benchbar app update)"
      fi
    else
      [[ "$s" == "$a_branch" ]] || fl__ap_on_tag "$cur" "$a_branch" || fl_die "apps/${cur} is on ${s:-a detached HEAD}, not ${a_branch}." \
        "benchbar never replaces an app. To switch it yourself: cd ${FL_BENCH_DIR}/apps/${cur} && git fetch $(fl_app_remote "$cur") ${a_branch} && git checkout ${a_branch}"
    fi
    a_reqs="$(fl_app_required_apps "$cur")"
  else
    a_reach=0
    if [[ -n "$a_branch" ]]; then
      if fl__ap_remote "$a_repo" "$a_branch"; then a_reach=1
      else case "$AP__ERR" in "branch "*) a_reach=1 ;; esac; fl__ap_err "$AP__ERR"; fi
    elif fl__ap_remote "$a_repo"; then
      a_reach=1
      default="$AP__DEFAULT"
      # like app add: a URL for a known app follows the known branch when the remote has it
      policy="$(fl_lookup_app_policy "$a_name" "$FL_PROFILE" 2>/dev/null || true)"; policy="${policy%%|*}"
      if [[ -n "$policy" ]] && fl__ap_remote "$a_repo" "$policy"; then a_branch="$policy"; a_bsrc="policy"
      elif [[ -n "$default" ]]; then a_branch="$default"; a_bsrc="remote_default"
      else fl__ap_err "could not tell the default branch of ${a_repo}; pass --branch"; fi
    else
      fl__ap_err "$AP__ERR"
    fi
    if [[ "$AP_CAN_APPLY" == "1" ]] && fl__ap_plain "$a_name" "$a_repo" "$a_branch"; then
      if fl__ap_read_hooks "$a_repo" "$a_branch" "$a_name" "$pin"; then
        a_pkg="$AP__PKG"; a_reqs="$AP__REQ"; a_commit="$AP__SHA"
        [[ -z "$pin" ]] || a_csrc="pin"
        # bench names the folder after the package, so that is the app
        if [[ -z "$name" && "$a_pkg" != "$a_name" ]]; then
          a_name="$a_pkg"
          [[ -z "$(fl_app_existing_dir "$a_name")" ]] || fl__ap_err "the package is ${a_name}, which the bench already has: run benchbar app add ${a_name}"
        fi
      else
        fl__ap_err "$AP__ERR"
      fi
    fi
  fi
  M_NAME[i]="$a_name"; M_REPO[i]="$a_repo"; M_BRANCH[i]="$a_branch"; M_BSRC[i]="$a_bsrc"; M_PRESENT[i]="$a_present"
  M_REACH[i]="$a_reach"; M_PKG[i]="$a_pkg"; M_COMMIT[i]="$a_commit"; M_CSRC[i]="$a_csrc"; M_REQS[i]="$a_reqs"
  M_SITES[i]=""; M_INSTALL[i]=""; M_INVOLVED[i]=0; M_PD[i]=0
}

# fl__ap_main_index NAME: sets AP_MI to the index of the target NAME (-1 when it is none)
fl__ap_main_index() {
  local i
  AP_MI=-1
  for ((i = 0; i < ${#M_NAME[@]}; i++)); do
    [[ "${M_NAME[$i]}" == "$1" ]] && { AP_MI="$i"; return 0; }
  done
  return 1
}

# fl__ap_main_order: sets AP_MORDER to the indexes of the targets in an order
# where each comes after the targets it requires (through apps in the bench
# too), the earlier one first among equals. Installs follow it.
fl__ap_main_order() {
  local placed=" " names=" " i d pick blocked n="${#M_NAME[@]}"
  AP_MORDER=()
  for ((i = 0; i < n; i++)); do names="${names}${M_NAME[$i]} "; done
  while [[ "${#AP_MORDER[@]}" -lt "$n" ]]; do
    pick=-1
    for ((i = 0; i < n; i++)); do
      case "$placed" in *" ${M_NAME[$i]} "*) continue ;; esac
      blocked=0
      fl__ap_blockers "${M_NAME[$i]}" "$names"
      for d in $AP_BLK; do
        case "$placed" in *" $d "*) ;; *) blocked=1; break ;; esac
      done
      [[ "$blocked" == "0" ]] && { pick="$i"; break; }
    done
    if [[ "$pick" -lt 0 ]]; then
      # a cycle (reported by the sort above): the rest in the order given
      for ((i = 0; i < n; i++)); do
        case "$placed" in *" ${M_NAME[$i]} "*) ;; *) AP_MORDER+=("$i") ;; esac
      done
      return 0
    fi
    placed="${placed}${M_NAME[$pick]} "
    AP_MORDER+=("$pick")
  done
}

# fl_app_add_plan ALL: plans every target of AP_T_* in one graph. Sets M_*
# (one entry per target), AP_* (the first target's own fields, the graph, the
# steps), AP_JSON and AP_TOKEN. Refusals that the plain app add also refuses
# exit 1 with the reason.
fl_app_add_plan() {
  local all="$1" i j s n cnt by pr rs src rp br sha kind label cmd note st entry body state sep a e on inst kn rn dup=0
  local g_sites=() pd_build="" pd_py="" pd_restart=0 pd_sites="" apps_json="" all_nodes names_json parent found
  M_NAME=(); M_REPO=(); M_BRANCH=(); M_BSRC=(); M_PRESENT=(); M_REACH=(); M_PKG=(); M_COMMIT=(); M_CSRC=(); M_REQS=()
  M_SITES=(); M_INSTALL=(); M_INVOLVED=(); M_PD=(); AP_MORDER=()
  AP_NAME=""; AP_REPO=""; AP_BRANCH=""; AP_BRANCH_SOURCE=""; AP_PRESENT=0; AP_REACHABLE=""; AP_PKG=""; AP_COMMIT=""; AP_COMMIT_SOURCE="branch"
  AP_SITES=(); AP_INSTALL=(); AP_REQ=(); AP_DEPS=(); AP_ERRORS=(); AP_STEPS=(); AP_CAN_APPLY=1
  AP_EDGES=(); AP_ORDER=(); AP_PENDING=0; AP_REASON=""; AP_SEEN=" "
  [[ "$all" == "1" && -n "${OPT_SITE:-}" ]] && fl_die "Pass --site or --all-sites, not both."
  cnt="${#AP_T_TARGET[@]}"

  # first pass: what each target is
  for ((i = 0; i < cnt; i++)); do fl__ap_target "$i"; done
  for ((i = 0; i < cnt; i++)); do
    for ((j = 0; j < i; j++)); do
      [[ "${M_NAME[$i]}" != "${M_NAME[$j]}" ]] || { dup=1; fl__ap_err "${M_NAME[$i]} is named twice; list each app once"; }
    done
  done
  AP_NAME="${M_NAME[0]}"; AP_REPO="${M_REPO[0]}"; AP_BRANCH="${M_BRANCH[0]}"; AP_BRANCH_SOURCE="${M_BSRC[0]}"; AP_PRESENT="${M_PRESENT[0]}"
  AP_REACHABLE="${M_REACH[0]}"; AP_PKG="${M_PKG[0]}"; AP_COMMIT="${M_COMMIT[0]}"; AP_COMMIT_SOURCE="${M_CSRC[0]}"

  # the sites of each target: its own --install-on, else --site or --all-sites
  while IFS= read -r s; do [[ -n "$s" ]] && g_sites+=("$s"); done < <(fl_app_target_sites "$all")
  for ((i = 0; i < cnt; i++)); do
    on="${AP_T_ON[$i]:-}"
    if [[ -n "$on" ]]; then
      [[ "$on" != ,* && "$on" != *, ]] || fl_die "--install-on needs site names separated by commas (got '${on}')."
      for s in ${on//,/ }; do fl_site_require "$s"; case " ${M_SITES[$i]} " in *" $s "*) ;; *) M_SITES[i]="${M_SITES[$i]:+${M_SITES[$i]} }$s" ;; esac; done
    else
      for s in ${g_sites[@]+"${g_sites[@]}"}; do M_SITES[i]="${M_SITES[$i]:+${M_SITES[$i]} }$s"; done
    fi
  done

  # second pass: the required apps of all of them, one graph, one order
  for ((i = 0; i < cnt; i++)); do
    [[ -z "${M_REQS[$i]}" ]] || fl__ap_required "${M_NAME[$i]}" "${M_REQS[$i]}"
  done
  [[ "$dup" == "1" ]] || fl__ap_toposort || true
  fl__ap_main_order

  # an earlier app add of a target that stopped half way: what it did not
  # finish (build, install, restart) is part of this plan
  for ((i = 0; i < cnt; i++)); do
    s="${M_NAME[$i]}"
    if [[ -z "$s" ]]; then continue
    elif fl_pending_corrupt "$s"; then
      fl__ap_err "the pending record of ${s} cannot be read (cut short or from another version); it is kept and nothing runs from it: benchbar app update ${s} --discard-pending drops it and stops"
    elif fl_pending_load "$s" && [[ "$PD_OP" == "app_add" ]]; then
      AP_PENDING=1; M_PD[i]=1
      AP_REASON="${AP_REASON}${AP_REASON:+; }an earlier app add of ${s} stopped at ${PD_FAILED:-an unknown step}${PD_REASON:+ (${PD_REASON})}; the steps it did not finish are in this plan"
      # shellcheck disable=SC2153  # PD_STEPS is set by fl_pending_load (apps.sh)
      for st in ${PD_STEPS[@]+"${PD_STEPS[@]}"}; do
        IFS='|' read -r kind kn _ <<<"$st"
        case "$kind" in
          build) for a in ${kn//,/ }; do [[ -z "$(fl_app_existing_dir "$a")" ]] || pd_build="${pd_build}${pd_build:+,}$(fl_app_existing_dir "$a")"; done ;;
          install) if fl_sites_list | grep -qxF "$kn"; then case " ${M_SITES[$i]} " in *" $kn "*) ;; *) M_SITES[i]="${M_SITES[$i]:+${M_SITES[$i]} }$kn" ;; esac; fi ;;
          requirements_python) for a in ${kn//,/ }; do [[ -z "$(fl_app_existing_dir "$a")" ]] || pd_py="${pd_py}${pd_py:+,}$(fl_app_existing_dir "$a")"; done ;;
          restart) pd_restart=1 ;;
        esac
      done
    fi
  done

  # which sites still need each target (a fresh read of their app lists)
  for ((i = 0; i < cnt; i++)); do
    for s in ${M_SITES[$i]}; do case " ${AP_SITES[*]:-} " in *" $s "*) ;; *) AP_SITES+=("$s") ;; esac; done
  done
  if [[ "${#AP_SITES[@]}" -gt 0 ]]; then
    fl_site_apps_refresh "${AP_SITES[@]}" >/dev/null 2>&1 || true
    for ((i = 0; i < cnt; i++)); do
      for s in ${M_SITES[$i]}; do
        if [[ "${M_PRESENT[$i]}" == "1" ]] && fl_site_has_app "$s" "${M_NAME[$i]}"; then continue; fi
        M_INSTALL[i]="${M_INSTALL[$i]:+${M_INSTALL[$i]} }$s"
        case " ${AP_INSTALL[*]:-} " in *" $s "*) ;; *) AP_INSTALL+=("$s") ;; esac
      done
    done
  fi

  # the steps, in the order --apply runs them: every clone in dependency
  # order, one build for all of them, the installs, one restart
  s=""
  for e in ${AP_ORDER[@]+"${AP_ORDER[@]}"}; do
    s="${s}${s:+,}${e}"
    if fl__ap_new_main "$e"; then
      fl__ap_main_index "$e"
      AP_STEPS+=("clone|${e}|Clone ${e}|bench get-app --skip-assets --branch ${M_BRANCH[$AP_MI]:-?} ${M_REPO[$AP_MI]}|get-app clones into apps/${e}, pip installs it into the bench env and adds it to sites/apps.txt; never --overwrite or --resolve-deps")
    else
      br=""; rp=""; parent="$AP_NAME"
      for entry in ${AP_DEPS[@]+"${AP_DEPS[@]}"}; do
        [[ "${entry%%|*}" == "$e" ]] && { IFS='|' read -r _ rp br _ <<<"$entry"; break; }
      done
      for entry in ${AP_REQ[@]+"${AP_REQ[@]}"}; do
        [[ "${entry%%|*}" == "$e" ]] && { IFS='|' read -r _ parent _ <<<"$entry"; break; }
      done
      AP_STEPS+=("clone_required|${e}|Clone ${e}|bench get-app --skip-assets --branch ${br} ${rp}|required app of ${parent} (hooks.py required_apps); get-app also pip installs it into the bench env")
    fi
  done
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
  # installs: site by site, each site in dependency order
  for s in ${AP_INSTALL[@]+"${AP_INSTALL[@]}"}; do
    for j in ${AP_MORDER[@]+"${AP_MORDER[@]}"}; do
      case " ${M_INSTALL[$j]} " in *" $s "*) ;; *) continue ;; esac
      e="${M_NAME[$j]}"
      if [[ "$cnt" == "1" ]]; then label="Install on ${s}"; else label="Install ${e} on ${s}"; fi
      AP_STEPS+=("install|${e}@${s}|${label}|bench --site ${s} install-app ${e}|changes the site's database: installs ${e} (and its required apps) and syncs their DocTypes and patches, like a migrate of these apps only; no backup is taken first")
    done
  done
  if [[ "${#AP_ORDER[@]}" -gt 0 || "$pd_restart" == "1" ]]; then
    AP_STEPS+=("restart||Restart|benchbar restart|only when the bench is running, so the new code is served")
  fi

  # the targets that have work: a record is kept for these when a step fails
  all_nodes=" ${AP_ORDER[*]:-} "
  for ((i = 0; i < cnt; i++)); do
    if [[ "${M_PRESENT[$i]}" == "0" || -n "${M_INSTALL[$i]}" || "${M_PD[$i]}" == "1" ]]; then M_INVOLVED[i]=1; continue; fi
    fl__ap_blockers "${M_NAME[$i]}" "$all_nodes"
    [[ -z "$AP_BLK" ]] || M_INVOLVED[i]=1
  done

  # JSON
  if [[ "$cnt" -gt 1 ]]; then
    apps_json="\"apps\":["; sep=""
    for ((i = 0; i < cnt; i++)); do
      inst=""
      for s in ${M_SITES[$i]}; do
        j=1; case " ${M_INSTALL[$i]} " in *" $s "*) j=0 ;; esac
        inst="${inst}${inst:+,}{\"name\":$(fl_json_str "$s"),\"installed\":$(fl_json_bool "$j")}"
      done
      names_json=()
      while IFS= read -r e; do [[ -n "$e" ]] && names_json+=("$e"); done <<<"${M_REQS[$i]}"
      apps_json="${apps_json}${sep}$(printf '{"app":%s,"package":%s,"target":%s,"repo":%s,"branch":%s,"branch_source":%s,"commit":%s,"commit_source":%s,"present":%s,"reachable":%s,"install_on":%s,"sites":[%s],"required_apps":%s}' \
        "$(fl_json_str "${M_NAME[$i]}")" "$(fl_json_str "${M_PKG[$i]}")" "$(fl_json_str "$(fl_url_strip_userinfo "${AP_T_TARGET[$i]}")")" \
        "$(fl_json_str "${M_REPO[$i]}")" "$(fl_json_str "${M_BRANCH[$i]}")" "$(fl_json_str "${M_BSRC[$i]}")" \
        "$(fl_json_str "${M_COMMIT[$i]}")" "$(fl_json_str "${M_CSRC[$i]}")" "$(fl_json_bool "${M_PRESENT[$i]}")" \
        "$(if [[ -z "${M_REACH[$i]}" ]]; then printf null; else fl_json_bool "${M_REACH[$i]}"; fi)" \
        "$(fl_json_str_array ${AP_T_ON[$i]:+${AP_T_ON[$i]//,/ }})" "$inst" "$(fl_json_str_array ${names_json[@]+"${names_json[@]}"})")"
      sep=","
    done
    apps_json="${apps_json}],"
  fi
  body="$(printf '"bench":%s,"profile":%s,"target":%s,"app":%s,"package":%s,"repo":%s,"branch":%s,"commit":%s,"commit_source":%s,"branch_source":%s,"present":%s,"reachable":%s,' \
    "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$FL_PROFILE")" "$(fl_json_str "$(fl_url_strip_userinfo "${AP_T_TARGET[0]}")")" \
    "$(fl_json_str "$AP_NAME")" "$(fl_json_str "$AP_PKG")" "$(fl_json_str "$AP_REPO")" "$(fl_json_str "$AP_BRANCH")" "$(fl_json_str "$AP_COMMIT")" \
    "$(fl_json_str "$AP_COMMIT_SOURCE")" "$(fl_json_str "$AP_BRANCH_SOURCE")" "$(fl_json_bool "$AP_PRESENT")" \
    "$(if [[ -z "$AP_REACHABLE" ]]; then printf null; else fl_json_bool "$AP_REACHABLE"; fi)")"
  body="${body}${apps_json}\"sites\":["; sep=""
  for s in ${AP_SITES[@]+"${AP_SITES[@]}"}; do
    i=1; case " ${AP_INSTALL[*]:-} " in *" $s "*) i=0 ;; esac
    body="${body}${sep}{\"name\":$(fl_json_str "$s"),\"installed\":$(fl_json_bool "$i")}"; sep=","
  done
  body="${body}],\"sites_error\":$(fl_json_str "${FL_SITE_APPS_ERROR:-}"),\"required_apps\":["; sep=""
  for entry in ${AP_REQ[@]+"${AP_REQ[@]}"}; do
    IFS='|' read -r rn by pr rs src rp br sha <<<"$entry"
    body="${body}${sep}{\"name\":$(fl_json_str "$rn"),\"required_by\":$(fl_json_str "$by"),\"present\":$(fl_json_bool "$pr"),\"resolves\":$(fl_json_bool "$rs"),\"source\":$(fl_json_str "$src"),\"repo\":$(fl_json_str "$rp"),\"branch\":$(fl_json_str "$br"),\"commit\":$(fl_json_str "$sha")}"; sep=","
  done
  body="${body}],\"missing_required\":["; sep=""
  for entry in ${AP_REQ[@]+"${AP_REQ[@]}"}; do
    IFS='|' read -r rn by pr _ <<<"$entry"
    [[ "$pr" == "1" ]] && continue
    body="${body}${sep}$(fl_json_str "$rn")"; sep=","
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
  local rows=("#|Step|Command") i=1 entry label cmd e names=""
  if [[ "${#M_NAME[@]}" -gt 1 ]]; then
    for ((e = 0; e < ${#M_NAME[@]}; e++)); do names="${names}${names:+, }${M_NAME[$e]} (${M_BRANCH[$e]:-?})"; done
    printf '\n%sPlan%s %s\n' "$FL_BOLD" "$FL_RESET" "$names"
  else
    printf '\n%sPlan%s %s (%s%s) from %s\n' "$FL_BOLD" "$FL_RESET" "$AP_NAME" "${AP_BRANCH:-?}" "$([[ "$AP_COMMIT_SOURCE" == "pin" ]] && printf ' at %s' "${AP_COMMIT:0:12}")" "$AP_REPO"
  fi
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
  local e heads entry n pr rs i
  for e in ${AP_ERRORS[@]+"${AP_ERRORS[@]}"}; do
    for ((i = 0; i < ${#M_NAME[@]}; i++)); do
      case "$e" in
        "branch ${M_BRANCH[$i]} not found in "*)
          heads="$(fl_git_batch ls-remote --heads -- "${M_REPO[$i]}" 2>/dev/null | sed 's#.*refs/heads/##' | head -n 20 | tr '\n' ' ')"
          fl_note "remote branches: ${heads:-none}"
          fl_fix "pass one of them with --branch" ;;
        "cannot read ${M_REPO[$i]} "*) fl_repo_access_hint "${M_REPO[$i]}" ;;
      esac
    done
  done
  for entry in ${AP_REQ[@]+"${AP_REQ[@]}"}; do
    IFS='|' read -r n _ pr rs _ <<<"$entry"
    [[ "$pr" == "0" && "$rs" == "0" ]] || continue
    fl_fix "benchbar app add <git URL of ${n}> --branch BRANCH, then run this command again"
  done
}

# fl__ap_names_v VAR: the names of the targets, comma separated
fl__ap_names_v() {
  local __i __s=""
  for ((__i = 0; __i < ${#M_NAME[@]}; __i++)); do __s="${__s}${__s:+, }${M_NAME[$__i]}"; done
  printf -v "$1" '%s' "$__s"
}

# fl__ap_unchanged: the "nothing to do" line of each target
fl__ap_unchanged() {
  local i where
  for ((i = 0; i < ${#M_NAME[@]}; i++)); do
    if [[ "${M_CSRC[$i]}" == "pin" ]]; then where="at the pinned commit ${M_COMMIT[$i]:0:12}"; else where="on ${M_BRANCH[$i]}"; fi
    fl_ok "unchanged: ${M_NAME[$i]} is ${where}${M_SITES[$i]:+ and installed on ${M_SITES[$i]}}, nothing to do"
  done
}

# fl_cmd_app_add: app add from a terminal. The same plan the agents review
# (--dry-run --json, then --apply TOKEN), printed, asked once, and applied by
# the same loop, so both ways clone, build and install in the same order and
# leave the same record behind when a step fails.
fl_cmd_app_add() {
  local code=0 entry dep_list="" i names=""
  fl__ap_parse "Use: benchbar app add NAME|URL [--branch B] [--name N] [--commit SHA] [--install-on SITES] [NAME|URL ...] [--site S | --all-sites]" "$@"
  fl_require_bench
  [[ -n "${AP_T_TARGET[0]}" ]] || fl_die "Usage: benchbar app add NAME|URL [--branch B] [--name N] [--commit SHA] [--install-on SITES] [NAME|URL ...] [--site S | --all-sites]"
  fl_app_add_plan "$AP_ALL"
  fl_header "benchbar app add" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "${AP_SITES[*]:-no site}"
  for ((i = 0; i < ${#M_NAME[@]}; i++)); do
    [[ "${M_PRESENT[$i]}" == "1" ]] || continue
    if [[ "${M_CSRC[$i]}" == "pin" ]]; then fl_ok "apps/${M_NAME[$i]} is already at the pinned commit ${M_COMMIT[$i]:0:12}"
    else fl_ok "apps/${M_NAME[$i]} is already on ${M_BRANCH[$i]}"; fi
    fl_app_dirty "${M_NAME[$i]}" && fl_warn "apps/${M_NAME[$i]} has local changes; add only installs it on sites (app update and lock apply refuse a dirty app)"
  done
  if [[ "${#AP_STEPS[@]}" == "0" && "${#AP_ERRORS[@]}" == "0" ]]; then
    fl__ap_settle || return 1
    printf '\n'
    fl__ap_unchanged
    [[ "${#AP_SITES[@]}" != "0" ]] || fl_info "install it on a site with: benchbar app install ${AP_NAME} --site SITE"
    return 0
  fi
  if [[ "${#AP_DEPS[@]}" -gt 0 ]]; then
    for entry in "${AP_DEPS[@]}"; do dep_list="${dep_list}${dep_list:+, }${entry%%|*}"; done
    fl__ap_names_v names
    fl_info "${names} requires apps that are not in the bench yet (hooks.py required_apps): ${dep_list}"
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
  fl__ap_apply "${AP_T_TARGET[0]}" || code=$?
  return "$code"
}

# ---------------------------------------------------------------- the command

fl_cmd_app_add_planned() {
  local json="$OPT_JSON" code=0 target usage="Use: benchbar app add NAME|URL [--branch B] [--name N] [--commit SHA] [--install-on SITES] [NAME|URL ...] [--site S | --all-sites] --dry-run --json, then --apply TOKEN --yes"
  # JSON on fd 3, every line of text on stderr
  if [[ "$json" == "1" ]]; then fl_json_doc_begin; elif [[ "${FL_JSONL:-0}" != "1" ]]; then exec 3>&1; fi
  fl__ap_parse "$usage" "$@"
  target="${AP_T_TARGET[0]}"
  fl_require_bench
  [[ -n "$target" ]] || fl_die "Usage: benchbar app add NAME|URL [--branch B] [--name N] [--commit SHA] [--install-on SITES] [NAME|URL ...] [--site S | --all-sites] --dry-run --json"
  if [[ "$AP_APPLY" == "1" ]]; then
    [[ "${FL_DRY_RUN:-0}" != "1" ]] || fl_die "--apply runs the plan; --dry-run shows it. Pass one of them."
    [[ "$AP_TOKEN_IN" =~ ^[0-9a-f]{64}$ ]] || fl_die "--apply needs the token of a plan." "benchbar app add ${target} ... --dry-run --json prints it"
    [[ "${FL_ASSUME_YES:-0}" == "1" ]] || fl_die "Review the plan (--dry-run --json), then pass its token with --apply TOKEN --yes."
  else
    [[ "${FL_DRY_RUN:-0}" == "1" ]] || fl_die "--json shows the plan only; add --dry-run (then --apply TOKEN --yes to run it)." "benchbar app add ${target} --dry-run --json"
  fi
  # never a question on stdin: the plan was shown and approved already
  exec 0</dev/null
  fl_app_add_plan "$AP_ALL"
  if [[ "$AP_APPLY" == "0" ]]; then
    fl_doc_emit 0 "$AP_JSON" plan
    return 0
  fi

  fl_header "benchbar app add --apply" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "${AP_INSTALL[*]:-no site}"
  [[ "$AP_TOKEN_IN" == "$AP_TOKEN" ]] || fl_die "The app add plan changed since it was shown (apps.txt, apps/, the sites or the remote). Nothing was changed." \
    "Review a fresh plan: benchbar app add ${target} ... --dry-run --json, then pass its token."
  fl__ap_print_plan
  [[ "$AP_CAN_APPLY" == "1" ]] || fl_die "The plan cannot be applied (see above). Nothing was changed."
  if [[ "${#AP_STEPS[@]}" == "0" ]]; then
    fl__ap_settle || { [[ "$json" == "1" ]] && fl_doc_emit 1 "$(fl__ap_result_json 1)"; return 1; }
    printf '\n'; fl__ap_unchanged
    [[ "$json" == "1" ]] && fl_doc_emit 0 "$(fl__ap_result_json 0)"
    return 0
  fi

  fl__ap_apply "$target" || code=$?
  [[ "$json" == "1" ]] && fl_doc_emit "$code" "$(fl__ap_result_json "$code")"
  return "$code"
}

# fl__ap_record FAILED REASON DONE: the pending record of every target that
# has work, with the steps of AP_STEPS whose index is not in DONE (a string
# like " 0 1 "). A record holds the steps shared by the batch (clones, build,
# restart) and the installs of its own app, so `app add NAME` finishes that
# app and doctor names it.
fl__ap_record() {
  local left i m entry kind arg label code=0
  for ((m = 0; m < ${#M_NAME[@]}; m++)); do
    [[ "${M_INVOLVED[$m]}" == "1" ]] || continue
    left=(); i=0
    for entry in "${AP_STEPS[@]}"; do
      case "$3" in
        *" $i "*) ;;
        *)
          IFS='|' read -r kind arg label _ <<<"$entry"
          if [[ "$kind" == "install" ]]; then
            if [[ "${arg%%@*}" == "${M_NAME[$m]}" ]]; then arg="${arg#*@}"; label="Install on ${arg}"; else i=$((i + 1)); continue; fi
          fi
          left+=("${kind}|${arg}|${label}") ;;
      esac
      i=$((i + 1))
    done
    fl_pending_write app_add "${M_NAME[$m]}" "${M_BRANCH[$m]}" "" "${M_COMMIT[$m]}" "$1" "$2" ${left[@]+"${left[@]}"} || code=1
  done
  return "$code"
}

# fl__ap_verify APP BRANCH SOURCE COMMIT SITE...: the verify pass of one
# target: apps.txt, its branch (or tag, or pinned commit) and the sites
fl__ap_verify() {
  local app="$1" b="$2" csrc="$3" commit="$4" code=0 head
  shift 4
  # a tag is checked out detached: its commit is the check, not a branch name
  if [[ "$csrc" != "pin" ]] && fl__ap_on_tag "$app" "$b"; then fl_ok "apps/${app} is at tag ${b}"; b=""; fi
  [[ "$csrc" != "pin" ]] || b=""
  fl_app_verify "$app" "$b" "$@" || code=1
  if [[ "$csrc" == "pin" ]]; then
    head="$(git -C "$(fl_app_path "$app")" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$commit" && "$head" == "$commit" ]]; then fl_ok "apps/${app} is at the pinned commit ${commit:0:12}"
    else fl_fail "apps/${app} is at ${head:0:12}, expected the pinned commit ${commit:0:12}"; code=1; fi
  fi
  return "$code"
}

# fl__ap_settle: a record of an earlier add and no step left to run (the
# install was done by hand, a site was dropped, or only the verify failed):
# verify, and clear the record when it passes; otherwise say what is wrong.
# Returns 1 when an app does not verify.
fl__ap_settle() {
  local m nm code=0
  [[ "$AP_PENDING" == "1" && "${#AP_STEPS[@]}" == "0" ]] || return 0
  for ((m = 0; m < ${#M_NAME[@]}; m++)); do
    [[ "${M_PD[$m]}" == "1" ]] || continue
    nm="${M_NAME[$m]}"
    # shellcheck disable=SC2086  # the sites are words
    if [[ -d "$(fl_app_path "$nm")" ]] && fl__ap_verify "$nm" "${M_BRANCH[$m]}" "${M_CSRC[$m]}" "${M_COMMIT[$m]}" ${M_SITES[$m]}; then
      fl_pending_remove "$nm"
      if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then fl_ok "the unfinished app add of ${nm} is complete; its record would be removed"
      else fl_ok "the unfinished app add of ${nm} is complete; its record is removed"; fi
    else
      fl_fail "the unfinished app add of ${nm} has no step left, but ${nm} does not verify (above)"
      fl_fix "benchbar app update ${nm} --discard-pending   (drops the record and stops; nothing else runs)"
      code=1
    fi
  done
  return "$code"
}

# fl__ap_clone_info NAME: sets AP_CI_REPO, AP_CI_BRANCH, AP_CI_SHA (the commit
# the plan read) and AP_CI_PIN (the pinned commit, or nothing) of an app to clone
fl__ap_clone_info() {
  local e
  AP_CI_REPO=""; AP_CI_BRANCH=""; AP_CI_SHA=""; AP_CI_PIN=""
  for e in ${AP_DEPS[@]+"${AP_DEPS[@]}"}; do
    [[ "${e%%|*}" == "$1" ]] && { IFS='|' read -r _ AP_CI_REPO AP_CI_BRANCH AP_CI_SHA <<<"$e"; return 0; }
  done
  fl__ap_main_index "$1" || return 0
  AP_CI_REPO="${M_REPO[$AP_MI]}"; AP_CI_BRANCH="${M_BRANCH[$AP_MI]}"; AP_CI_SHA="${M_COMMIT[$AP_MI]}"
  [[ "${M_CSRC[$AP_MI]}" != "pin" ]] || AP_CI_PIN="${M_COMMIT[$AP_MI]}"
}

# fl__ap_pin_checkout DIR SHA: the clone in apps/DIR onto the pinned commit,
# fetching it when the clone does not have it; 1 (with AP__GOT, where the
# clone is) when it cannot get there
fl__ap_pin_checkout() {
  local path
  path="$(fl_app_path "$1")"
  if fl_commit_reach "$path" "$2" && fl_run git -C "$path" checkout --quiet "$2"; then return 0; fi
  AP__GOT="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
  return 1
}

# fl__ap_apply TARGET: runs AP_STEPS in order, with the dependencies
# clone_required -> clone -> build -> install and restart. A step whose
# requirement failed is skipped ("after failed <step>"); installs on
# different sites do not depend on each other, and a failed install does not
# keep the restart from running. The steps that did not finish stay in the
# pending records, which go away only when all are done and verify is green.
# Returns 1 when a step or the verify pass failed.
fl__ap_apply() {
  local target="$1" labels=() ids=() entry kind arg label i=0 code=0 e s a m nm res fail_from reason ia is
  local clone_failed="" build_failed="" py_failed="" first_kind="" first_reason="" done_set=" " cloned=() inst_failed=" " mains=" " vfail=""
  AP_STEP_NOTE=()
  for ((m = 0; m < ${#M_NAME[@]}; m++)); do mains="${mains}${M_NAME[$m]} "; done
  for entry in "${AP_STEPS[@]}"; do
    IFS='|' read -r kind arg label _ <<<"$entry"
    labels+=("$label")
    # the stream's step ids, KIND_TARGET as app update names its own
    # (an install is APP@SITE: install_SITE for one app, install_APP_SITE for a batch)
    if [[ "$kind" == "install" && "${#M_NAME[@]}" -le 1 ]]; then ids+=("install_${arg#*@}")
    else ids+=("${kind}${arg:+_${arg//@/_}}"); fi
  done
  fl_steps_define "${labels[@]}"
  fl_steps_ids "${ids[@]}"
  # the records first: whatever stops this run leaves what is still to do
  fl__ap_record "" "" "$done_set" || { fl_fail "nothing was run: without its record a stop could not be finished later"; return 1; }
  for entry in "${AP_STEPS[@]}"; do
    IFS='|' read -r kind arg label _ <<<"$entry"
    res=""
    if [[ -n "$clone_failed" ]]; then res="after failed ${clone_failed}"
    elif [[ -n "$py_failed" && ( "$kind" == "build" || "$kind" == "install" || "$kind" == "restart" ) ]]; then res="after failed requirements_python"
    elif [[ -n "$build_failed" && ( "$kind" == "install" || "$kind" == "restart" ) ]]; then res="after failed build"
    elif [[ "$kind" == "install" ]]; then
      # an app that this one requires failed to install on this site
      ia="${arg%%@*}"; is="${arg#*@}"
      fl__ap_blockers "$ia" "$mains"
      for a in $AP_BLK; do
        case "$inst_failed" in *" ${a}@${is} "*) res="after failed install of ${a}" ;; esac
      done
    fi
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
        fl__ap_clone_info "$arg"
        if ! fl_app_clone "$arg" "$AP_CI_REPO" "$AP_CI_BRANCH"; then res="failed"
        elif [[ -n "$AP_CI_PIN" ]] && ! fl__ap_pin_checkout "$FL_CLONED_DIR" "$AP_CI_PIN"; then
          # the clone does not reach the commit that was reviewed
          res="failed"
          fl_fail "${arg}: the clone does not reach the pinned commit (planned ${AP_CI_PIN:0:12}, cloned ${AP__GOT:0:12}); nothing was built or installed."
          fl_fix "Check the commit is on a branch or tag of ${AP_CI_REPO}, then: cd ${FL_BENCH_DIR} && bench remove-app ${FL_CLONED_DIR}, and plan again"
        elif ! fl__ap_at_commit "$FL_CLONED_DIR" "$AP_CI_SHA"; then
          # the branch moved between the plan and get-app: build and install
          # would run code nobody reviewed
          res="failed"
          fl_fail "${arg}: ${AP_CI_BRANCH} moved after the plan was made (planned ${AP_CI_SHA:0:12}, cloned ${AP__GOT:0:12}); nothing was built or installed."
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
        fl_app_install_on_sites "${arg%%@*}" "${arg#*@}" || { res="failed"; inst_failed="${inst_failed}${arg} "; } ;;
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
          install) fl_changed app "${arg%%@*}" "installed on ${arg#*@}" ;;
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
      # a clone that failed was rolled back: the records keep only the build
      # of the apps this run did clone, or go away when there are none
      s=""
      for a in ${cloned[@]+"${cloned[@]}"}; do s="${s}${s:+,}${a}"; done
      # a folder get-app left behind (listed in apps.txt) was not pip installed
      e="$(fl_app_existing_dir "$arg")"
      [[ -z "$e" ]] || { case ",${s}," in *",${e},"*) ;; *) s="${s}${s:+,}${e}" ;; esac; }
      for ((m = 0; m < ${#M_NAME[@]}; m++)); do
        [[ "${M_INVOLVED[$m]}" == "1" ]] || continue
        nm="${M_NAME[$m]}"
        if [[ -n "$s" && -n "$e" ]]; then
          fl_pending_write app_add "$nm" "${M_BRANCH[$m]}" "" "${M_COMMIT[$m]}" "$first_kind" "$first_reason" "requirements_python|${e}|Python requirements" "build|${s}|Build" "restart||Restart" || code=1
        elif [[ -n "$s" ]]; then
          fl_pending_write app_add "$nm" "${M_BRANCH[$m]}" "" "${M_COMMIT[$m]}" "$first_kind" "$first_reason" "build|${s}|Build" "restart||Restart" || code=1
        else
          fl_pending_remove "$nm"
        fi
      done
    elif ! fl__ap_record "$first_kind" "$first_reason" "$done_set"; then
      # the record is what a retry runs from: a step that cannot be recorded is a failed step
      code=1; clone_failed="pending record"
    fi
    i=$((i + 1))
  done
  fl_bench_redis_down
  for ((m = 0; m < ${#M_NAME[@]}; m++)); do
    nm="${M_NAME[$m]}"
    [[ -d "$(fl_app_path "$nm")" ]] || continue
    # shellcheck disable=SC2086  # the sites are words
    if ! fl__ap_verify "$nm" "${M_BRANCH[$m]}" "${M_CSRC[$m]}" "${M_COMMIT[$m]}" ${M_INSTALL[$m]}; then
      code=1; vfail="${vfail}${vfail:+, }${nm}"
    fi
  done
  # a failed step is already in the record; a verify that fails on its own is the news
  [[ -z "$vfail" || -n "$first_kind" ]] || fl__ap_record "verify" "apps/${vfail} did not pass the verify pass after the steps" "$done_set"
  if [[ "$code" == "0" ]]; then
    for ((m = 0; m < ${#M_NAME[@]}; m++)); do fl_pending_remove "${M_NAME[$m]}"; done
  fi
  fl_steps_summary
  return "$code"
}

# fl__ap_app_result NAME: one app's part of the result: whether this run
# cloned it, how its clone and the build went, and each install with the
# migrate that install-app runs (the app's patches and doctype sync; it has
# the install's own status)
fl__ap_app_result() {
  local name="$1" i=0 entry kind arg label st clone="null" was=false build="null" ins="" sep="" ia is
  for entry in ${AP_STEPS[@]+"${AP_STEPS[@]}"}; do
    IFS='|' read -r kind arg label _ <<<"$entry"
    st="${FL_STEP_STATUS[$i]:-pending}"
    case "$kind" in
      clone|clone_required) if [[ "$arg" == "$name" ]]; then clone="$(fl_json_str "$st")"; [[ "$st" != "done" ]] || was=true; fi ;;
      build) case ",${arg}," in *",${name},"*) build="$(fl_json_str "$st")" ;; esac ;;
      install)
        ia="${arg%%@*}"; is="${arg#*@}"
        if [[ "$ia" == "$name" ]]; then
          ins="${ins}${sep}{\"site\":$(fl_json_str "$is"),\"status\":$(fl_json_str "$st"),\"migrate\":$(fl_json_str "$st"),\"reason\":$(fl_json_str "${AP_STEP_NOTE[$i]:-}")}"; sep=","
        fi ;;
    esac
    i=$((i + 1))
  done
  printf '{"app":%s,"cloned":%s,"clone":%s,"build":%s,"installs":[%s]}' "$(fl_json_str "$name")" "$was" "$clone" "$build" "$ins"
}

# the result of --apply --json: the plan's first app, the token, each step's
# status and one entry per app (apps[]: the targets; required_apps[]: the
# ones cloned for them)
fl__ap_result_json() {
  local ok=1 i=0 sep="" out entry kind label m e
  [[ "$1" == "0" ]] || ok=0
  out="$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"app":%s,"branch":%s,"commit":%s,"commit_source":%s,"token":"%s","applied":true,"ok":%s,"steps":[' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$AP_NAME")" "$(fl_json_str "$AP_BRANCH")" \
    "$(fl_json_str "$AP_COMMIT")" "$(fl_json_str "$AP_COMMIT_SOURCE")" "$AP_TOKEN" "$(fl_json_bool "$ok")")"
  for entry in ${AP_STEPS[@]+"${AP_STEPS[@]}"}; do
    IFS='|' read -r kind _ label _ _ <<<"$entry"
    out="${out}${sep}{\"kind\":$(fl_json_str "$kind"),\"name\":$(fl_json_str "$label"),\"status\":$(fl_json_str "${FL_STEP_STATUS[$i]:-pending}"),\"reason\":$(fl_json_str "${AP_STEP_NOTE[$i]:-}")}"; sep=","
    i=$((i + 1))
  done
  out="${out}],\"apps\":["; sep=""
  for ((m = 0; m < ${#M_NAME[@]}; m++)); do
    out="${out}${sep}$(fl__ap_app_result "${M_NAME[$m]}")"; sep=","
  done
  out="${out}],\"required_apps\":["; sep=""
  for e in ${AP_ORDER[@]+"${AP_ORDER[@]}"}; do
    fl__ap_new_main "$e" && continue
    out="${out}${sep}$(fl__ap_app_result "$e")"; sep=","
  done
  printf '%s]}\n' "$out"
}

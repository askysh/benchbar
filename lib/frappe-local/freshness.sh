#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# freshness.sh: focus apps and the freshness of what they depend on.
#
#   benchbar app focus [--list] [--json] [--fetch]   every app: focus, why, behind
#   benchbar app focus NAME [--auto]                  pin NAME as focus (--auto: infer again)
#   benchbar app unfocus NAME                         pin NAME as not a focus app (ignore)
#
# A developer pulls the app they work on themselves, so it never gets a
# warning. What goes stale quietly are the apps it needs: doctor warns
# (dependency_behind) for every app a focus app needs, directly or through
# another app, that is behind its remote branch, and sums up the rest in one
# line (apps_behind).
#
# An app is a focus app when it is pinned so, or (pin auto) when it has
# local changes, is on a branch other than the one the profile names (or
# the remote's default), or has a commit by your git user.email in the last
# FL_FOCUS_DAYS days. Pins live in the bench's state file (APP_FOCUS).
#
# The network: doctor stays read only and never fetches on its own. Only
# --fetch (FL_FETCH=1, for doctor and app focus) fetches the dependencies'
# remote branches, each with a timeout and never with a prompt, and never
# with OFFLINE=1 or --dry-run. Every other read is local (the remote
# tracking refs, whoever fetched them last), so an app never fetched is
# unknown, never a failure.

FL_FOCUS_DAYS="${FL_FOCUS_DAYS:-14}"
FL_FETCH="${FL_FETCH:-0}"
FL_FRESHNESS_FETCH_TIMEOUT="${FL_FRESHNESS_FETCH_TIMEOUT:-20}"

# now as epoch seconds; FL_NOW fixes it, only under FL_TESTING=1 (tests). In a
# doctor run the clock is read once (facts.sh).
fl_now() {
  if [[ "${FL_TESTING:-}" == "1" && -n "${FL_NOW:-}" ]]; then printf '%s' "$FL_NOW"
  elif [[ -n "${FL_FACTS_DIR:-}" ]]; then fl_memo now date +%s
  else date +%s; fi
}

fl_epoch_iso() { [[ -n "$1" ]] || return 0; date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true; }

# ---------------------------------------------------------------- pins

# APP_FOCUS holds "app=focus app2=ignore"; an app without an entry is auto
fl_app_focus_pin() { fl_app_memo pin "$1" fl__app_focus_pin "$1"; }
fl__app_focus_pin() {
  local w pins
  if [[ "$FL_AF_ON" == "1" ]]; then pins="$FL_AF_PINS"
  else
    # the state file is read once per doctor run, not once for every app (facts.sh)
    fl_memo_v pins "app-focus-pins:${FL_BENCH_DIR}" fl_bstate_get APP_FOCUS || true
  fi
  # shellcheck disable=SC2086  # the pins are words
  for w in $pins; do
    [[ "${w%%=*}" == "$1" ]] && { printf '%s' "${w#*=}"; return 0; }
  done
  printf 'auto'
}

fl_app_focus_pin_set() {
  local app="$1" pin="$2" w out=""
  for w in $(fl_bstate_get APP_FOCUS); do
    [[ "${w%%=*}" == "$app" ]] || out="${out}${out:+ }${w}"
  done
  [[ "$pin" == "auto" ]] || out="${out}${out:+ }${app}=${pin}"
  fl_bstate_set APP_FOCUS "$out"
  # what the facts hold of the pins and of what they decide is old now
  fl_app_memo_clear
  [[ "$FL_AF_ON" == "1" ]] && FL_AF_PINS="$(fl_bstate_get APP_FOCUS)"
  return 0
}

# ---------------------------------------------------------------- inference

# The branch an app is expected to follow: the profile's (config/apps.tsv or
# the team profile), else the remote's default branch as git last saw it.
fl_app_reference_branch() { local b; fl__app_reference_branch_v b "$1"; printf '%s' "$b"; }
fl__app_reference_branch_v() {
  local app="$2" __rb remote
  fl__memo_v __rb policy "$app" fl_app_policy_branch "$app"
  if [[ -z "$__rb" ]]; then
    if fl__af_field "$app" remote; then remote="$FL_AF_VAL"; else remote="$(fl_app_remote "$app")"; fi
    if [[ -z "$remote" ]]; then :
    elif fl__af_field "$app" refhead; then __rb="$FL_AF_VAL"
    # the rows of the doctor run know it (HEAD of the remote is a symbolic ref); else git is asked
    elif fl__app_ref_v __rb "$app" "refs/remotes/${remote}/HEAD" sym; then __rb="${__rb#refs/remotes/}"
    else __rb="$(fl_app_git "$app" symbolic-ref -q --short "refs/remotes/${remote}/HEAD" 2>/dev/null || true)"; fi
    __rb="${__rb#"${remote}/"}"
  fi
  printf -v "$1" '%s' "$__rb"
}

# fl_app_focus_auto_reasons APP: why APP counts as a focus app, one reason
# per line; nothing when it does not.
fl_app_focus_auto_reasons() {
  local app="$1" branch ref email at="" now age
  fl_app_has_git "$app" || return 0
  fl_app_dirty "$app" && printf 'local changes\n'
  if fl__af_field "$app" branch; then branch="$FL_AF_VAL"; else branch="$(fl_app_branch "$app")"; fi
  fl__app_reference_branch_v ref "$app"
  if [[ -n "$branch" && -n "$ref" && "$branch" != "$ref" ]]; then printf 'on %s, not %s\n' "$branch" "$ref"; fi
  if fl__af_field "$app" email; then
    email="$FL_AF_VAL"; fl__af_field "$app" authored && at="$FL_AF_VAL"
  else
    fl_app_config_v email "$app" user.email
    [[ -n "$email" ]] && at="$(fl_app_git "$app" log -1 -i -F --author="<${email}>" --format=%at HEAD --branches 2>/dev/null || true)"
  fi
  if [[ -n "$email" ]]; then
    if [[ "$at" =~ ^[0-9]+$ ]]; then
      now="${FL_AF_NOW:-$(fl_now)}"; age=$(((now - at) / 86400))
      [[ "$age" -lt 0 ]] && age=0
      if [[ "$age" -lt "$FL_FOCUS_DAYS" ]]; then
        if [[ "$age" == "0" ]]; then printf 'your commit today\n'; else printf 'your commit %d day(s) ago\n' "$age"; fi
      fi
    fi
  fi
  return 0
}

# fl_app_focus_reasons APP: the pin's reason, or the inferred ones
fl_app_focus_reasons() { fl_app_memo reasons "$1" fl__app_focus_reasons "$1"; }
fl__app_focus_reasons() {
  local pin
  fl__memo_v pin pin "$1" fl_app_focus_pin "$1"
  case "$pin" in
    focus) printf 'pinned\n' ;;
    ignore) ;;
    *) fl_app_focus_auto_reasons "$1" ;;
  esac
}

# The focus apps of the bench, one per line (sets FL_FOCUS_APPS too)
FL_FOCUS_APPS=""
fl_focus_apps() {
  local app out="" apps=()
  while IFS= read -r app; do [[ -n "$app" ]] && apps+=("$app"); done < <(fl_apps_all)
  fl_app_memo_fill ${apps[@]+"${apps[@]}"}
  for app in ${apps[@]+"${apps[@]}"}; do
    # asked in this shell, so the answer stays for fl_freshness_app_json
    fl_app_focus_pin "$app" >/dev/null
    fl_app_focus_reasons "$app" >/dev/null
    if fl_app_memo_peek reasons "$app"; then [[ -n "$FL_MEMO_VAL" ]] && out="${out}${app}"$'\n'
    elif [[ -n "$(fl_app_focus_reasons "$app")" ]]; then out="${out}${app}"$'\n'; fi
  done
  FL_FOCUS_APPS="$out"
  printf '%s' "$out"
}

fl_is_focus_app() { [[ $'\n'"$FL_FOCUS_APPS"$'\n' == *$'\n'"$1"$'\n'* ]]; }

# fl_focus_dependencies: "DEP NEEDED_BY,NEEDED_BY" per line: every app of the
# bench a focus app needs through required_apps (transitively), the focus
# apps themselves left out. Reads FL_FOCUS_APPS (fl_focus_apps first).
fl_focus_dependencies() {
  local root queue next dep seen r pairs=""
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    queue="$root"; seen=" ${root} "
    while [[ -n "$queue" ]]; do
      next=""
      for dep in $queue; do
        while IFS= read -r r; do
          [[ -n "$r" ]] || continue
          case "$seen" in *" $r "*) continue ;; esac
          seen="${seen}${r} "
          [[ -d "$(fl_app_path "$r")" ]] || continue
          next="${next} ${r}"
          fl_is_focus_app "$r" || pairs="${pairs}${r} ${root}"$'\n'
        done < <(fl_app_required_apps "$dep")
      done
      queue="${next# }"
    done
  done <<<"$FL_FOCUS_APPS"
  [[ -n "$pairs" ]] || return 0
  printf '%s' "$pairs" | awk '
    { if (!($1 in by)) { order[++n] = $1; by[$1] = $2 } else if (index("," by[$1] ",", "," $2 ",") == 0) by[$1] = by[$1] "," $2 }
    END { for (i = 1; i <= n; i++) print order[i], by[order[i]] }'
}

# ---------------------------------------------------------------- behind

# fl_app_upstream APP: "REMOTE BRANCH" the app's branch follows (its
# configured merge branch, else the same name), nothing on a detached HEAD
fl_app_upstream() {
  local app="$1" b remote merge
  fl_app_has_git "$app" || return 0
  b="$(fl_app_branch "$app")"; [[ -n "$b" ]] || return 0
  remote="$(fl_app_remote "$app")"; [[ -n "$remote" ]] || return 0
  if fl__af_field "$app" merge; then merge="$FL_AF_VAL"
  else
    fl_app_config_v merge "$app" "branch.${b}.merge"
    merge="${merge#refs/heads/}"
  fi
  printf '%s %s' "$remote" "${merge:-$b}"
}

# fl_app_behind APP: "COUNT DAYS REMOTE/BRANCH" from the remote tracking ref
# as last fetched; nothing when it cannot tell (no upstream, never fetched).
# Both are counted on the first parent line of the remote branch: COUNT is
# the commits it got after HEAD, DAYS the age of the first of them. A merge
# can bring in commits of any age and number (another repository's history
# from 2011, a hotfix branch's commits), and those say nothing about how far
# behind HEAD is: a release merged in is one step, not every commit in it.
FL_BH_N=""; FL_BH_DAYS=""; FL_BH_UP=""
# fl__app_behind_v APP: fl_app_behind in FL_BH_N, FL_BH_DAYS and FL_BH_UP; 1 when
# it says nothing. From the loaded facts it needs no subshell.
fl__app_behind_v() {
  local app="$1" b remote merge n ct="" days=0 line
  FL_BH_N=""; FL_BH_DAYS=""; FL_BH_UP=""
  if [[ "$FL_AF_BEHIND" == "1" ]] && fl__af_field "$app" git && [[ "$FL_AF_VAL" == "1" ]]; then
    fl__af_v b "$app" branch; [[ -n "$b" ]] || return 1
    fl__af_v remote "$app" remote; [[ -n "$remote" ]] || return 1
    fl__af_v merge "$app" merge
    fl__af_v n "$app" bn
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    if [[ "$n" -gt 0 ]]; then
      fl__af_v ct "$app" bct
      [[ "$ct" =~ ^[0-9]+$ ]] && days=$(((${FL_AF_NOW:-$(fl_now)} - ct) / 86400))
      [[ "$days" -lt 0 ]] && days=0
    fi
    FL_BH_N="$n"; FL_BH_DAYS="$days"; FL_BH_UP="${remote}/${merge:-$b}"
    return 0
  fi
  line="$(fl_app_behind "$app")"
  [[ -n "$line" ]] || return 1
  read -r FL_BH_N FL_BH_DAYS FL_BH_UP <<<"$line"
}

fl_app_behind() {
  local app="$1" up remote branch ref n ct="" days=0 h hb
  up="$(fl_app_upstream "$app")"; [[ -n "$up" ]] || return 0
  remote="${up%% *}"; branch="${up#* }"
  if [[ "$FL_AF_BEHIND" == "1" ]] && fl__af_field "$app" bn; then
    n="$FL_AF_VAL"
    [[ "$n" =~ ^[0-9]+$ ]] || return 0
    if [[ "$n" -gt 0 ]]; then
      fl__af_field "$app" bct && ct="$FL_AF_VAL"
      [[ "$ct" =~ ^[0-9]+$ ]] && days=$((($(fl_now) - ct) / 86400))
      [[ "$days" -lt 0 ]] && days=0
    fi
    printf '%s %s %s/%s' "$n" "$days" "$remote" "$branch"
    return 0
  fi
  ref="refs/remotes/${remote}/${branch}"
  # a ref that does not exist fails the count, so no separate rev-parse is asked
  # (in a doctor run the rows of for-each-ref say whether HEAD and the ref are one commit: 0 behind)
  n=""
  if fl__app_head_v h "$app" && fl__app_ref_v hb "$app" "$ref" oid; then
    if [[ "${h#* }" == "$hb" ]]; then n=0; fi
  elif fl__app_head_v h "$app" && fl__app_refs_v hb "$app"; then
    # the ref is not among the refs (never fetched): the count fails, as git's would
    return 0
  fi
  [[ -n "$n" ]] || n="$(fl_app_git "$app" rev-list --count --first-parent "HEAD..${ref}" 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || return 0
  if [[ "$n" -gt 0 ]]; then
    ct="$(fl_app_git "$app" log --first-parent --format=%ct "HEAD..${ref}" 2>/dev/null)"; ct="${ct##*$'\n'}"
    [[ "$ct" =~ ^[0-9]+$ ]] && days=$((($(fl_now) - ct) / 86400))
    [[ "$days" -lt 0 ]] && days=0
  fi
  printf '%s %s %s/%s' "$n" "$days" "$remote" "$branch"
}

# ---------------------------------------------------------------- fetch

fl_freshness_file() {
  local f
  f="$(fl_bench_state_file_for "$FL_BENCH_DIR")"
  printf '%s.freshness' "${f%.env}"
}

fl_freshness_fetched_at() { fl_kv_get "$(fl_freshness_file)" FETCHED_AT; }

# 0 when --fetch asked for a fetch that may run (not OFFLINE=1, no dry run)
fl_freshness_fetch_wanted() {
  [[ "$FL_FETCH" == "1" && "${OFFLINE:-0}" != "1" && "${FL_DRY_RUN:-0}" != "1" ]]
}

# How old the numbers are: nothing when benchbar fetched in the last day,
# else "as of a fetch 3 days ago" or "as of your last git fetch"
fl_freshness_age_note() {
  local fetched
  fetched="$(fl_freshness_fetched_at)"
  if [[ ! "$fetched" =~ ^[0-9]+$ ]]; then printf 'as of your last git fetch'
  elif [[ $(($(fl_now) - fetched)) -ge 86400 ]]; then printf 'as of a fetch %s' "$(fl_age_words "$fetched")"; fi
  return 0
}

# fl_freshness_fetch APP...: fetches each app's upstream branch into its
# remote tracking ref, side by side, each with a timeout and no prompt.
# Only .git changes (like app update's fetch). Records the time only when
# every fetch worked (FETCHED_AT, for the age note): one failure keeps the
# old time, so the note still says the answer may be stale.
fl_freshness_fetch() {
  local app up remote branch dir ts args codes ok=0 failed=0 pids=()
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  codes="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-fresh.XXXXXX")"
  mkdir "$codes/err"
  for app in "$@"; do
    up="$(fl_app_upstream "$app")"; [[ -n "$up" ]] || continue
    remote="${up%% *}"; branch="${up#* }"; dir="$(fl_app_path "$app")"; args=()
    if fl_app_shallow "$app"; then
      ts="$(fl_app_git "$app" log -1 --format=%ct HEAD 2>/dev/null || true)"
      [[ "$ts" =~ ^[0-9]+$ ]] && args+=("--shallow-since=@$((ts - 1))")
    fi
    (
      code=0
      fl_run_capture_timeout "$FL_FRESHNESS_FETCH_TIMEOUT" /dev/null "${codes}/err/${app}" fl__in_dir "$FL_BENCH_DIR" env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10' \
        git -C "$dir" fetch --quiet --no-tags ${args[@]+"${args[@]}"} "$remote" "+refs/heads/${branch}:refs/remotes/${remote}/${branch}" || code=$?
      printf '%s' "$code" >"${codes}/${app}"
    ) &
    pids+=("$!")
  done
  for app in ${pids[@]+"${pids[@]}"}; do wait "$app" 2>/dev/null || true; done
  for app in "$codes"/err/*; do fl_log_file_append "$app"; done
  for app in "$codes"/*; do
    [[ -f "$app" ]] || continue
    if [[ "$(cat "$app")" == "0" ]]; then ok=1; else failed=1; fi
  done
  rm -rf "$codes"
  fl_app_facts_drop_behind
  # the refs just changed: what a doctor run kept about the apps' git is old
  fl_facts_forget "git"
  [[ "$ok" == "1" && "$failed" == "0" ]] && fl_kv_set "$(fl_freshness_file)" FETCHED_AT "$(fl_now)"
  return 0
}

# "12 days ago" for an epoch, "today" under a day
fl_age_words() {
  local d
  d=$((($(fl_now) - $1) / 86400))
  if [[ "$d" -le 0 ]]; then printf 'today'; elif [[ "$d" == "1" ]]; then printf 'a day ago'; else printf '%d days ago' "$d"; fi
}

fl_behind_words() {
  local n="$1" days="$2" c="commits"
  [[ "$n" == "1" ]] && c="commit"
  if [[ "$days" -le 0 ]]; then printf '%s %s behind' "$n" "$c"
  elif [[ "$days" == "1" ]]; then printf '%s %s / 1 day behind' "$n" "$c"
  else printf '%s %s / %s days behind' "$n" "$c" "$days"; fi
}

# ---------------------------------------------------------------- doctor

# fl_facts_warm_apps IDS: at the start of a doctor run, when a check that
# reads the apps' git will run (IDS, the checks of the run), the git questions
# those checks ask about every app are asked here, in the background, several
# apps at a time. The checks then find each answer kept (facts.sh) and start
# no git. Reads only; the checks keep their own order and their own words.
FL_WARM_PID=""
FL_WARM_FULL=0
FL_WARM_JOBS="${FL_WARM_JOBS:-8}"
fl_facts_warm_apps() {
  FL_WARM_PID=""
  # the freshness checks need all of it; the branch policy check only the branch and remote
  FL_WARM_FULL=0
  case "$1" in *" dependency_behind "*|*" apps_behind "*) FL_WARM_FULL=1 ;; esac
  case "$1" in *" dependency_behind "*|*" apps_behind "*|*" app_branch_policy "*) ;; *) return 0 ;; esac
  # a group of its own: a stop (facts.sh) reaches every git of it
  fl_par_group_on
  { (
    local app pids=() alive pid
    trap - EXIT ERR
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      fl_app_has_git "$app" || continue
      while [[ "${#pids[@]}" -ge "$FL_WARM_JOBS" ]]; do
        alive=()
        for pid in "${pids[@]}"; do if kill -0 "$pid" 2>/dev/null; then alive+=("$pid"); fi; done
        pids=(${alive[@]+"${alive[@]}"})
        [[ "${#pids[@]}" -lt "$FL_WARM_JOBS" ]] || wait "${pids[0]}" 2>/dev/null || true
      done
      { trap - EXIT ERR; fl__app_warm "$app"; } >/dev/null 2>&1 &
      pids+=("$!")
    done < <(fl_apps_all)
    wait
  ) & } 2>/dev/null
  FL_WARM_PID="$!"
  fl_par_group_off
}

# fl_facts_wait_warm: the checks that read the apps' git wait for the warming
fl_facts_wait_warm() {
  [[ -z "$FL_WARM_PID" ]] || wait "$FL_WARM_PID" 2>/dev/null || true
  FL_WARM_PID=""
}

# the questions of chk_app_branch_policy, fl_focus_apps and fl_app_behind for one app
fl__app_warm() {
  local reasons
  fl_app_branch "$1"; fl_app_remote "$1"
  [[ "$FL_WARM_FULL" == "1" ]] || return 0
  reasons="$(fl_app_focus_reasons "$1")"
  [[ -n "$reasons" ]] || fl_app_behind "$1"
  return 0
}

# One row per stale dependency of a focus app (CHK_MORE), or one ok row.
# The two checks share one inference per doctor run.
FL_FRESHNESS_READY=""
fl_freshness_prepare() {
  fl_facts_wait_warm
  [[ "$FL_FRESHNESS_READY" == "$FL_BENCH_DIR" ]] && return 0
  fl_app_facts_load
  fl_focus_apps >/dev/null
  FL_FOCUS_DEPS="$(fl_focus_dependencies)"
  FL_FRESHNESS_READY="$FL_BENCH_DIR"
}

chk_dependency_behind() {
  local deps dep by b n days up age stale="" unknown="" fresh=0 fix note="" hint=""
  FL_FRESHNESS_READY=""
  fl_freshness_prepare
  if [[ -z "$FL_FOCUS_APPS" ]]; then
    chk__set ok "no focus app (none has local changes, another branch or a recent commit of yours; benchbar app focus NAME marks one)"
    return 0
  fi
  deps="$FL_FOCUS_DEPS"
  if [[ -z "$deps" ]]; then
    chk__set ok "focus: $(printf '%s' "$FL_FOCUS_APPS" | tr '\n' ' ' | sed 's/ $//; s/ /, /g'); they need no other app of this bench"
    return 0
  fi
  # shellcheck disable=SC2046  # the app names are words
  fl_freshness_fetch_wanted && fl_freshness_fetch $(printf '%s\n' "$deps" | awk '{print $1}')
  age="$(fl_freshness_age_note)"
  if [[ -n "$age" ]]; then note=" (${age})"; hint="; run benchbar doctor --fetch to check the remotes"; fi
  while read -r dep by; do
    [[ -n "$dep" ]] || continue
    b="$(fl_app_behind "$dep")"
    if [[ -z "$b" ]]; then unknown="${unknown}${unknown:+, }${dep}"; continue; fi
    read -r n days up <<<"$b"
    if [[ "$n" == "0" ]]; then fresh=$((fresh + 1)); continue; fi
    stale=1
    if fl_app_dirty "$dep"; then
      fix="$(fl_fix_cmd cd "${FL_BENCH_DIR}/apps/${dep}" '&&' git status)   (commit or stash the changes, then: benchbar app update $(printf '%q' "$dep") --bench-dir $(printf '%q' "$FL_BENCH_DIR"))"
    else
      fix="$(fl_fix_cmd benchbar app update "$dep" --bench-dir "$FL_BENCH_DIR")"
    fi
    CHK_MORE+=("warn"$'\037'"${dep} (needed by ${by//,/, }) is $(fl_behind_words "$n" "$days") ${up}${note}"$'\037'"${fix}"$'\037')
  done <<<"$deps"
  [[ -n "$stale" ]] && return 0
  if [[ -n "$unknown" ]]; then
    chk__set ok "${fresh} dependenc$([[ "$fresh" == "1" ]] && printf y || printf ies) of the focus apps up to date${note}; unknown for ${unknown} (never fetched, or no upstream branch)${hint}"
  else
    chk__set ok "the ${fresh} app(s) the focus apps need are up to date with their remotes${note}${hint}"
  fi
}

# The other apps (neither focus nor needed by one): one line, local refs only.
chk_apps_behind() {
  local app deps b n days up behind="" m=0 k=0
  fl_freshness_prepare
  deps=" $(printf '%s\n' "$FL_FOCUS_DEPS" | awk '{print $1}' | tr '\n' ' ') "
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    fl_is_focus_app "$app" && continue
    case "$deps" in *" $app "*) continue ;; esac
    b="$(fl_app_behind "$app")"; [[ -n "$b" ]] || continue
    read -r n days up <<<"$b"
    k=$((k + 1))
    [[ "$n" == "0" ]] && continue
    m=$((m + 1)); behind="${behind}${behind:+, }${app} ${n}"
  done < <(fl_apps_all)
  if [[ "$m" -gt 0 ]]; then
    chk__set ok "${m} of ${k} other app(s) behind their remotes as last fetched (commits): ${behind}; no focus app needs them"
  elif [[ "$k" -gt 0 ]]; then
    chk__set ok "${k} other app(s) up to date with their remotes as last fetched"
  else
    chk__set ok "no other app with a remote branch"
  fi
}

# ---------------------------------------------------------------- commands

# the JSON fields of one app: focus, pin, reasons, requires, needed_by, behind
# (reads FL_FOCUS_APPS and FL_FOCUS_DEPS)
FL_FOCUS_DEPS=""
fl_freshness_app_json() { local j; fl_freshness_app_json_v j "$1"; printf '%s' "$j"; }
fl_freshness_app_json_v() {
  local __o="$1" app="$2" reasons line focus=0 by="" rest n="" days="" up="" pin req
  local j_focus j_pin j_reasons j_req j_by j_up j_n j_days
  fl__memo_v reasons reasons "$app" fl_app_focus_reasons "$app"
  fl__memo_v pin pin "$app" fl_app_focus_pin "$app"
  fl__memo_v req required "$app" fl_app_required_apps "$app"
  fl_is_focus_app "$app" && focus=1
  if [[ "$focus" != "1" ]]; then
    rest=$'\n'"$FL_FOCUS_DEPS"
    if [[ "$rest" == *$'\n'"${app} "* ]]; then rest="${rest#*$'\n'"${app} "}"; by="${rest%%$'\n'*}"; by="${by%% *}"; fi
  fi
  fl__app_behind_v "$app" && { n="$FL_BH_N"; days="$FL_BH_DAYS"; up="$FL_BH_UP"; }
  local lines=()
  while IFS= read -r line; do [[ -n "$line" ]] && lines+=("$line"); done <<<"$reasons"
  fl_json_bool_v j_focus "$focus"; fl_json_str_v j_pin "$pin"
  fl_json_words_v j_reasons ${lines[@]+"${lines[@]}"}
  # shellcheck disable=SC2086  # the app names are words
  fl_json_words_v j_req $req
  # shellcheck disable=SC2086
  fl_json_words_v j_by ${by//,/ }
  fl_json_str_v j_up "$up"; fl_json_num_v j_n "$n"; fl_json_num_v j_days "$days"
  printf -v "$__o" '"focus":%s,"focus_pin":%s,"focus_reasons":%s,"requires":%s,"needed_by":%s,"upstream":%s,"behind":%s,"behind_days":%s' \
    "$j_focus" "$j_pin" "$j_reasons" "$j_req" "$j_by" "$j_up" "$j_n" "$j_days"
}

fl_cmd_app_focus_list() {
  local app sep="" rows=() reasons by b n days up state fetched
  FL_FRESHNESS_READY=""
  fl_freshness_prepare
  # shellcheck disable=SC2046  # the app names are words
  if [[ -n "$FL_FOCUS_DEPS" ]] && fl_freshness_fetch_wanted; then fl_freshness_fetch $(printf '%s\n' "$FL_FOCUS_DEPS" | awk '{print $1}'); fi
  fetched="$(fl_freshness_fetched_at)"
  if [[ "$OPT_JSON" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"focus_days":%d,"fetched_at":%s,"apps":[' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$FL_FOCUS_DAYS" "$(fl_json_str "$(fl_epoch_iso "$fetched")")"
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      printf '%s{"name":%s,%s}' "$sep" "$(fl_json_str "$app")" "$(fl_freshness_app_json "$app")"; sep=","
    done < <(fl_apps_all)
    printf ']}\n'
    return 0
  fi
  rows+=("App|Focus|Why|Needed by|Behind")
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    state="no"; fl_is_focus_app "$app" && state="yes"
    [[ "$(fl_app_focus_pin "$app")" == "auto" ]] || state="${state} (pinned)"
    reasons="$(fl_app_focus_reasons "$app" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    by=""; [[ "$state" == no* ]] && by="$(printf '%s\n' "$FL_FOCUS_DEPS" | awk -v a="$app" '$1 == a {print $2; exit}')"
    b="$(fl_app_behind "$app")"; n="?"
    if [[ -n "$b" ]]; then read -r n days up <<<"$b"; [[ "$n" == "0" ]] && n="up to date" || n="${n} (${days}d) ${up}"; fi
    rows+=("${app}|${state}|${reasons:--}|${by//,/, }|${n}")
  done < <(fl_apps_all)
  fl_table "${rows[@]}"
  if [[ "$fetched" =~ ^[0-9]+$ ]]; then fl_note "dependencies last fetched $(fl_age_words "$fetched"); --fetch fetches them now"; else fl_note "numbers as of your last git fetch; --fetch fetches the dependencies now (doctor never fetches without it)"; fi
}

fl_cmd_app_focus() {
  local cmd="$1" app="" a auto=0 list=0 pin reasons=()
  shift
  for a in "$@"; do
    case "$a" in
      --json) OPT_JSON=1 ;;
      --list) list=1 ;;
      --auto) auto=1 ;;
      --fetch) FL_FETCH=1 ;;
      -*) fl_die "Unknown option for app ${cmd}: $a" "Use: benchbar app focus [--list] [--json] [--fetch] | app focus NAME [--auto] | app unfocus NAME" ;;
      *) [[ -z "$app" ]] && app="$a" ;;
    esac
  done
  fl_require_bench
  if [[ -z "$app" ]]; then
    [[ "$cmd" == "focus" ]] || fl_die "Usage: benchbar app unfocus NAME"
    fl_cmd_app_focus_list
    return 0
  fi
  [[ "$list" == "0" ]] || fl_die "--list takes no app name." "benchbar app focus --list"
  fl_has_line "$(fl_apps_all || true)" "$app" || fl_die "${app} is not an app of this bench." "benchbar app list shows the apps."
  if [[ "$cmd" == "unfocus" ]]; then pin=ignore; elif [[ "$auto" == "1" ]]; then pin=auto; else pin=focus; fi
  fl_bench_state_migrate "$FL_BENCH_DIR"
  fl_app_focus_pin_set "$app" "$pin"
  fl_focus_apps >/dev/null
  if [[ "$OPT_JSON" == "1" ]]; then
    while IFS= read -r a; do [[ -n "$a" ]] && reasons+=("$a"); done < <(fl_app_focus_reasons "$app")
    fl_json_doc_begin
    fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"app":%s,"pin":%s,"focus":%s,"reasons":%s}' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$app")" "$(fl_json_str "$pin")" \
      "$(fl_json_bool "$(fl_is_focus_app "$app" && printf 1 || printf 0)")" "$(fl_json_str_array ${reasons[@]+"${reasons[@]}"})")"
    return 0
  fi
  case "$pin" in
    focus) fl_ok "${app} is a focus app (pinned): doctor never warns about it, and warns when an app it needs falls behind" ;;
    ignore) fl_ok "${app} is not a focus app (pinned): doctor checks it like any other app; benchbar app focus ${app} --auto infers again" ;;
    auto)
      if fl_is_focus_app "$app"; then fl_ok "${app}: inferred again, a focus app ($(fl_app_focus_reasons "$app" | tr '\n' ',' | sed 's/,$//; s/,/, /g'))"
      else fl_ok "${app}: inferred again, not a focus app"; fi ;;
  esac
}

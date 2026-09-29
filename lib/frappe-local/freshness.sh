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
# The network: doctor fetches the dependencies' remote branches at most once
# a day (FL_FRESHNESS_TTL), once an hour after a failed try, each with a
# timeout, never with a prompt, and never with OFFLINE=1 or --dry-run. Every
# other read is local (the remote tracking refs), so without a network the
# numbers are those of the last fetch, and an app never fetched is unknown.

FL_FOCUS_DAYS="${FL_FOCUS_DAYS:-14}"
FL_FRESHNESS_TTL="${FL_FRESHNESS_TTL:-86400}"
FL_FRESHNESS_RETRY="${FL_FRESHNESS_RETRY:-3600}"
FL_FRESHNESS_FETCH_TIMEOUT="${FL_FRESHNESS_FETCH_TIMEOUT:-20}"

# now as epoch seconds; FL_NOW fixes it (tests)
fl_now() { if [[ -n "${FL_NOW:-}" ]]; then printf '%s' "$FL_NOW"; else date +%s; fi; }

fl_epoch_iso() { [[ -n "$1" ]] || return 0; date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true; }

# ---------------------------------------------------------------- pins

# APP_FOCUS holds "app=focus app2=ignore"; an app without an entry is auto
fl_app_focus_pin() {
  local w
  for w in $(fl_bstate_get APP_FOCUS); do
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
}

# ---------------------------------------------------------------- inference

# The branch an app is expected to follow: the profile's (config/apps.tsv or
# the team profile), else the remote's default branch as git last saw it.
fl_app_reference_branch() {
  local app="$1" b remote
  b="$(fl_app_policy_branch "$app")"
  if [[ -z "$b" ]]; then
    remote="$(fl_app_remote "$app")"
    [[ -n "$remote" ]] && b="$(fl_app_git "$app" symbolic-ref -q --short "refs/remotes/${remote}/HEAD" 2>/dev/null || true)"
    b="${b#"${remote}/"}"
  fi
  printf '%s' "$b"
}

# fl_app_focus_auto_reasons APP: why APP counts as a focus app, one reason
# per line; nothing when it does not.
fl_app_focus_auto_reasons() {
  local app="$1" branch ref email at now age
  fl_app_has_git "$app" || return 0
  fl_app_dirty "$app" && printf 'local changes\n'
  branch="$(fl_app_branch "$app")"
  ref="$(fl_app_reference_branch "$app")"
  if [[ -n "$branch" && -n "$ref" && "$branch" != "$ref" ]]; then printf 'on %s, not %s\n' "$branch" "$ref"; fi
  email="$(fl_app_git "$app" config user.email 2>/dev/null || true)"
  if [[ -n "$email" ]]; then
    at="$(fl_app_git "$app" log -1 -i -F --author="<${email}>" --format=%at HEAD --branches 2>/dev/null || true)"
    if [[ "$at" =~ ^[0-9]+$ ]]; then
      now="$(fl_now)"; age=$(((now - at) / 86400))
      [[ "$age" -lt 0 ]] && age=0
      if [[ "$age" -lt "$FL_FOCUS_DAYS" ]]; then
        if [[ "$age" == "0" ]]; then printf 'your commit today\n'; else printf 'your commit %d day(s) ago\n' "$age"; fi
      fi
    fi
  fi
  return 0
}

# fl_app_focus_reasons APP: the pin's reason, or the inferred ones
fl_app_focus_reasons() {
  case "$(fl_app_focus_pin "$1")" in
    focus) printf 'pinned\n' ;;
    ignore) ;;
    *) fl_app_focus_auto_reasons "$1" ;;
  esac
}

# The focus apps of the bench, one per line (sets FL_FOCUS_APPS too)
FL_FOCUS_APPS=""
fl_focus_apps() {
  local app out=""
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    [[ -n "$(fl_app_focus_reasons "$app")" ]] && out="${out}${app}"$'\n'
  done < <(fl_apps_all)
  FL_FOCUS_APPS="$out"
  printf '%s' "$out"
}

fl_is_focus_app() { printf '%s' "$FL_FOCUS_APPS" | grep -qxF "$1"; }

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
  merge="$(fl_app_git "$app" config --get "branch.${b}.merge" 2>/dev/null || true)"
  merge="${merge#refs/heads/}"
  printf '%s %s' "$remote" "${merge:-$b}"
}

# fl_app_behind APP: "COUNT DAYS REMOTE/BRANCH" from the remote tracking ref
# as last fetched (DAYS: the age of the oldest commit HEAD lacks); nothing
# when it cannot tell (no upstream, never fetched).
fl_app_behind() {
  local app="$1" up remote branch ref n ct days=0
  up="$(fl_app_upstream "$app")"; [[ -n "$up" ]] || return 0
  remote="${up%% *}"; branch="${up#* }"
  ref="refs/remotes/${remote}/${branch}"
  fl_app_git "$app" rev-parse -q --verify "${ref}^{commit}" >/dev/null 2>&1 || return 0
  n="$(fl_app_git "$app" rev-list --count "HEAD..${ref}" 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || return 0
  if [[ "$n" -gt 0 ]]; then
    ct="$(fl_app_git "$app" log --format=%ct "HEAD..${ref}" 2>/dev/null | tail -n1)"
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

# 0 when the last good fetch is older than a day and the last try older
# than an hour; never with OFFLINE=1 or in a dry run
fl_freshness_fetch_due() {
  local file now got tried
  [[ "${OFFLINE:-0}" == "1" || "${FL_DRY_RUN:-0}" == "1" ]] && return 1
  file="$(fl_freshness_file)"; now="$(fl_now)"
  got="$(fl_kv_get "$file" FETCHED_AT)"; tried="$(fl_kv_get "$file" TRIED_AT)"
  [[ "$got" =~ ^[0-9]+$ && $((now - got)) -lt "$FL_FRESHNESS_TTL" ]] && return 1
  [[ "$tried" =~ ^[0-9]+$ && $((now - tried)) -lt "$FL_FRESHNESS_RETRY" ]] && return 1
  return 0
}

# fl_freshness_fetch APP...: fetches each app's upstream branch into its
# remote tracking ref, side by side, each with a timeout and no prompt.
# Only .git changes (like app update's fetch). Records the try, and the
# time when at least one fetch worked.
fl_freshness_fetch() {
  local app up remote branch dir ts args codes ok=0 pids=()
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  codes="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-fresh.XXXXXX")"
  for app in "$@"; do
    up="$(fl_app_upstream "$app")"; [[ -n "$up" ]] || continue
    remote="${up%% *}"; branch="${up#* }"; dir="$(fl_app_path "$app")"; args=()
    if fl_app_shallow "$app"; then
      ts="$(fl_app_git "$app" log -1 --format=%ct HEAD 2>/dev/null || true)"
      [[ "$ts" =~ ^[0-9]+$ ]] && args+=("--shallow-since=@$((ts - 1))")
    fi
    (
      code=0
      fl_capture_timeout "$FL_FRESHNESS_FETCH_TIMEOUT" /dev/null env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10' \
        git -C "$dir" fetch --quiet --no-tags ${args[@]+"${args[@]}"} "$remote" "+refs/heads/${branch}:refs/remotes/${remote}/${branch}" || code=$?
      printf '%s' "$code" >"${codes}/${app}"
    ) &
    pids+=("$!")
  done
  for app in ${pids[@]+"${pids[@]}"}; do wait "$app" 2>/dev/null || true; done
  for app in "$codes"/*; do [[ -f "$app" && "$(cat "$app")" == "0" ]] && ok=1; done
  rm -rf "$codes"
  fl_kv_set "$(fl_freshness_file)" TRIED_AT "$(fl_now)"
  [[ "$ok" == "1" ]] && fl_kv_set "$(fl_freshness_file)" FETCHED_AT "$(fl_now)"
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

# One row per stale dependency of a focus app (CHK_MORE), or one ok row.
# The two checks share one inference per doctor run.
FL_FRESHNESS_READY=""
fl_freshness_prepare() {
  [[ "$FL_FRESHNESS_READY" == "$FL_BENCH_DIR" ]] && return 0
  fl_focus_apps >/dev/null
  FL_FOCUS_DEPS="$(fl_focus_dependencies)"
  FL_FRESHNESS_READY="$FL_BENCH_DIR"
}

chk_dependency_behind() {
  local deps dep by b n days up fetched stale="" unknown="" fresh=0 fix note=""
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
  fl_freshness_fetch_due && fl_freshness_fetch $(printf '%s\n' "$deps" | awk '{print $1}')
  fetched="$(fl_freshness_fetched_at)"
  if [[ "$fetched" =~ ^[0-9]+$ ]]; then
    [[ $(($(fl_now) - fetched)) -ge $((2 * FL_FRESHNESS_TTL)) ]] && note=" (as of the fetch $(fl_age_words "$fetched"), offline since)"
  fi
  while read -r dep by; do
    [[ -n "$dep" ]] || continue
    b="$(fl_app_behind "$dep")"
    if [[ -z "$b" ]]; then unknown="${unknown}${unknown:+, }${dep}"; continue; fi
    read -r n days up <<<"$b"
    if [[ "$n" == "0" ]]; then fresh=$((fresh + 1)); continue; fi
    stale=1
    if fl_app_dirty "$dep"; then
      fix="cd ${FL_BENCH_DIR}/apps/${dep} && git status   (commit or stash the changes, then: benchbar app update ${dep} --bench-dir ${FL_BENCH_DIR})"
    else
      fix="benchbar app update ${dep} --bench-dir ${FL_BENCH_DIR}"
    fi
    CHK_MORE+=("warn"$'\037'"${dep} (needed by ${by//,/, }) is $(fl_behind_words "$n" "$days") ${up}${note}"$'\037'"${fix}"$'\037')
  done <<<"$deps"
  [[ -n "$stale" ]] && return 0
  if [[ -n "$unknown" ]]; then
    chk__set ok "${fresh} dependenc$([[ "$fresh" == "1" ]] && printf y || printf ies) of the focus apps up to date${note}; unknown for ${unknown} (never fetched, or no upstream branch)"
  else
    chk__set ok "the ${fresh} app(s) the focus apps need are up to date with their remotes${note}"
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
fl_freshness_app_json() {
  local app="$1" reasons=() r focus=0 by="" b n="" days="" up=""
  while IFS= read -r r; do [[ -n "$r" ]] && reasons+=("$r"); done < <(fl_app_focus_reasons "$app")
  fl_is_focus_app "$app" && focus=1
  [[ "$focus" == "1" ]] || by="$(printf '%s\n' "$FL_FOCUS_DEPS" | awk -v a="$app" '$1 == a {print $2; exit}')"
  b="$(fl_app_behind "$app")"
  [[ -n "$b" ]] && read -r n days up <<<"$b"
  # shellcheck disable=SC2046  # the app names are words
  printf '"focus":%s,"focus_pin":%s,"focus_reasons":%s,"requires":%s,"needed_by":%s,"upstream":%s,"behind":%s,"behind_days":%s' \
    "$(fl_json_bool "$focus")" "$(fl_json_str "$(fl_app_focus_pin "$app")")" "$(fl_json_str_array ${reasons[@]+"${reasons[@]}"})" \
    "$(fl_json_str_array $(fl_app_required_apps "$app"))" "$(fl_json_str_array $(printf '%s' "$by" | tr ',' ' '))" \
    "$(fl_json_str "$up")" "$(fl_json_num "$n")" "$(fl_json_num "$days")"
}

fl_cmd_app_focus_list() {
  local fetch="$1" app sep="" rows=() reasons by b n days up state fetched
  FL_FRESHNESS_READY=""
  fl_freshness_prepare
  # shellcheck disable=SC2046  # the app names are words
  if [[ "$fetch" == "1" && -n "$FL_FOCUS_DEPS" && "${OFFLINE:-0}" != "1" ]]; then fl_freshness_fetch $(printf '%s\n' "$FL_FOCUS_DEPS" | awk '{print $1}'); fi
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
  if [[ "$fetched" =~ ^[0-9]+$ ]]; then fl_note "dependencies last fetched $(fl_age_words "$fetched"); --fetch fetches them now"; else fl_note "dependencies not fetched yet; --fetch fetches them now (doctor does once a day)"; fi
}

fl_cmd_app_focus() {
  local cmd="$1" app="" a auto=0 list=0 fetch=0 pin reasons=()
  shift
  for a in "$@"; do
    case "$a" in
      --json) OPT_JSON=1 ;;
      --list) list=1 ;;
      --auto) auto=1 ;;
      --fetch) fetch=1 ;;
      -*) fl_die "Unknown option for app ${cmd}: $a" "Use: benchbar app focus [--list] [--json] [--fetch] | app focus NAME [--auto] | app unfocus NAME" ;;
      *) [[ -z "$app" ]] && app="$a" ;;
    esac
  done
  fl_require_bench
  if [[ -z "$app" ]]; then
    [[ "$cmd" == "focus" ]] || fl_die "Usage: benchbar app unfocus NAME"
    fl_cmd_app_focus_list "$fetch"
    return 0
  fi
  [[ "$list" == "0" ]] || fl_die "--list takes no app name." "benchbar app focus --list"
  fl_apps_all | grep -qxF "$app" || fl_die "${app} is not an app of this bench." "benchbar app list shows the apps."
  if [[ "$cmd" == "unfocus" ]]; then pin=ignore; elif [[ "$auto" == "1" ]]; then pin=auto; else pin=focus; fi
  fl_bench_state_migrate "$FL_BENCH_DIR"
  fl_app_focus_pin_set "$app" "$pin"
  fl_focus_apps >/dev/null
  if [[ "$OPT_JSON" == "1" ]]; then
    while IFS= read -r a; do [[ -n "$a" ]] && reasons+=("$a"); done < <(fl_app_focus_reasons "$app")
    printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"app":%s,"pin":%s,"focus":%s,"reasons":%s}\n' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$app")" "$(fl_json_str "$pin")" \
      "$(fl_json_bool "$(fl_is_focus_app "$app" && printf 1 || printf 0)")" "$(fl_json_str_array ${reasons[@]+"${reasons[@]}"})"
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

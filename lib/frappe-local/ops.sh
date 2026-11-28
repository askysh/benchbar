#!/usr/bin/env bash
#
# ops.sh: operation handles (docs/json-schema.md, "Operation handles").
#
# Every run that changes things gets an op_id and a small record,
# <state folder>/ops/<op_id>.json, written when the run starts, at each step
# and progress line and when it ends (one temp file and one rename each, so a
# reader never sees half a record). `benchbar op status|list|wait` read the
# records; --background starts a long command detached and returns its
# op_id at once. A record that says "running" or "starting" whose process is
# gone is shown as "interrupted": a run that was killed writes no done line.
#
# ui.sh sources this file, so the phase scripts (child processes of install)
# update the same record: they inherit FL_OP_ID and friends, and only the
# process that began the op (FL_OP_OWNER) ends it.
#
# Compatible with macOS /bin/bash 3.2.

FL_OP_ID="${FL_OP_ID:-}"
FL_OP_OWNER="${FL_OP_OWNER:-}"
FL_OP_STARTED="${FL_OP_STARTED:-}"
FL_OP_COMMAND="${FL_OP_COMMAND:-}"
# `,"op_id":"..."` for the event lines (fl_jsonl and friends); empty without an op
FL_OP_JSON="${FL_OP_JSON:-}"
FL_OP_BACKGROUND="${FL_OP_BACKGROUND:-0}"
FL_OP_ENDED=0
# the state the record says while the run goes on: "starting" for a detached run until it holds the lock
# (fl_op_running), else "running"
FL_OP_STATE="running"
# the process's start time (see fl_op_pid_start_v), so a reader can tell the run from a process that reuses its pid
FL_OP_PID_START="${FL_OP_PID_START:-}"
# the site the command works on (site add NAME ...), and the bench found before the run's context is set up
FL_OP_SITE="${FL_OP_SITE:-}"
FL_OP_BENCH="${FL_OP_BENCH:-}"
# what the record says about the step that runs and the last progress line of this process
FL_OP_STEP_ID=""
FL_OP_STEP_NAME=""
FL_OP_STEP_STATUS=""
FL_OP_PROG_LABEL=""
FL_OP_PROG_ELAPSED=""
FL_OP_PROG_BYTES=""
# commands that never get a record: fg and self-update end by exec (no exit trap runs, the record
# would say "running" until the program that replaced them ended)
FL_OP_NOT_FOR="fg self-update"
# a record is "starting" from the moment --background wrote it until the detached run takes it over
FL_OP_START_GRACE=60
# a stamp this many seconds ahead of the clock is a clock that stepped back (VM time sync: seconds); more is a bad stamp
FL_OP_CLOCK_SKEW=600
FL_OP_ID_RE='^op-[0-9]{8}-[0-9]{6}-[0-9]+(-[0-9]+)?$'

fl_ops_dir() { printf '%s/ops' "${FL_STATE_DIR}"; }

# fl_op_id_ok TEXT: whether TEXT is an op id (so it can be a file name)
fl_op_id_ok() { [[ "${1:-}" =~ $FL_OP_ID_RE ]]; }

# fl__op_str_v VAR TEXT: TEXT as a JSON string, null when empty
fl__op_str_v() {
  if [[ -n "${2:-}" ]]; then fl_json_str_v "$1" "$2"; else printf -v "$1" '%s' null; fi
}

# fl__op_stamp_secs_v VAR STAMP: STAMP (YYYYMMDD-HHMMSS) as seconds on a scale that counts its fields as UTC (days from
# the civil date, in bash arithmetic only). Two stamps of one clock differ by the real seconds between them.
fl__op_stamp_secs_v() {
  local __y __m __d __era __yoe __doy __doe
  __y=$((10#${2:0:4})); __m=$((10#${2:4:2})); __d=$((10#${2:6:2}))
  [[ "$__m" -gt 2 ]] || __y=$((__y - 1))
  __era=$((__y / 400)); __yoe=$((__y - __era * 400))
  __doy=$(( (153 * (__m > 2 ? __m - 3 : __m + 9) + 2) / 5 + __d - 1 ))
  __doe=$((__yoe * 365 + __yoe / 4 - __yoe / 100 + __doy))
  printf -v "$1" '%s' $(( (__era * 146097 + __doe - 719468) * 86400 + 10#${2:9:2} * 3600 + 10#${2:11:2} * 60 + 10#${2:13:2} ))
}

# fl_op_new_id_v VAR: a new op id, its file made empty (noclobber, so two runs never share one). The id sorts
# after every id that is already there (fl_op_ids_v): the clock can step back (a VM that syncs its time does so by
# seconds, WSL every 30 s), and a run that starts after a step would carry an older stamp than the run before it.
# So when the clock is not past the newest stamp in the folder, the id takes that stamp and a -N one above the
# newest -N of it, and N, not the pid, orders the runs of one stamp. A stamp more than FL_OP_CLOCK_SKEW seconds
# ahead of the clock is not a step back (a resumed VM, a bad RTC): it is ignored, so one such op does not hold the
# stamp of every op after it (it stays on top of the list until it is pruned). A name read in bash only, no fork.
fl_op_new_id_v() {
  local __dir __stamp __id __n=0 __max __top="" __topn=0 __f __b __s __k __now="" __sec
  local __re='^op-([0-9]{8}-[0-9]{6})-[0-9]+(-([0-9]+))?\.json$'
  __dir="$(fl_ops_dir)"
  mkdir -p "$__dir" 2>/dev/null || return 1
  __stamp="$(date +%Y%m%d-%H%M%S)"
  for __f in "$__dir"/op-*.json; do
    __b="${__f##*/}"
    [[ "$__b" =~ $__re ]] || continue
    __s="${BASH_REMATCH[1]}"; __k="${BASH_REMATCH[3]:-0}"
    if [[ "$__s" > "$__stamp" ]]; then
      [[ -n "$__now" ]] || fl__op_stamp_secs_v __now "$__stamp"
      fl__op_stamp_secs_v __sec "$__s"
      [[ $((__sec - __now)) -le "$FL_OP_CLOCK_SKEW" ]] || continue
    fi
    if [[ "$__s" > "$__top" ]]; then __top="$__s"; __topn="$__k"
    elif [[ "$__s" == "$__top" && "$__k" -gt "$__topn" ]]; then __topn="$__k"; fi
  done
  if [[ -n "$__top" && ! "$__stamp" > "$__top" ]]; then __stamp="$__top"; __n=$((__topn + 1)); fi
  __max=$((__n + 20))
  __id="op-${__stamp}-$$"
  [[ "$__n" -eq 0 ]] || __id="${__id}-${__n}"
  until ( set -o noclobber; : >"${__dir}/${__id}.json" ) 2>/dev/null; do
    __n=$((__n + 1))
    [[ "$__n" -le "$__max" ]] || return 1
    __id="op-${__stamp}-$$-${__n}"
  done
  printf -v "$1" '%s' "$__id"
}

# fl_op_pid_start_v VAR PID: when the process started, as text (empty when it cannot be read). Linux: field 22 of
# /proc/PID/stat (after the last ")", the command name may hold spaces), no process; macOS: ps -o lstart=.
# Only the writer of a record and `benchbar op` ask: the lean status path never does.
fl_op_pid_start_v() {
  local __line="" __rest __w
  if [[ -r /proc/self/stat ]]; then
    IFS= read -r __line <"/proc/${2}/stat" 2>/dev/null || __line=""
    if [[ -n "$__line" ]]; then
      __rest="${__line##*) }"
      # shellcheck disable=SC2206
      __w=($__rest)
      __line="${__w[19]:-}"
    fi
  else
    __line="$(ps -o lstart= -p "$2" 2>/dev/null || true)"
    __line="${__line#"${__line%%[![:space:]]*}"}"; __line="${__line%"${__line##*[![:space:]]}"}"
  fi
  printf -v "$1" '%s' "$__line"
}

# fl_op_context: the site this command works on (the NAME of site add|backup|restore|drop NAME) and the bench,
# found before the run's own context exists: a run that is refused at the lock still says which bench and site
fl_op_context() {
  FL_OP_SITE=""
  if [[ "${COMMAND:-}" == "site" ]] && declare -F fl_site_arg_name >/dev/null; then FL_OP_SITE="$(fl_site_arg_name 2>/dev/null || true)"; fi
  [[ -n "$FL_OP_SITE" ]] || FL_OP_SITE="${OPT_SITE:-}"
  FL_OP_BENCH="${FL_BENCH_DIR:-}"
  [[ -n "$FL_OP_BENCH" ]] || FL_OP_BENCH="${OPT_BENCH_DIR:-}"
  if [[ -z "$FL_OP_BENCH" ]] && declare -F fl_bench_detect >/dev/null; then
    FL_OP_BENCH="$( (fl_bench_detect "" >/dev/null 2>&1; printf '%s' "${FL_BENCH_DIR:-}") 2>/dev/null || true)"
  fi
}

# fl_op_write STATE [EXIT]: the record of the run that FL_OP_ID names, whole, through a temp file and a
# rename. STATE is starting, running, done or failed. Never ends the run: a folder that cannot be
# written leaves the run without a record, nothing more.
fl_op_write() {
  local state="$1" code="${2:-}" dir f_bench f_site f_log f_out f_cmd f_ps step="null" prog="null" now fin="null" ex="null" tmp pid
  [[ -n "$FL_OP_ID" ]] || return 0
  [[ "$FL_OP_ENDED" != "1" || "$state" == "done" || "$state" == "failed" ]] || return 0
  dir="$(fl_ops_dir)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fl__op_str_v f_bench "${FL_BENCH_DIR:-${FL_OP_BENCH:-}}"
  fl__op_str_v f_site "${FL_OP_SITE:-${FL_SITE:-}}"
  fl__op_str_v f_ps "$FL_OP_PID_START"
  fl__op_str_v f_log "${FL_LOG_FILE:-}"
  fl__op_str_v f_cmd "$FL_OP_COMMAND"
  f_out=null
  [[ "$FL_OP_BACKGROUND" != "1" ]] || fl_json_str_v f_out "${dir}/${FL_OP_ID}.jsonl"
  if [[ -n "$FL_OP_STEP_ID" ]]; then
    step="{\"id\":$(fl_json_str "$FL_OP_STEP_ID"),\"name\":$(fl_json_str "$FL_OP_STEP_NAME"),\"status\":$(fl_json_str "$FL_OP_STEP_STATUS")}"
  fi
  if [[ -n "$FL_OP_PROG_LABEL" ]]; then
    prog="{\"label\":$(fl_json_str "$FL_OP_PROG_LABEL"),\"elapsed\":$(fl_json_num "$FL_OP_PROG_ELAPSED"),\"bytes\":$(fl_json_num "$FL_OP_PROG_BYTES")}"
  fi
  [[ -z "$code" ]] || { ex="$code"; fin="\"${now}\""; }
  pid="${FL_OP_OWNER:-null}"
  tmp="${dir}/.${FL_OP_ID}.$$.tmp"
  {
    printf '{"schema_version":%d,"cli_version":"%s","op_id":"%s","state":"%s","command":%s,"bench":%s,"site":%s,"pid":%s,"pid_start":%s,"started_at":"%s","updated_at":"%s","finished_at":%s,"step":%s,"progress":%s,"exit":%s,"log":%s,"output":%s,"background":%s}\n' \
      "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$FL_OP_ID" "$state" "$f_cmd" "$f_bench" "$f_site" "$pid" "$f_ps" \
      "${FL_OP_STARTED:-$now}" "$now" "$fin" "$step" "$prog" "$ex" "$f_log" "$f_out" \
      "$([[ "$FL_OP_BACKGROUND" == "1" ]] && printf true || printf false)" >"$tmp" \
      && mv -f "$tmp" "${dir}/${FL_OP_ID}.json"
  } 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  return 0
}

# fl_op_begin: the run that just made its log is an op, unless it is a dry run. A detached run
# (--background) takes the id its launcher wrote (FL_OP_PRESET, only when that record still says
# "starting"); every other run makes a new one. Exported, so the phase scripts update the same record.
fl_op_begin() {
  local id="" key preset="${FL_OP_PRESET:-}"
  [[ -z "$FL_OP_ID" && "${FL_DRY_RUN:-0}" != "1" && "${FL_OP_NONE:-0}" != "1" ]] || return 0
  [[ " ${FL_OP_NOT_FOR} " != *" ${COMMAND:-} "* ]] || return 0
  unset FL_OP_PRESET
  if fl_op_id_ok "$preset" && grep -q '"state":"starting"' "$(fl_ops_dir)/${preset}.json" 2>/dev/null; then
    id="$preset"; FL_OP_BACKGROUND=1
  else
    FL_OP_BACKGROUND=0
    fl_op_new_id_v id || return 0
  fi
  key="${FL_JSON_KEY:-}"
  if [[ -z "$key" ]] && declare -F fl_cmd_key_for >/dev/null; then key="$(fl_cmd_key_for "${COMMAND:-}" "${ARGS[0]:-}" 2>/dev/null || true)"; fi
  FL_OP_COMMAND="${key:-${COMMAND:-}}"
  fl_caller_resolve
  fl_op_context
  fl_op_pid_start_v FL_OP_PID_START "$$"
  # a detached run says "starting" until it holds the lock: its launcher waits for that (fl_op_background)
  FL_OP_STATE="running"
  [[ "$FL_OP_BACKGROUND" != "1" ]] || FL_OP_STATE="starting"
  FL_OP_ID="$id"
  FL_OP_OWNER="$$"
  FL_OP_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # shellcheck disable=SC2089,SC2090  # JSON text with its quotes, put on a line as it is
  FL_OP_JSON=",\"op_id\":\"${id}\""
  FL_OP_ENDED=0
  # shellcheck disable=SC2090
  export FL_OP_ID FL_OP_OWNER FL_OP_STARTED FL_OP_COMMAND FL_OP_JSON FL_OP_BACKGROUND FL_OP_PID_START FL_OP_SITE FL_OP_BENCH
  fl_op_write "$FL_OP_STATE"
}

# fl_op_running: the run holds its lock (the dispatcher calls this after taking it); a detached run leaves
# "starting" here, so a launcher that waits for it knows the run was not refused
fl_op_running() {
  [[ -n "$FL_OP_ID" && "$FL_OP_OWNER" == "$$" && "$FL_OP_STATE" == "starting" ]] || return 0
  FL_OP_STATE="running"
  fl_op_write running
}

# fl_op_note_step ID NAME STATUS: the step that runs now (or just ended); a new step has no progress yet
fl_op_note_step() {
  [[ -n "$FL_OP_ID" ]] || return 0
  FL_OP_STEP_ID="$1"; FL_OP_STEP_NAME="$2"; FL_OP_STEP_STATUS="$3"
  FL_OP_PROG_LABEL=""; FL_OP_PROG_ELAPSED=""; FL_OP_PROG_BYTES=""
  fl_op_write "$FL_OP_STATE"
}

# fl_op_note_progress LABEL ELAPSED [BYTES]: the last progress line
fl_op_note_progress() {
  [[ -n "$FL_OP_ID" ]] || return 0
  FL_OP_PROG_LABEL="$1"; FL_OP_PROG_ELAPSED="${2:-0}"; FL_OP_PROG_BYTES="${3:-}"
  fl_op_write "$FL_OP_STATE"
}

# fl_op_end CODE: the run is over (the exit trap calls this after the done line is out, so a reader
# that saw the done line finds the record finished). Only the process that began the op ends it.
fl_op_end() {
  [[ -n "$FL_OP_ID" && "$FL_OP_OWNER" == "$$" && "$FL_OP_ENDED" != "1" ]] || return 0
  local code="${1:-0}" state="done"
  [[ "$code" == "0" ]] || state=failed
  # a step that was running when the run ended did not end on its own: the run's exit says how
  if [[ "$FL_OP_STEP_STATUS" == "running" ]]; then
    FL_OP_STEP_STATUS="done"
    [[ "$code" == "0" ]] || FL_OP_STEP_STATUS="failed"
  fi
  FL_OP_PROG_LABEL=""
  # the line of the history (history.sh) before the record is finished: a reader that sees the run end finds
  # it. A failing write never changes the run's exit.
  fl_hist_record "$code" || true
  fl_op_write "$state" "$code"
  FL_OP_ENDED=1
}

# ---------------------------------------------------------------- reading

# fl_op_field_v VAR RECORD KEY: one field of a record's text (the keys are unique in it: op_id, state, command,
# bench, site, pid, started_at, updated_at, finished_at, id, name, status, label, elapsed, bytes, exit, log,
# output, background). A string comes back unquoted, null as nothing.
fl_op_field_v() {
  local __re="\"${3}\":(\"(([^\"\\\\]|\\\\.)*)\"|[^,}]*)" __v=""
  if [[ "$2" =~ $__re ]]; then
    if [[ "${BASH_REMATCH[1]:0:1}" == '"' ]]; then __v="${BASH_REMATCH[2]}"; __v="${__v//\\\"/\"}"; __v="${__v//\\\\/\\}"
    else __v="${BASH_REMATCH[1]}"; [[ "$__v" != "null" ]] || __v=""; fi
  fi
  printf -v "$1" '%s' "$__v"
}

# fl_op_read_v VAR OP_ID: the record's text (one line), nothing when there is none
fl_op_read_v() {
  local __line=""
  fl_op_id_ok "$2" && [[ -f "$(fl_ops_dir)/${2}.json" ]] && IFS= read -r __line <"$(fl_ops_dir)/${2}.json" || true
  printf -v "$1" '%s' "$__line"
}

# fl_op_effective_v VAR RECORD: the state to show. A run that says running whose process is gone, or a
# launch that never took over, is interrupted.
fl_op_effective_v() {
  local __s __pid __id __age=0 __ps __now
  fl_op_field_v __s "$2" state
  fl_op_field_v __pid "$2" pid
  case "$__s" in
    running|starting)
      if [[ "$__pid" =~ ^[0-9]+$ ]]; then
        # a run that is gone, or a pid that another process has taken since: the start time of the pid says
        if ! kill -0 "$__pid" 2>/dev/null; then __s=interrupted
        else
          fl_op_field_v __ps "$2" pid_start
          if [[ -n "$__ps" ]]; then
            fl_op_pid_start_v __now "$__pid"
            [[ -z "$__now" || "$__now" == "$__ps" ]] || __s=interrupted
          fi
        fi
      elif [[ "$__s" == "running" ]]; then
        __s=interrupted
      else
        # a launch no process took over yet
        fl_op_field_v __id "$2" op_id
        if declare -F fl__lock_age >/dev/null && [[ -f "$(fl_ops_dir)/${__id}.json" ]]; then __age="$(fl__lock_age "$(fl_ops_dir)/${__id}.json")"; fi
        if [[ "$__age" -gt "$FL_OP_START_GRACE" ]]; then __s=interrupted; fi
      fi ;;
  esac
  printf -v "$1" '%s' "$__s"
}

# fl_op_now_v REC_VAR STATE_VAR OP_ID: the record and the state to show, for a reader. A run finishes its
# record before it exits, so a record that still says running while its pid is gone may be one the run
# finished between the read and the pid check (op wait on a background run said interrupted for a run
# that was done, macOS CI): the record is read once more before the run counts as interrupted.
fl_op_now_v() {
  local __now_rec __now_st
  fl_op_read_v __now_rec "$3"
  fl_op_effective_v __now_st "$__now_rec"
  if [[ "$__now_st" == "interrupted" && -n "$__now_rec" ]]; then
    fl_op_read_v __now_rec "$3"
    fl_op_effective_v __now_st "$__now_rec"
  fi
  printf -v "$1" '%s' "$__now_rec"
  printf -v "$2" '%s' "$__now_st"
}

# fl_op_json_v VAR RECORD [RESULT] [STATE]: the record as the JSON document of op status and op list, with
# the state that is true now; RESULT (the run's done line) is added as "result". STATE is the state the
# caller already has from fl_op_now_v: the document shows that one, not a second look at the pid.
fl_op_json_v() {
  local __rec="$2" __eff="${4:-}" __doc
  [[ -n "$__eff" ]] || fl_op_effective_v __eff "$__rec"
  __doc="$__rec"
  if [[ "$__eff" == "interrupted" ]]; then
    __doc="${__doc/\"state\":\"running\"/\"state\":\"interrupted\"}"
    __doc="${__doc/\"state\":\"starting\"/\"state\":\"interrupted\"}"
  fi
  [[ -z "${3:-}" ]] || __doc="${__doc%\}},\"result\":${3}}"
  printf -v "$1" '%s' "$__doc"
}

# fl_op_result_v VAR OP_ID: the done line of a detached run (the last line of its output file), when there is one
fl_op_result_v() {
  local __f __line=""
  __f="$(fl_ops_dir)/${2}.jsonl"
  if [[ -f "$__f" && "$(wc -c <"$__f" 2>/dev/null | tr -d ' ')" -le 1048576 ]]; then
    __line="$(grep '"event":"done"' "$__f" 2>/dev/null | tail -n 1 || true)"
  fi
  printf -v "$1" '%s' "$__line"
}

# fl_op_ids_v: every op id, newest first. An id is op-DATE-TIME-PID[-N]: the date and the time are fixed width text,
# the N (the run's place within one stamp, see fl_op_new_id_v) and the pid are numbers, compared in that order. Sorted
# as text, pid 9998 came after 10001 and "-5" after "-5-1". One sort for the whole list, no fork per op.
# An id whose stamp is more than FL_OP_CLOCK_SKEW seconds ahead of the clock (a resumed VM, a bad RTC) is not the
# newest run: it goes LAST, so ops[0] is a real run and the prune (it keeps the first FL_KEEP_OPS ids of this list)
# takes it. Several of them follow each other from the nearest stamp to the furthest, the furthest is pruned first.
# These have the newest stamps, so they are the first lines of the sort: the clock's stamp is made once per call
# (one date call) and an id is converted to seconds (fl__op_stamp_secs_v) only while it is text greater than that.
# fl_op_ids_v VAR sets VAR to that list, one id per line; the callers read it from the variable, because a printf
# into a process substitution can fail on macOS with "Interrupted system call" and drop ids (test-ops).
fl_op_ids_v() {
  local __now __nowsecs="" __sec __id __far="" __past=0 __ids=""
  __now="$(date +%Y%m%d-%H%M%S)"
  while IFS= read -r __id; do
    if [[ "$__past" != "1" ]]; then
      if [[ "${__id:3:15}" > "$__now" ]]; then
        [[ -n "$__nowsecs" ]] || fl__op_stamp_secs_v __nowsecs "$__now"
        fl__op_stamp_secs_v __sec "${__id:3:15}"
        if [[ $((__sec - __nowsecs)) -gt "$FL_OP_CLOCK_SKEW" ]]; then __far="${__id}"$'\n'"${__far}"; continue; fi
      fi
      __past=1
    fi
    __ids="${__ids}${__id}"$'\n'
  done < <(fl__op_ids_sorted)
  printf -v "$1" '%s' "${__ids}${__far}"
}

# fl__op_ids_sorted: the op ids, newest stamp first (see fl_op_ids_v)
fl__op_ids_sorted() {
  # shellcheck disable=SC2010  # names this tool made, matched by a strict pattern
  ls -1 "$(fl_ops_dir)" 2>/dev/null | grep -E '^op-[0-9]{8}-[0-9]{6}-[0-9]+(-[0-9]+)?\.json$' | sed 's/\.json$//' \
    | sort -t- -k2,2r -k3,3r -k5,5nr -k4,4nr || true
}

# fl_op_ago_v VAR RECORD: a short "3m 12s" for how long the run has gone (or went), from its own times
fl_op_ago_v() {
  local __s __f __a __b
  fl_op_field_v __s "$2" started_at
  fl_op_field_v __f "$2" finished_at
  [[ -n "$__f" ]] || fl_op_field_v __f "$2" updated_at
  __a="$(fl_op_epoch "$__s")"; __b="$(fl_op_epoch "$__f")"
  if [[ "$__a" =~ ^[0-9]+$ && "$__b" =~ ^[0-9]+$ && "$__b" -ge "$__a" ]]; then printf -v "$1" '%s' "$(fl_fmt_secs $((__b - __a)))"; else printf -v "$1" '%s' "?"; fi
}

# fl_op_epoch TIME: seconds since 1970 of 2026-11-19T10:15:00Z (BSD or GNU date)
fl_op_epoch() {
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || true
}

# ---------------------------------------------------------------- benchbar op

# fl_op_text RECORD [STATE]: an op for a person (STATE as for fl_op_json_v)
fl_op_text() {
  local rec="$1" id state="${2:-}" cmd bench site step sname sstat plabel pel log ex ago out
  fl_op_field_v id "$rec" op_id
  [[ -n "$state" ]] || fl_op_effective_v state "$rec"
  fl_op_field_v cmd "$rec" command; fl_op_field_v bench "$rec" bench; fl_op_field_v site "$rec" site
  fl_op_field_v step "$rec" id; fl_op_field_v sname "$rec" name; fl_op_field_v sstat "$rec" status
  fl_op_field_v plabel "$rec" label; fl_op_field_v pel "$rec" elapsed
  fl_op_field_v log "$rec" log; fl_op_field_v ex "$rec" exit; fl_op_field_v out "$rec" output
  fl_op_ago_v ago "$rec"
  printf '%s  benchbar %s  %s%s\n' "$id" "${cmd:-?}" "$state" "${ex:+ (exit ${ex})}"
  [[ -z "$bench" ]] || printf '  bench     %s\n' "$bench"
  [[ -z "$site" ]] || printf '  site      %s\n' "$site"
  printf '  took      %s\n' "$ago"
  [[ -z "$step" ]] || printf '  step      %s: %s (%s)\n' "$step" "${sname:-$step}" "$sstat"
  [[ -z "$plabel" ]] || printf '  progress  %s (%ss)\n' "$plabel" "${pel:-0}"
  [[ -z "$log" ]] || printf '  log       %s\n' "$log"
  [[ -z "$out" ]] || printf '  output    %s\n' "$out"
}

# fl_op_one OP_ID [wait]: the document or text of one op; dies naming the id when there is none
fl_op_one() {
  local id="$1" rec result="" doc eff
  fl_op_id_ok "$id" || fl_die "Not an op id: ${id}" "An op id looks like op-20261119-101500-4242; benchbar op list shows them."
  fl_op_now_v rec eff "$id"
  [[ -n "$rec" ]] || fl_die "No operation ${id}." "benchbar op list shows the operations this machine remembers (the newest 100)."
  case "$eff" in done|failed|interrupted) fl_op_result_v result "$id" ;; esac
  if [[ "$OPT_JSON" == "1" ]]; then fl_op_json_v doc "$rec" "$result" "$eff"; printf '%s\n' "$doc"; else fl_op_text "$rec" "$eff"; fi
}

# fl_op_list_cmd: the operations, newest first (--limit N, --running)
fl_op_list_cmd() {
  local limit=20 running=0 id ids rec n=0 doc eff docs="" sep="" a rows=() cmd ago step i=0
  local args=("$@")
  while [[ "$i" -lt "${#args[@]}" ]]; do
    a="${args[$i]}"
    case "$a" in
      --limit) i=$((i + 1)); limit="${args[$i]:-}" ;;
      --limit=*) limit="${a#*=}" ;;
      --running) running=1 ;;
      *) fl_die "Unknown option for op list: ${a}" "benchbar op list [--running] [--limit N] [--json]" ;;
    esac
    i=$((i + 1))
  done
  [[ "$limit" =~ ^[0-9]+$ && "$limit" -ge 1 && "$limit" -le 100 ]] || fl_die "--limit takes a number from 1 to 100." "Example: benchbar op list --limit 10"
  rows+=("Op|Command|State|Took|Step")
  fl_op_ids_v ids
  while IFS= read -r id; do
    [[ -n "$id" && "$n" -lt "$limit" ]] || continue
    fl_op_now_v rec eff "$id"
    [[ -n "$rec" ]] || continue
    [[ "$running" != "1" || "$eff" == "running" || "$eff" == "starting" ]] || continue
    n=$((n + 1))
    fl_op_json_v doc "$rec" "" "$eff"
    docs="${docs}${sep}${doc%$'\n'}"; sep=","
    fl_op_field_v cmd "$rec" command; fl_op_ago_v ago "$rec"; fl_op_field_v step "$rec" id
    rows+=("${id}|${cmd:-?}|${eff}|${ago}|${step:--}")
  done <<<"$ids"
  if [[ "$OPT_JSON" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","ops":[%s]}\n' "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$docs"
  elif [[ "$n" == "0" ]]; then
    printf 'No operations.\n'
  else
    fl_table "${rows[@]}"
  fi
}

# fl_op_wait_cmd OP_ID [--timeout SECS]: waits until the op is not running, then prints it. Exit 0 when the
# run exited 0, else 1 (a failed run, an interrupted one, a timeout: the document says which).
fl_op_wait_cmd() {
  local id="" timeout=0 a i=0 rec eff ex start="$SECONDS" timed_out=0 doc result="" poll="${FL_OP_WAIT_POLL:-1}"
  local args=("$@")
  [[ "${FL_TESTING:-}" == "1" ]] || poll=1
  while [[ "$i" -lt "${#args[@]}" ]]; do
    a="${args[$i]}"
    case "$a" in
      --timeout) i=$((i + 1)); timeout="${args[$i]:-}" ;;
      --timeout=*) timeout="${a#*=}" ;;
      -*) fl_die "Unknown option for op wait: ${a}" "benchbar op wait OP_ID [--timeout SECS] [--json]" ;;
      *) [[ -z "$id" ]] || fl_die "op wait takes one op id." "benchbar op wait OP_ID [--timeout SECS]"; id="$a" ;;
    esac
    i=$((i + 1))
  done
  [[ -n "$id" ]] || fl_die "op wait needs an op id." "benchbar op wait OP_ID [--timeout SECS]; benchbar op list shows them."
  [[ "$timeout" =~ ^[0-9]+$ ]] || fl_die "--timeout takes a number of seconds." "Example: benchbar op wait ${id} --timeout 600"
  fl_op_id_ok "$id" || fl_die "Not an op id: ${id}" "An op id looks like op-20261119-101500-4242; benchbar op list shows them."
  while :; do
    fl_op_now_v rec eff "$id"
    [[ -n "$rec" ]] || fl_die "No operation ${id}." "benchbar op list shows the operations this machine remembers (the newest 100)."
    case "$eff" in running|starting) ;; *) break ;; esac
    if [[ "$timeout" -gt 0 && $((SECONDS - start)) -ge "$timeout" ]]; then timed_out=1; break; fi
    sleep "$poll"
  done
  case "$eff" in done|failed|interrupted) fl_op_result_v result "$id" ;; esac
  if [[ "$OPT_JSON" == "1" ]]; then
    fl_op_json_v doc "$rec" "$result" "$eff"
    [[ "$timed_out" != "1" ]] || doc="${doc%\}},\"timed_out\":true}"
    printf '%s\n' "$doc"
  else
    fl_op_text "$rec" "$eff"
    [[ "$timed_out" != "1" ]] || printf 'Still running after %ss; benchbar op wait %s goes on.\n' "$timeout" "$id"
  fi
  [[ "$timed_out" != "1" ]] || return 1
  fl_op_field_v ex "$rec" exit
  [[ "$eff" == "done" && "${ex:-0}" == "0" ]] || return 1
}

# fl_cmd_op status [OP_ID] | list | wait OP_ID
fl_cmd_op() {
  local sub="${1:-}"
  [[ $# -eq 0 ]] || shift
  case "$sub" in
    status)
      if [[ -n "${1:-}" && "${1:0:1}" != "-" ]]; then fl_op_one "$1"
      elif [[ -z "${1:-}" ]]; then fl_op_list_cmd --limit 10
      else fl_die "Unknown option for op status: ${1}" "benchbar op status [OP_ID] [--json]"; fi ;;
    list) fl_op_list_cmd "$@" ;;
    wait) fl_op_wait_cmd "$@" ;;
    "") fl_die "op needs a subcommand: status, list or wait." "benchbar op status [OP_ID]; benchbar op list; benchbar op wait OP_ID" ;;
    *) fl_die "Unknown subcommand: op ${sub}" "benchbar op status [OP_ID]; benchbar op list; benchbar op wait OP_ID" ;;
  esac
}

# ---------------------------------------------------------------- --background

# The commands that may run detached: the ones that take minutes and end in a done line an agent can
# read later. A command that takes seconds (up, down, restart, service, adopt) runs where the caller
# can see it; a command only a person runs (share, lan-guard, labs on, open-as on, listen all,
# mariadb-password, uninstall-service) never does, under an agent or not: the unattended run can ask nothing.
# fl_op_background_ok KEY: whether KEY may run with --background
fl_op_background_ok() {
  case "$1" in install|repair|pull|"app add"|"app update"|"site add"|"site backup"|"site restore"|"site snapshot"|"site rollback") return 0 ;; esac
  return 1
}

# fl_op_launch_wait ID: the launcher looks at the record of the run it started, up to FL_OP_LAUNCH_WAIT seconds
# (5; the tests shorten it), until the run leaves "starting": it holds its lock then. A run that was refused
# (another run holds the lock, a check that the preflight cannot see) is the launcher's refusal, with the run's
# own message and exit code; sets FL_OP_LAUNCH_STATE (starting, running or done) and FL_OP_LAUNCH_PID.
FL_OP_LAUNCH_STATE="starting"
FL_OP_LAUNCH_PID=""
fl_op_launch_wait() {
  local id="$1" rec st="starting" i=0 tries msg hint code line
  tries=$(( ${FL_OP_LAUNCH_WAIT:-5} * 5 ))
  [[ "${FL_TESTING:-}" == "1" ]] || tries=25
  while :; do
    fl_op_now_v rec st "$id"
    [[ "$st" == "starting" && "$i" -lt "$tries" ]] || break
    sleep 0.2
    i=$((i + 1))
  done
  fl_op_field_v FL_OP_LAUNCH_PID "$rec" pid
  case "$st" in
    failed|interrupted)
      fl_op_field_v code "$rec" exit
      [[ "$code" =~ ^[0-9]+$ ]] || code=1
      line=""; fl_op_result_v line "$id"
      msg=""; [[ -z "$line" ]] || fl_op_field_v msg "$line" error
      [[ -n "$msg" ]] || msg="$(grep -m1 -v '^[[:space:]]*$' "$(fl_ops_dir)/${id}.err" 2>/dev/null || true)"
      [[ -n "$msg" ]] || msg="The detached run ended without a result."
      hint="$(sed -n 's/^Aborting\. //p' "$(fl_ops_dir)/${id}.err" 2>/dev/null | tail -n 1)"
      fl_die "$msg" "${hint:-See benchbar op status ${id} and its log.} Nothing was started; the attempt is recorded as ${id}." "$code" ;;
    done|running) FL_OP_LAUNCH_STATE="$st" ;;
    *) FL_OP_LAUNCH_STATE="starting" ;;
  esac
}

# fl_op_background ARGS...: starts this command again, detached, with its stream in ops/OP_ID.jsonl, and
# prints the op_id; the caller exits. Everything that can be refused is refused here, before the start
# (a missing input, a dry run, a command that may not run detached), so a refusal is the answer and not an op.
fl_op_background() {
  local key id args=() a dir out err pw_sudo=0 doc
  key="$(fl_cmd_key_for "$COMMAND" "${ARGS[0]:-}" 2>/dev/null || true)"
  fl_op_background_ok "$key" || fl_die "benchbar ${key:-$COMMAND} cannot run with --background." \
    "--background is for install, repair, pull, app add, app update, site add, site backup, site restore, site snapshot and site rollback. A command that takes seconds runs in front; one only a person runs never runs unattended."
  [[ "$FL_DRY_RUN" != "1" ]] || fl_die "--background starts a change; a dry run prints its plan at once." "Run the plan without --background, then apply it with --background."
  [[ -z "${FL_SUDO_PW:-}" && "${FL_SUDO_PW_NEWLINE:-0}" != "1" ]] || fl_die "--background cannot carry BENCHBAR_SUDO_PASSWORD: a detached run has no pipe to read it from." \
    "Run the command in front, or cache the sudo credential first so that sudo -n works."
  # --secrets-stdin is put back below (the secrets were read from this run's stdin and go to the new one on a pipe)
  for a in "$@"; do [[ "$a" == "--background" || "$a" == "--secrets-stdin" ]] || args+=("$a"); done
  args+=(--jsonl)
  # the detached run says who started it: the launcher's answer, not its own (it has no terminal)
  fl_caller_resolve
  fl_op_new_id_v id || fl_die "Could not make the operations folder $(fl_ops_dir)." "Check that the state folder ${FL_STATE_DIR} is writable."
  dir="$(fl_ops_dir)"; out="${dir}/${id}.jsonl"; err="${dir}/${id}.err"
  # the launcher writes the first record ("starting"); the detached run takes it over
  FL_OP_ID="$id"; FL_OP_OWNER=""; FL_OP_COMMAND="$key"; FL_OP_BACKGROUND=1
  FL_OP_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  FL_LOG_FILE=""
  fl_op_context
  fl_op_write starting
  FL_OP_ID=""; FL_OP_BACKGROUND=0
  # the detached run starts without this run's stream (its flags, and fd 3, the caller's stdout); a refusal after the start
  # (fl_op_launch_wait) opens it again
  fl_background_stream_release
  (
    export FL_OP_PRESET="$id" BENCHBAR_NONINTERACTIVE=1
    if [[ "$OPT_SECRETS_STDIN" == "1" ]]; then
      # --secrets-stdin: the detached run reads them from a pipe (its stdin), as this run did; they are
      # not exported, so the detached process has no password in its environment either
      if command -v setsid >/dev/null 2>&1; then
        setsid "$BASH" "${SCRIPT_DIR}/benchbar" "${args[@]}" --secrets-stdin >"$out" 2>"$err" < <(fl__secrets_emit) &
      else
        set -m
        nohup "$BASH" "${SCRIPT_DIR}/benchbar" "${args[@]}" --secrets-stdin >"$out" 2>"$err" < <(fl__secrets_emit) &
      fi
    else
      [[ -z "${ADMIN_PASSWORD:-}" ]] || export ADMIN_PASSWORD
      [[ -z "${MARIADB_ROOT_PASSWORD:-}" ]] || export MARIADB_ROOT_PASSWORD
      if command -v setsid >/dev/null 2>&1; then
        setsid "$BASH" "${SCRIPT_DIR}/benchbar" "${args[@]}" >"$out" 2>"$err" </dev/null &
      else
        set -m
        nohup "$BASH" "${SCRIPT_DIR}/benchbar" "${args[@]}" >"$out" 2>"$err" </dev/null &
      fi
    fi
  ) 2>/dev/null
  fl_background_stream_open
  fl_op_launch_wait "$id"
  # accepted: the line below is the result, and the detached run's stream is its own
  fl_background_stream_release
  if [[ "$OPT_JSON" == "1" ]]; then
    fl_next_action "$(fl_fix_cmd benchbar op wait "$id")" "Wait for it to end (add --timeout SECS to give up waiting; --json for the result)"
    fl_next_action "$(fl_fix_cmd benchbar op status "$id" --json)" "Where it is now: the step, the last progress line, the exit"
    fl_json_str_v doc "$key"
    printf '{"schema_version":%d,"cli_version":"%s","op_id":"%s","command":%s,"state":"%s","pid":%s,"background":true,"output":%s,"exit":0,"next_actions":[%s]}\n' \
      "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$id" "$doc" "$FL_OP_LAUNCH_STATE" "${FL_OP_LAUNCH_PID:-null}" "$(fl_json_str "$out")" "$FL_DONE_NEXT"
  else
    printf 'Started in the background (%s): %s (benchbar %s)\n' "$FL_OP_LAUNCH_STATE" "$id" "$key"
    printf '  benchbar op status %s    where it is now\n' "$id"
    printf '  benchbar op wait %s      wait for it to end\n' "$id"
  fi
  exit 0
}

# fl_op_prune: the records of the oldest runs go, beyond FL_KEEP_OPS (100), with their output files; a
# record of a run that still runs stays. Prints how many records went. A temp file of a killed writer
# (older than a day) goes too.
fl_op_prune() {
  local keep n=0 gone=0 id ids rec eff dir f
  keep="${FL_KEEP_OPS:-100}"; [[ "$keep" =~ ^[0-9]+$ && "$keep" -ge 1 ]] || keep=100
  dir="$(fl_ops_dir)"
  [[ -d "$dir" ]] || { printf 0; return 0; }
  fl_op_ids_v ids
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    n=$((n + 1))
    [[ "$n" -gt "$keep" && "$id" != "${FL_OP_ID:-}" ]] || continue
    fl_op_now_v rec eff "$id"
    if [[ -n "$rec" ]]; then
      [[ "$eff" != "running" && "$eff" != "starting" ]] || continue
    fi
    for f in "${dir}/${id}.json" "${dir}/${id}.jsonl" "${dir}/${id}.err"; do
      [[ ! -L "$f" ]] || continue
      rm -f "$f" 2>/dev/null || true
    done
    gone=$((gone + 1))
  done <<<"$ids"
  find "$dir" -maxdepth 1 -type f -name '.op-*.tmp' -mmin +1440 -exec rm -f {} + 2>/dev/null || true
  printf '%s' "$gone"
}

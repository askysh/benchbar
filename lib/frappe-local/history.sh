#!/usr/bin/env bash
#
# history.sh: what ran on this machine, and who started it (docs/json-schema.md, "Action history").
#
# Every run that changes things (an operation, ops.sh) appends one compact line to
# <state folder>/history.jsonl when it ends: the op_id, the command line (secrets as ***), who started
# it (BENCHBAR_CALLER), the bench and site, the times, the exit, what it changed and its log. The
# file is rotated at 1 MB with three old files kept, like the MCP audit log (mcp-calls.jsonl), so it
# outlives the newest 100 operation records. `benchbar history` reads it, newest first.
#
# A run that was killed (SIGKILL, power) writes no line: `benchbar op list` shows it as interrupted.
# BENCHBAR_CALLER is a label the caller sets, not a proof: any process of the user can set it.
#
# Compatible with macOS /bin/bash 3.2.

# never read from the environment: only fl_caller_resolve sets it, from BENCHBAR_CALLER checked against the list
# (an exported FL_CALLER would let any process choose what the history and the log say)
FL_CALLER=""
# who may be named: a person at a terminal, the Mac app, the tray, an agent through MCP, an agent
# that asked for --for-agent, a script (cron, CI, another program)
FL_CALLERS="terminal app tray mcp agent script"
FL_HISTORY_FILE="history.jsonl"
FL_HISTORY_OLD=3
# how many entries of changed[] a line keeps, and how many words of the command line
FL_HIST_CHANGED_MAX=20
FL_HIST_WORDS_MAX=40
# a word of the command line is cut here
FL_HIST_SECRET_WORD_MAX=200

# fl_hist_secret_name_p NAME [param]: whether NAME (a flag or a key) looks like it holds a secret, case ignored.
# The words are the MCP audit log's (mcp.py, SECRET_KEY); a flag may also be --apply (a plan's token), and a
# query parameter or KEY=VALUE name also "sig" (SECRET_PARAM there).
fl_hist_secret_name_p() {
  local nc=0 rc=1
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  case "$1" in
    *pass*|*secret*|*token*|*key*|*credential*|*auth*|*cookie*|*session*|--apply) rc=0 ;;
    *sig*) [[ -z "${2:-}" ]] || rc=0 ;;
  esac
  [[ "$nc" == "1" ]] || shopt -u nocasematch
  return "$rc"
}

# fl_caller_resolve: who started this run, into FL_CALLER and BENCHBAR_CALLER_KIND (exported, so the phase
# scripts and a detached run say the same). BENCHBAR_CALLER itself is never changed: a lease names its
# holder by it (lease.sh), so it may be a longer name of the agent's own. The kind is the value of
# BENCHBAR_CALLER when it is one of FL_CALLERS, or its part before the first ":" when that is (the MCP
# server's holder mcp:CLIENT:PID is mcp), else BENCHBAR_CALLER_KIND when a parent run set one of the list;
# a longer text is never copied anywhere. Without one, --for-agent says agent, a terminal on stdin says
# terminal, anything else is a script.
fl_caller_resolve() {
  local c="${BENCHBAR_CALLER:-}" k="${BENCHBAR_CALLER_KIND:-}" w ok=""
  [[ -z "${FL_CALLER:-}" ]] || return 0
  # exact equality with one word of the list: a text that only contains an allowed word ("app tray") is no caller
  for w in $FL_CALLERS; do
    if [[ "$c" == "$w" || "${c%%:*}" == "$w" && "$c" == *:* ]]; then ok="$w"; fi
  done
  if [[ -z "$ok" ]]; then
    for w in $FL_CALLERS; do [[ "$k" != "$w" ]] || ok="$w"; done
  fi
  c="$ok"
  if [[ -z "$c" ]]; then
    if [[ "${OPT_FOR_AGENT:-0}" == "1" ]]; then c=agent
    elif [[ -t 0 ]]; then c=terminal
    else c=script; fi
  fi
  FL_CALLER="$c"
  BENCHBAR_CALLER_KIND="$c"
  export BENCHBAR_CALLER_KIND
}

# fl_hist_word_v VAR WORD PREV_SECRET: one word of the command line as the history keeps it. The credentials
# of a URL, the value of a secret looking KEY=VALUE or ?query=value, and the word after a flag that looks
# like it holds a secret are ***; a long word is cut. Sets FL_HIST_NEXT_SECRET=1 when the next word is the
# value of a secret flag.
FL_HIST_NEXT_SECRET=0
fl_hist_word_v() {
  local __word="$2" __name __rest __q __base __p __out __sep
  FL_HIST_NEXT_SECRET=0
  # the word after a secret looking flag is its value, unless it is a flag itself (--keep-secrets --yes)
  if [[ "${3:-0}" == "1" && "$__word" != -* ]]; then printf -v "$1" '%s' '***'; return 0; fi
  if [[ "$__word" == -* ]]; then
    if [[ "$__word" == *=* ]]; then
      __name="${__word%%=*}"
      if fl_hist_secret_name_p "$__name"; then __word="${__name}=***"; fi
    elif fl_hist_secret_name_p "$__word"; then
      FL_HIST_NEXT_SECRET=1
    fi
  else
    case "$__word" in *://*@*) fl_redact_url_v __word "$__word" ;; esac
    if [[ "$__word" == *'?'*=* || "$__word" == *'&'*=* ]]; then
      # the query of a URL (or a word shaped like one): every secret looking parameter
      __base="${__word%%\?*}"; __q="${__word#*\?}"
      [[ "$__word" == *'?'* ]] || { __base=""; __q="$__word"; }
      __out=""; __sep=""
      while [[ -n "$__q" ]]; do
        if [[ "$__q" == *'&'* ]]; then __p="${__q%%&*}"; __q="${__q#*&}"; else __p="$__q"; __q=""; fi
        if [[ "$__p" == *=* ]] && fl_hist_secret_name_p "${__p%%=*}" param; then __p="${__p%%=*}=***"; fi
        __out="${__out}${__sep}${__p}"; __sep="&"
      done
      if [[ "$__word" == *'?'* ]]; then __word="${__base}?${__out}"; else __word="$__out"; fi
    elif [[ "$__word" == *=* ]]; then
      __name="${__word%%=*}"
      if fl_hist_secret_name_p "$__name" param; then __word="${__name}=***"; fi
    fi
  fi
  [[ "${#__word}" -le "$FL_HIST_SECRET_WORD_MAX" ]] || __word="${__word:0:$FL_HIST_SECRET_WORD_MAX}... [cut]"
  printf -v "$1" '%s' "$__word"
}

# fl_hist_words: the command line of this run, secrets as ***, into the array FL_HIST_WORDS (at most
# FL_HIST_WORDS_MAX words, then a word "...")
FL_HIST_WORDS=()
fl_hist_words() {
  local __args=() __w __n=0 __prev=0 __last
  FL_HIST_WORDS=()
  __args=(${FL_ORIG_ARGS[@]+"${FL_ORIG_ARGS[@]}"})
  # a detached run was started again by its launcher with --jsonl added at the end
  __last=$((${#__args[@]} - 1))
  if [[ "${FL_OP_BACKGROUND:-0}" == "1" && "$__last" -ge 0 && "${__args[$__last]}" == "--jsonl" ]]; then unset "__args[$__last]"; fi
  for __w in ${__args[@]+"${__args[@]}"}; do
    if [[ "$__n" -ge "$FL_HIST_WORDS_MAX" ]]; then FL_HIST_WORDS+=("..."); break; fi
    __n=$((__n + 1))
    fl_hist_word_v __w "$__w" "$__prev"
    __prev="$FL_HIST_NEXT_SECRET"
    FL_HIST_WORDS+=("$__w")
  done
}

# fl_hist_argv_json_v VAR: the command line as a JSON array of words
fl_hist_argv_json_v() {
  local __w __out="" __sep=""
  fl_hist_words
  for __w in ${FL_HIST_WORDS[@]+"${FL_HIST_WORDS[@]}"}; do __out="${__out}${__sep}$(fl_json_str "$__w")"; __sep=","; done
  printf -v "$1" '[%s]' "$__out"
}

# fl_hist_valid_tool TEXT / fl_hist_valid_client TEXT: what an MCP server may name (the tool is one of
# its own, the client is what the client called itself in initialize; a text outside these is dropped)
fl_hist_valid_tool() { [[ "${1:-}" =~ ^benchbar_[a-z0-9_]{1,60}$ ]]; }
fl_hist_valid_client() { [[ "${1:-}" =~ ^[A-Za-z0-9._\ +/@-]{1,80}$ ]]; }

# fl_hist_mcp_json_v VAR: {"tool","client"} when an MCP server started this run (mcp.py passes both), else null
fl_hist_mcp_json_v() {
  local __t="null" __c="null" __doc="null"
  if [[ "${FL_CALLER:-}" == "mcp" ]]; then
    fl_hist_valid_tool "${BENCHBAR_MCP_TOOL:-}" && fl_json_str_v __t "$BENCHBAR_MCP_TOOL"
    fl_hist_valid_client "${BENCHBAR_MCP_CLIENT:-}" && fl_json_str_v __c "$BENCHBAR_MCP_CLIENT"
    if [[ "$__t" != "null" || "$__c" != "null" ]]; then __doc="{\"tool\":${__t},\"client\":${__c}}"; fi
  fi
  printf -v "$1" '%s' "$__doc"
}

# fl_hist_changed_v VAR_LIST VAR_MORE: what the run changed, as the history keeps it: kind and name of the
# first FL_HIST_CHANGED_MAX entries of changed[] (the detail stays in the run's log), and how many more there were
fl_hist_changed_v() {
  local __rest __item __out="" __sep="" __n=0 __more=0 __mk='},{"kind":' __k __nm
  declare -F fl_changed_fold >/dev/null && fl_changed_fold
  __rest="${FL_DONE_CHANGED:-}"
  local __kre='^\{"kind":"([^"]*)","name":("([^"\\]|\\.)*")'
  while [[ -n "$__rest" ]]; do
    if [[ "$__rest" == *"$__mk"* ]]; then __item="${__rest%%"$__mk"*}}"; __rest="{\"kind\":${__rest#*"$__mk"}"; else __item="$__rest"; __rest=""; fi
    if [[ "$__n" -ge "$FL_HIST_CHANGED_MAX" ]]; then __more=$((__more + 1)); continue; fi
    if [[ "$__item" =~ $__kre ]]; then
      __k="${BASH_REMATCH[1]}"; __nm="${BASH_REMATCH[2]}"
      [[ "${#__nm}" -le 300 ]] || __nm="\"...\""
      __out="${__out}${__sep}{\"kind\":\"${__k}\",\"name\":${__nm}}"; __sep=","
      __n=$((__n + 1))
    fi
  done
  printf -v "$1" '[%s]' "$__out"
  printf -v "$2" '%s' "$__more"
}

# fl_hist_append LINE: the line into history.jsonl (0600), under the file's own lock (history.jsonl.lck, state.sh:
# two runs that end together never rotate at once and never lose a line to a rotation). Past FL_HISTORY_MAX bytes
# (1 MB) the file moves to .old.1 (.old.2 and .old.3 shift up, the oldest goes). A file that cannot be written, or a
# lock that cannot be taken, never fails a run: the work is in a subshell, so a refusal of the lock ends only that.
fl_hist_append() {
  local line="$1" f
  f="${FL_STATE_DIR}/${FL_HISTORY_FILE}"
  [[ ! -L "$f" ]] || return 0
  (
    declare -F fl__kv_lock >/dev/null && fl__kv_lock "$f"
    local max n size
    max="${FL_HISTORY_MAX:-1000000}"; [[ "$max" =~ ^[0-9]+$ && "$max" -ge 1 ]] || max=1000000
    size="$({ wc -c <"$f"; } 2>/dev/null | tr -d ' ')"
    if [[ "$size" =~ ^[0-9]+$ && "$size" -ge "$max" ]]; then
      n="$FL_HISTORY_OLD"
      while [[ "$n" -gt 1 ]]; do
        [[ ! -f "${f}.old.$((n - 1))" ]] || mv -f "${f}.old.$((n - 1))" "${f}.old.${n}" 2>/dev/null || true
        n=$((n - 1))
      done
      mv -f "$f" "${f}.old.1" 2>/dev/null || true
    fi
    umask 077
    printf '%s
' "$line" >>"$f"
    declare -F fl__kv_unlock >/dev/null && fl__kv_unlock "$f"
  ) 2>/dev/null || true
}

# fl_hist_record CODE: the run is over; its line into the history. Called by fl_op_end, so only the process
# that began the op writes it, once, and a dry run, a read and a refusal before the log have none.
fl_hist_record() {
  local code="${1:-0}" argv changed more mcp f_bench f_site f_log f_cmd now line
  [[ -n "${FL_OP_ID:-}" ]] || return 0
  fl_caller_resolve
  fl_hist_argv_json_v argv
  fl_hist_changed_v changed more
  fl_hist_mcp_json_v mcp
  fl__op_str_v f_bench "${FL_BENCH_DIR:-${FL_OP_BENCH:-}}"
  fl__op_str_v f_site "${FL_OP_SITE:-${FL_SITE:-}}"
  fl__op_str_v f_log "${FL_LOG_FILE:-}"
  fl__op_str_v f_cmd "${FL_OP_COMMAND:-}"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf -v line '{"op_id":"%s","command":%s,"argv":%s,"caller":"%s","mcp":%s,"bench":%s,"site":%s,"started_at":"%s","ended_at":"%s","exit":%s,"changed":%s,"changed_more":%s,"cli_version":"%s","log":%s}' \
    "$FL_OP_ID" "$f_cmd" "$argv" "${FL_CALLER:-script}" "$mcp" "$f_bench" "$f_site" \
    "${FL_OP_STARTED:-$now}" "$now" "$code" "$changed" "$more" "${FL_VERSION:-0}" "$f_log"
  fl_hist_append "$line"
}

# ---------------------------------------------------------------- reading

# fl_hist_files: the history files, newest first
fl_hist_files() {
  local f="${FL_STATE_DIR}/${FL_HISTORY_FILE}" n=1
  [[ ! -f "$f" || -L "$f" ]] || printf '%s\n' "$f"
  while [[ "$n" -le "$FL_HISTORY_OLD" ]]; do
    [[ ! -f "${f}.old.${n}" || -L "${f}.old.${n}" ]] || printf '%s\n' "${f}.old.${n}"
    n=$((n + 1))
  done
}

# fl_hist_iso_v VAR EPOCH: 2026-11-19T10:15:00Z of seconds since 1970 (GNU or BSD date)
fl_hist_iso_v() {
  local __s=""
  if date --version >/dev/null 2>&1; then __s="$(date -u -d "@$2" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  else __s="$(date -u -r "$2" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"; fi
  printf -v "$1" '%s' "$__s"
}

# fl_hist_since_v VAR TEXT: --since as an ISO time in UTC (ISO times of one length compare as text): 90m, 12h, 7d or
# 2w ago; a date (2026-11-19, from midnight UTC); or a time (2026-11-19T10:15:00Z)
fl_hist_since_v() {
  local __t="$2" __n __u __secs __now __iso=""
  if [[ "$__t" =~ ^([0-9]+)([mhdw])$ ]]; then
    __n="${BASH_REMATCH[1]}"; __u="${BASH_REMATCH[2]}"
    case "$__u" in m) __secs=60 ;; h) __secs=3600 ;; d) __secs=86400 ;; w) __secs=604800 ;; esac
    __now="$(date +%s)"
    fl_hist_iso_v __iso "$((__now - __n * __secs))"
  elif [[ "$__t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then __iso="${__t}T00:00:00Z"
  elif [[ "$__t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z$ ]]; then
    __iso="$__t"; [[ "${#__iso}" -eq 20 ]] || __iso="${__iso%Z}:00Z"
  fi
  [[ -n "$__iso" ]] || return 1
  printf -v "$1" '%s' "$__iso"
}

# fl_hist_line_ok LINE: a line this tool wrote (a half line of a killed writer is skipped)
fl_hist_line_ok() { [[ "$1" == '{"op_id":"op-'*'}' ]]; }

# fl_hist_text LINES...: the history for a person
fl_hist_text() {
  local line id cmd who started ex bench tool client words w rows=()
  rows+=("Started|Who|Command|Exit|Bench")
  for line in "$@"; do
    fl_op_field_v id "$line" op_id
    fl_op_field_v who "$line" caller
    fl_op_field_v started "$line" started_at
    fl_op_field_v ex "$line" exit
    fl_op_field_v bench "$line" bench
    fl_op_field_v cmd "$line" command
    fl_op_field_v tool "$line" tool
    fl_op_field_v client "$line" client
    [[ -z "$tool" ]] || who="${who} (${tool}${client:+, ${client}})"
    started="${started/T/ }"; started="${started%:??Z}Z"
    rows+=("${started}|${who:-?}|benchbar ${cmd:-?}|${ex:-?}|${bench:-"-"}")
  done
  fl_table "${rows[@]}"
}

# fl_cmd_history [--bench PATH] [--since TIME] [--limit N] [--json]: the runs that changed things, newest first
fl_cmd_history() {
  local limit=20 since="" bench="${OPT_BENCH_DIR:-}" a i=0 args=("$@") f line n=0 docs="" sep="" b started
  local bench_a="" bench_b="" lines=()
  while [[ "$i" -lt "${#args[@]}" ]]; do
    a="${args[$i]}"
    case "$a" in
      --limit) i=$((i + 1)); limit="${args[$i]:-}" ;;
      --limit=*) limit="${a#*=}" ;;
      --since) i=$((i + 1)); since="${args[$i]:-}" ;;
      --since=*) since="${a#*=}" ;;
      --bench) i=$((i + 1)); bench="${args[$i]:-}" ;;
      --bench=*) bench="${a#*=}" ;;
      *) fl_die "Unknown option for history: ${a}" "benchbar history [--bench PATH] [--since TIME] [--limit N] [--json]" ;;
    esac
    i=$((i + 1))
  done
  [[ "$limit" =~ ^[0-9]+$ && "$limit" -ge 1 && "$limit" -le 1000 ]] || fl_die "--limit takes a number from 1 to 1000." "Example: benchbar history --limit 50"
  if [[ -n "$since" ]]; then
    fl_hist_since_v since "$since" || fl_die "--since takes a time like 90m, 12h, 7d, 2w, 2026-11-19 or 2026-11-19T10:15:00Z." "Example: benchbar history --since 7d"
  fi
  if [[ -n "$bench" ]]; then
    bench_a="${bench%/}"; [[ -n "$bench_a" ]] || bench_a="/"
    bench_b="$(cd "$bench" 2>/dev/null && pwd -P || true)"
  fi
  # newest first: each file from its last line up, the current file before the .old ones
  while IFS= read -r f; do
    [[ -n "$f" && "$n" -lt "$limit" ]] || continue
    while IFS= read -r line; do
      fl_hist_line_ok "$line" || continue
      if [[ -n "$since" ]]; then
        fl_op_field_v started "$line" started_at
        [[ ! "$started" < "$since" ]] || continue
      fi
      if [[ -n "$bench" ]]; then
        fl_op_field_v b "$line" bench
        [[ -n "$b" && ( "$b" == "$bench_a" || ( -n "$bench_b" && "$b" == "$bench_b" ) ) ]] || continue
      fi
      lines+=("$line")
      n=$((n + 1))
      [[ "$n" -lt "$limit" ]] || break
    done < <( { tac "$f" 2>/dev/null || tail -r "$f" 2>/dev/null; } || true )
  done < <(fl_hist_files)
  if [[ "$OPT_JSON" == "1" ]]; then
    for line in ${lines[@]+"${lines[@]}"}; do docs="${docs}${sep}${line}"; sep=","; done
    printf '{"schema_version":%d,"cli_version":"%s","history":[%s]}\n' "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$docs"
  elif [[ "$n" == "0" ]]; then
    printf 'No runs recorded yet.\n'
  else
    fl_hist_text "${lines[@]}"
  fi
}

#!/usr/bin/env bash
#
# stream.sh: the JSON stream of the entry point (docs/json-schema.md): the state of the
# --json and --jsonl runs, how a stream starts (fl_jsonl_start, fl_jsonl_begin_generic) and the
# done line, which the exit trap sends however the run ends (fl_jsonl_on_exit,
# fl_jsonl_done_generic, fl_repair_done). The line writers themselves (fl_jsonl, fl_jsonl_step,
# fl_jsonl_progress) are in ui.sh. Moved out of the entry point as it was (CORE-18, issue 151).
# Every start loads this file, a lean one too: the exit trap (fl_cleanup) calls the done writers.

# ---------------------------------------------------------------- install --json and adopt --json
#
# The stream (docs/json-schema.md): one JSON object per line on fd 3, the
# command's real stdout; every human line goes to the run's log. It starts
# before the lock and the log are taken (fl_jsonl_start) so that even a
# refusal or a busy lock ends in a done line, which fl_cleanup always sends.

FL_JSONL_DONE=0
FL_JSONL_PLAN_SENT=0
# own: install and adopt (their done line has fields of its own); generic: the
# other commands, whose done line is the shared one (fl_jsonl_done_generic)
FL_JSONL_KIND=""
FL_JSONL_BENCH=""
FL_JSONL_SITE=""
FL_JSONL_URL=""

# fl_jsonl_start: install or adopt with --json. Without --yes (and without
# --dry-run) nothing can answer a question: one done line, exit 1, nothing
# written, no lock. Else the log, the saved stdout, the plain UI, stdin closed.
fl_jsonl_start() {
  FL_JSONL=1; FL_JSONL_VERSION="$FL_VERSION"; FL_JSONL_KIND=own
  export FL_JSONL FL_JSONL_VERSION
  exec 3>&1 1>&2
  # a lease on what the run changes: a done line with exit 1 and the holder, before anything else (lease.sh)
  fl_lease_gate
  # the inputs a non interactive run lacks: a done line with exit 1, before the log and the lock
  fl_noninteractive_preflight
  if [[ "$FL_ASSUME_YES" != "1" && "$FL_DRY_RUN" != "1" ]]; then
    FL_JSONL_BENCH="$OPT_BENCH_DIR"; FL_JSONL_SITE="$OPT_SITE"
    [[ "$COMMAND" != "adopt" || -n "$FL_JSONL_BENCH" ]] || FL_JSONL_BENCH="${ARGS[0]:-}"
    FL_DIE_MESSAGE="benchbar ${COMMAND} --json needs --yes (or --dry-run): no question can be answered on the stream"
    exit 1
  fi
  # a dry run has a log here too: the human plan goes there
  # (the log of a dry run is no operation: nothing changes)
  FL_OP_NONE="$FL_DRY_RUN"; export FL_OP_NONE
  FL_DRY_RUN=0 fl_log_init "${FL_STATE_DIR}/logs"
  unset FL_OP_NONE
  exec 1>>"${FL_LOG_FILE:-/dev/null}" 2>&1 0</dev/null
  FL_PLAIN=1; fl_ui_init
  # a dry run streams the plan and done only: the plan line turns the rest
  # off (FL_JSONL_QUIET), the phase scripts it runs inherit that
}

# fl_jsonl_begin_generic: the stream of the commands that changed no JSON
# before (up, down, restart, service, site add, app update, ports apply, and
# the document commands under --jsonl). fd 3 is the real stdout; the text
# goes to stderr (and the log, which fl_log_init opens in the dispatcher);
# stdin is closed, so nothing waits for an answer. A dry run streams the plan
# and the done line only.
fl_jsonl_begin_generic() {
  FL_JSONL=1; FL_JSONL_VERSION="$FL_VERSION"; FL_JSONL_KIND=generic
  export FL_JSONL FL_JSONL_VERSION
  exec 3>&1 1>&2 0</dev/null
  FL_PLAIN=1; fl_ui_init
  # a dry run streams the plan and the done line only. These commands send a
  # plan of their own (once they know it); for the others the plan is the command.
  if [[ "$FL_DRY_RUN" == "1" ]]; then
    case "$FL_JSON_KEY" in
      service|"site add"|"site backup"|"site drop"|"site restore"|"app update"|"app install"|"lock apply"|"app add"|"share setup"|"share start"|run) ;;
      *)
        fl_bench_detect "$OPT_BENCH_DIR"
        fl_jsonl plan ",\"command\":$(fl_json_str "$FL_JSON_KEY"),\"bench\":$(fl_json_str "$FL_BENCH_DIR"),\"dry_run\":true"
        FL_JSONL_PLAN_SENT=1; FL_JSONL_QUIET=1; export FL_JSONL_QUIET ;;
    esac
  fi
}

# fl_jsonl_done_generic CODE: the done line of a generic stream: the
# command's document when it had one, the shared done fields (docs/json-schema.md,
# "Rules for readers") and the log
fl_jsonl_done_generic() {
  local code="$1" f rest="" extra=""
  FL_JSONL_DONE=1
  FL_JSONL_QUIET=0
  if [[ "$code" != "0" ]]; then
    FL_DIE_MESSAGE="${FL_DIE_MESSAGE:-$(fl_log_step_message 0)}"
    extra=",\"error\":$(fl_json_str "${FL_DIE_MESSAGE:-the command failed; see the log}")"
    [[ "$code" != "2" || "${FL_EXIT2_NOT_PASSWORD:-0}" == "1" ]] || fl_next_action "Ask the person for the MariaDB root password (do not look for it); they run the command again with MARIADB_ROOT_PASSWORD='...' in the environment" "The MariaDB root password is unknown"
  fi
  fl_done_fields_v f "$code"
  if [[ -n "$FL_DOC" ]]; then rest="$(fl_doc_rest "$FL_DOC"),"; else
    rest="\"bench\":$(fl_json_str "${FL_BENCH_DIR:-}"),"
    [[ "${FL_DONE_NO_BENCH:-0}" != "1" ]] || rest="\"bench\":null,"
  fi
  # a dry run says so, also when the command's document does not
  if [[ "$FL_DRY_RUN" == "1" ]]; then
    case "$rest" in *'"dry_run":'*) ;; *) extra="${extra},\"dry_run\":true" ;; esac
  fi
  fl_jsonl "done" ",${rest}${f},\"log\":$(fl_json_str "${FL_LOG_FILE:-}")${extra}"
}

# fl_jsonl_on_exit CODE: the done line, once, however the run ends
fl_jsonl_on_exit() {
  [[ "$FL_JSONL" == "1" && "$FL_JSONL_DONE" != "1" ]] || return 0
  local code="${1:-0}" url="null" fix="null" extra="" f
  if [[ "$FL_JSONL_KIND" == "generic" ]]; then fl_jsonl_done_generic "$code"; return 0; fi
  FL_JSONL_DONE=1
  FL_JSONL_QUIET=0
  [[ "$code" != "0" || -z "$FL_JSONL_URL" ]] || url="$(fl_json_str "$FL_JSONL_URL")"
  FL_DIE_MESSAGE="${FL_DIE_MESSAGE:-$(fl_log_step_message 0)}"
  [[ "$code" != "2" ]] || fix="$(fl_json_str "The MariaDB root password is unknown: ask the person for it (do not look for it), then run the command again with MARIADB_ROOT_PASSWORD='...' in the environment")"
  # a failure with a stable id and a fix of its own (a port that is taken)
  if [[ "$code" != "0" && -n "$FL_ERROR_FIX" ]]; then
    fix="$(fl_json_str "$FL_ERROR_FIX")"
    extra=",\"error\":$(fl_json_str "${FL_DIE_MESSAGE:-}")"
  fi
  if [[ "$FL_JSONL_PLAN_SENT" != "1" && "$code" != "0" ]]; then
    extra=",\"error\":$(fl_json_str "${FL_DIE_MESSAGE:-the command stopped before it started; see the log}")"
  fi
  [[ "${FL_DRY_RUN:-0}" != "1" ]] || extra="${extra},\"dry_run\":true"
  fl_done_fields_v f
  fl_jsonl "done" ",\"exit\":${code},\"bench\":$(fl_json_str "${FL_JSONL_BENCH:-${FL_BENCH_DIR:-}}"),\"site\":$(fl_json_str "${FL_JSONL_SITE:-${FL_SITE:-}}"),\"url\":${url},\"skipped\":[${FL_JSONL_SKIPPED}],\"fix\":${fix},\"log\":$(fl_json_str "${FL_LOG_FILE:-}")${extra},${f}"
}

# fl_own_stream_open: the streams of repair and pull are their own, and their command opens them (cmd_repair,
# fl_cmd_pull), after the lab gate, the lease gate, the preflight and the bench guess gate, and after the log and the
# lock. A refusal of any of those would have no stream to end, so the dispatch opens it here, before the first of them, as
# far as the done line needs it: fd 3 is the real stdout and the command's own done writer (fl_repair_done,
# fl_pull_on_exit) is armed; the exit trap sends the line, with the next actions the gate collected. Nothing is printed
# here, and the command's own open, later, sets the same state again. The text of a refusal stays on stderr (fl_die moves
# stdout there under --json). Any other command, and a run without JSON, is left as it is (#405).
fl_own_stream_open() {
  [[ "${OPT_JSON:-0}" == "1" ]] || return 0
  # shellcheck disable=SC2034  # FL_PULL_ACTIVE is read by fl_pull_on_exit (pull.sh), which the exit trap calls
  case "$COMMAND" in
    repair) FL_JSON_EVENTS=1 ;;
    pull) FL_PULL_ACTIVE=1 ;;
    *) return 0 ;;
  esac
  exec 3>&1
}

# fl_background_stream_open: a --background run is refused in the dispatch (the lab gate, the lease gate, the preflight,
# fl_op_background) before its stream would open, so that refusal had no stream to end and stdout stayed empty (#410). The
# dispatch calls this before the first of them: it opens the stream the run would have had in front, as far as the done
# line needs it (the writer's state and fd 3, the real stdout; no plan line, no log, no stdin change; nothing is exported,
# so the detached run does not see it) and the exit trap sends the line. The commands with a document under plain
# --json have no stream, as in front. A run that is accepted gives the stream back before it prints its op_id line
# (fl_background_stream_release). The detached run inherits fd 3, the caller's stdout, until its own stream opens in its
# dispatch (`exec 3>&1` onto its output file, before any work), which closes that copy.
FL_BG_STREAM=0
FL_BG_SAVED=""
fl_background_stream_open() {
  [[ "${OPT_JSON:-0}" == "1" ]] || return 0
  FL_BG_SAVED="${FL_JSONL:-0} ${FL_JSON_EVENTS:-0} ${FL_PULL_ACTIVE:-0}"
  case "$COMMAND" in
    repair|pull) fl_own_stream_open ;;
    install|adopt) FL_JSONL=1; FL_JSONL_KIND=own; exec 3>&1 ;;
    *)
      [[ "$FL_JSON_MODE" == "stream" || ( "$FL_JSON_MODE" == "doc" && "$OPT_JSONL" == "1" ) ]] || return 0
      FL_JSONL=1; FL_JSONL_KIND=generic; exec 3>&1 ;;
  esac
  FL_BG_STREAM=1
}

# fl_background_stream_release: the run was accepted: its result is the op_id line the launcher prints, not a done line,
# and the stream is the detached run's, not this one's. Put the state back and close fd 3.
fl_background_stream_release() {
  [[ "$FL_BG_STREAM" == "1" ]] || return 0
  FL_BG_STREAM=0
  FL_JSONL_KIND=""
  read -r FL_JSONL FL_JSON_EVENTS FL_PULL_ACTIVE <<<"$FL_BG_SAVED"
  exec 3>&-
}

# fl_repair_done CODE: repair --json ends with one done line, however the run
# ends (the engine's end, or an fl_die on the way). exit_code is the field of
# 0.8, exit the shared one: both carry the process exit code.
FL_REPAIR_DONE_SENT=0
fl_repair_done() {
  local code="$1" f err="" msg
  [[ "${FL_JSON_EVENTS:-0}" == "1" && "$FL_REPAIR_DONE_SENT" != "1" ]] || return 0
  # a dry run that worked is the plan alone; one that was refused ends with its done line
  # (--jsonl and --for-agent end every command with the envelope: the dry run gets its done line too)
  [[ "${FL_DRY_RUN:-0}" != "1" || "$code" != "0" || "$OPT_JSONL" == "1" ]] || return 0
  FL_REPAIR_DONE_SENT=1
  fl_done_fields_v f "$code"
  if [[ "$code" != "0" ]]; then
    msg="${FL_DIE_MESSAGE:-$(fl_log_step_message 0)}"
    err=",\"error\":$(fl_json_str "$msg")"
    { printf '[FAIL] %s\n' "${msg:-benchbar repair failed; see the log}" >&4; } 2>/dev/null || true
  fi
  fl_event "{\"event\":\"done\",\"schema_version\":${FL_SCHEMA_VERSION:-1},\"cli_version\":\"${FL_VERSION:-0}\",\"exit_code\":${code},${f},\"log\":$(fl_json_str "${FL_LOG_FILE:-}")${err}}"
}

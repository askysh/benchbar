#!/usr/bin/env bash
#
# doctor.sh: run checks, keep results, print them as text or JSON.
# Results live in parallel arrays (bash 3.2 has no associative arrays).

FL_D_IDS=()
FL_D_STATUS=()
FL_D_MSG=()
FL_D_FIX=()
FL_D_ACTION=()
# parallel to the checks: "1" for a WARN the person acknowledged (doctor --ack)
FL_D_ACKED=()
# doctor --quick: the ids it left out
FL_D_SKIPPED=""
FL_DOCTOR_QUICK="${FL_DOCTOR_QUICK:-0}"

fl_doctor_reset() { FL_D_IDS=(); FL_D_STATUS=(); FL_D_MSG=(); FL_D_FIX=(); FL_D_ACTION=(); FL_D_ACKED=(); FL_D_SKIPPED=""; }

# fl_check_relevant ID: the checks of a lab run only while the lab is on or it left a trace
# (the share state folder), so a Mac that never turned lan-rooms on sees nothing of it
fl_check_relevant() {
  case "$1" in
    share_scheduler) fl_lab_on lan-rooms || [[ -d "${FL_STATE_DIR}/share" ]] ;;
    *) return 0 ;;
  esac
}

# The checks that wait on a program or the network (brew, python, node,
# bench, curl) and only read. A run starts them in the background, a few at a
# time (FL_DOCTOR_JOBS, slowest first), while the others run in this shell, and
# takes their rows in the order of FL_CHECK_ORDER. A check that must see what
# another one set in this shell stays out of the list. A check in the list
# that this platform does not run is left out.
FL_PARALLEL_CHECKS="${FL_PARALLEL_CHECKS:-bench_version formula_dates python_leaves ping mariadb_version toolchain_pkgconfig honcho_setuptools env_setuptools env_python toolchain_node toolchain_yarn pdf_engine full_disk_access}"
# 1 when doctor --json wants the prerequisites run as a job of the doctor run
FL_DOCTOR_PREREQ=0
FL_DOC_PENDING=""
FL_DOC_PAR_IDS=()
FL_DOC_PAR_PIDS=()

# fl_doctor_job ID: runs one check in a background job and leaves its row in
# the run's folder (status, message, fix, action, then the rows of CHK_MORE,
# each ended by \036 and with \037 between its fields). The id "@prereq" is the
# prerequisites of this Mac (doctor --json): its rows are the ones of FL_P_*.
fl_doctor_job() {
  local id="$1" row buf i=0
  # a job is not the command: its end must not run the command's exit trap (lock, done line)
  trap - EXIT ERR
  FL_IN_JOB=1
  if [[ "$id" == "@prereq" ]]; then
    fl_prereq_run
    buf=""
    while [[ "$i" -lt "${#FL_P_IDS[@]}" ]]; do
      buf="${buf}${FL_P_IDS[$i]}"$'\037'"${FL_P_LEVEL[$i]}"$'\037'"${FL_P_MSG[$i]}"$'\037'"${FL_P_FIX[$i]}"$'\037'"${FL_P_EXTRA[$i]}"$'\036'
      i=$((i + 1))
    done
    printf '%s\035' "$buf" >"${FL_FACTS_DIR}/chk.prereq"
  else
    CHK_STATUS=""; CHK_MSG=""; CHK_FIX=""; CHK_ACTION=""; CHK_MORE=()
    "chk_${id}" || true
    buf="${CHK_STATUS}"$'\037'"${CHK_MSG}"$'\037'"${CHK_FIX}"$'\037'"${CHK_ACTION}"$'\036'
    for row in ${CHK_MORE[@]+"${CHK_MORE[@]}"}; do buf="${buf}${row}"$'\036'; done
    # one write, ended by \035: a file without it is a job that died half way
    printf '%s\035' "$buf" >"${FL_FACTS_DIR}/chk.${id}"
  fi
  # tells the run that a slot is free (see fl_doctor_wait)
  [[ -z "$FL_FACTS_WAKE" ]] || printf '.\n' >&9 2>/dev/null || true
}

# fl_doctor_start ID: a background job for ID, a process group of its own
fl_doctor_start() {
  fl_par_group_on
  { fl_doctor_job "$1" & } 2>/dev/null
  FL_DOC_PAR_IDS+=("$1"); FL_DOC_PAR_PIDS+=("$!"); fl_par_add "$!"
  fl_par_group_off
}

# fl_doctor_pump: starts the pending parallel checks while a slot is free; never waits
fl_doctor_pump() {
  local id
  while [[ -n "$FL_DOC_PENDING" ]] && fl_par_free; do
    id="${FL_DOC_PENDING%% *}"
    if [[ "$FL_DOC_PENDING" == *" "* ]]; then FL_DOC_PENDING="${FL_DOC_PENDING#* }"; else FL_DOC_PENDING=""; fi
    fl_doctor_start "$id"
  done
  return 0
}

# fl_doctor_wait PID: waits for the job PID. While checks are still waiting
# for a slot, each job that ends starts the next one at once: the wait is on
# the wake fifo (one line per ended job), a second at most, not on PID.
fl_doctor_wait() {
  local x
  if [[ -n "$FL_FACTS_WAKE" ]]; then
    while [[ -n "$FL_DOC_PENDING" ]] && kill -0 "$1" 2>/dev/null; do
      read -r -t 1 -u 9 x 2>/dev/null || true
      fl_doctor_pump
    done
  fi
  wait "$1" 2>/dev/null || true
}

# fl_doctor_unpend ID: ID will not be started in the background any more
fl_doctor_unpend() {
  local w out=""
  for w in $FL_DOC_PENDING; do [[ "$w" == "$1" ]] || out="${out}${out:+ }${w}"; done
  FL_DOC_PENDING="$out"
}

# fl_prereq_take: FL_P_* from the file of the prerequisites job; 1 when there is none
fl_prereq_take() {
  local blob="" rec
  [[ -n "$FL_FACTS_DIR" && -f "${FL_FACTS_DIR}/chk.prereq" ]] || return 1
  IFS= read -r -d '' blob <"${FL_FACTS_DIR}/chk.prereq" || true
  [[ "$blob" == *$'\035' ]] || return 1
  FL_P_IDS=(); FL_P_LEVEL=(); FL_P_MSG=(); FL_P_FIX=(); FL_P_EXTRA=()
  while [[ "$blob" == *$'\036'* ]]; do
    rec="${blob%%$'\036'*}"; blob="${blob#*$'\036'}"
    FL_P_IDS+=("${rec%%$'\037'*}"); rec="${rec#*$'\037'}"
    FL_P_LEVEL+=("${rec%%$'\037'*}"); rec="${rec#*$'\037'}"
    FL_P_MSG+=("${rec%%$'\037'*}"); rec="${rec#*$'\037'}"
    FL_P_FIX+=("${rec%%$'\037'*}"); FL_P_EXTRA+=("${rec#*$'\037'}")
  done
  FL_P_RAN=1
}

# fl_doctor_take ID: CHK_* and CHK_MORE from the file of a finished job; 1 when
# the job left none (it died), and the caller runs the check itself
fl_doctor_take() {
  local blob="" rest rec
  [[ -f "${FL_FACTS_DIR}/chk.${1}" ]] || return 1
  IFS= read -r -d '' blob <"${FL_FACTS_DIR}/chk.${1}" || true
  [[ "$blob" == *$'\035' ]] || return 1
  CHK_MORE=()
  rec="${blob%%$'\036'*}"; rest="${blob#*$'\036'}"
  CHK_STATUS="${rec%%$'\037'*}"; rec="${rec#*$'\037'}"
  CHK_MSG="${rec%%$'\037'*}"; rec="${rec#*$'\037'}"
  CHK_FIX="${rec%%$'\037'*}"; CHK_ACTION="${rec#*$'\037'}"
  while [[ "$rest" == *$'\036'* ]]; do
    CHK_MORE+=("${rest%%$'\036'*}")
    rest="${rest#*$'\036'}"
  done
  return 0
}

# fl_doctor_run [GROUP...]: runs every check (or only the given groups).
CHK_MORE=()
fl_doctor_run() {
  local id groups="$*" g row todo=() todo_str=" " i j started n rest pre_done
  local pre_status=() pre_msg=() pre_fix=() pre_action=() pre_more=() pre_n=()
  fl_doctor_reset
  # what the checks ask again and again is read once for the run (facts.sh)
  fl_facts_begin
  FL_DOC_PENDING=""; FL_DOC_PAR_IDS=(); FL_DOC_PAR_PIDS=()
  # a plan may add checks (port_block while ports move)
  for id in ${FL_PLAN_CHECKS:-} $FL_CHECK_ORDER; do
    fl_check_relevant "$id" || continue
    g="$(fl_check_group "$id")"
    if [[ -n "$groups" ]]; then
      case " $groups " in *" $g "*) ;; *) continue ;; esac
    fi
    if [[ "$FL_DOCTOR_QUICK" == "1" ]]; then
      case " $FL_QUICK_SKIP " in *" $id "*) FL_D_SKIPPED="${FL_D_SKIPPED}${FL_D_SKIPPED:+ }${id}"; continue ;; esac
    fi
    todo+=("$id"); todo_str="${todo_str}${id} "
  done
  if [[ -n "$FL_FACTS_DIR" && "$FL_DOCTOR_JOBS" -gt 1 ]]; then
    # the listeners of every port, once, before any job needs them
    if declare -F fl__listen_rows >/dev/null; then fl__listen_rows "" >/dev/null || true
    elif declare -F fl__ss_listeners >/dev/null; then fl__ss_listeners "" >/dev/null || true; fi
    if declare -F fl_facts_warm_apps >/dev/null; then fl_facts_warm_apps "$todo_str"; fi
    # the prerequisites of doctor --json run beside the slow checks, third in line
    n=0
    for id in $FL_PARALLEL_CHECKS; do
      case "$todo_str" in *" $id "*) FL_DOC_PENDING="${FL_DOC_PENDING}${FL_DOC_PENDING:+ }${id}"; n=$((n + 1)) ;; esac
      if [[ "$n" == "2" && "$FL_DOCTOR_PREREQ" == "1" ]]; then FL_DOC_PENDING="${FL_DOC_PENDING} @prereq"; n=3; fi
    done
    if [[ "$FL_DOCTOR_PREREQ" == "1" && "$n" -lt 3 ]]; then FL_DOC_PENDING="${FL_DOC_PENDING}${FL_DOC_PENDING:+ }@prereq"; fi
  fi
  # The checks that are not in FL_PARALLEL_CHECKS run in this shell, one after
  # the other as always. While background jobs are out they run first, right
  # now, and their rows are kept: the run does not sit idle at a slow check
  # whose job is still busy. The rows are still taken in the order of the list.
  pre_done=" "
  if [[ -n "$FL_FACTS_DIR" && "$FL_DOCTOR_JOBS" -gt 1 ]]; then
    i=0
    for id in ${todo[@]+"${todo[@]}"}; do
      case " $FL_PARALLEL_CHECKS " in *" $id "*) i=$((i + 1)); continue ;; esac
      fl_doctor_pump
      CHK_STATUS=""; CHK_MSG=""; CHK_FIX=""; CHK_ACTION=""; CHK_MORE=()
      "chk_${id}" || true
      pre_status[i]="$CHK_STATUS"; pre_msg[i]="$CHK_MSG"; pre_fix[i]="$CHK_FIX"; pre_action[i]="$CHK_ACTION"
      pre_more[i]=""
      for row in ${CHK_MORE[@]+"${CHK_MORE[@]}"}; do pre_more[i]="${pre_more[i]}${row}"$'\036'; done
      pre_n[i]="${#CHK_MORE[@]}"
      pre_done="${pre_done}${i} "
      i=$((i + 1))
    done
  fi
  i=0
  for id in ${todo[@]+"${todo[@]}"}; do
    if [[ "$pre_done" == *" $i "* ]]; then
      CHK_STATUS="${pre_status[i]}"; CHK_MSG="${pre_msg[i]}"; CHK_FIX="${pre_fix[i]}"; CHK_ACTION="${pre_action[i]}"; CHK_MORE=()
      rest="${pre_more[i]}"
      while [[ "$rest" == *$'\036'* ]]; do CHK_MORE+=("${rest%%$'\036'*}"); rest="${rest#*$'\036'}"; done
    else
      fl_doctor_pump
      started=""
      j=0
      while [[ "$j" -lt "${#FL_DOC_PAR_IDS[@]}" ]]; do
        if [[ "${FL_DOC_PAR_IDS[$j]}" == "$id" ]]; then started=1; fl_doctor_wait "${FL_DOC_PAR_PIDS[$j]}"; break; fi
        j=$((j + 1))
      done
      # one that never got a slot is not waited for: it runs here, now
      [[ -n "$started" ]] || fl_doctor_unpend "$id"
      if [[ -z "$started" ]] || ! fl_doctor_take "$id"; then
        CHK_STATUS=""; CHK_MSG=""; CHK_FIX=""; CHK_ACTION=""; CHK_MORE=()
        "chk_${id}" || true
      fi
    fi
    i=$((i + 1))
    # a check may report one row per finding instead (CHK_MORE, \037
    # separated status, message, fix, action), all under its id
    if [[ -n "$CHK_STATUS" || "${#CHK_MORE[@]}" == "0" ]]; then
      FL_D_IDS+=("$id"); FL_D_STATUS+=("$CHK_STATUS"); FL_D_MSG+=("$CHK_MSG"); FL_D_FIX+=("$CHK_FIX"); FL_D_ACTION+=("$CHK_ACTION")
      fl_log "check ${id}: ${CHK_STATUS} ${CHK_MSG}"
    fi
    for row in ${CHK_MORE[@]+"${CHK_MORE[@]}"}; do
      IFS=$'\037' read -r CHK_STATUS CHK_MSG CHK_FIX CHK_ACTION <<<"$row"
      FL_D_IDS+=("$id"); FL_D_STATUS+=("$CHK_STATUS"); FL_D_MSG+=("$CHK_MSG"); FL_D_FIX+=("$CHK_FIX"); FL_D_ACTION+=("$CHK_ACTION")
      fl_log "check ${id}: ${CHK_STATUS} ${CHK_MSG}"
    done
  done
  # the prerequisites that never got a slot, or whose job died, are run by cmd_doctor
  fl_doctor_unpend "@prereq"
  fl_par_wait_all
  if declare -F fl_facts_wait_warm >/dev/null; then fl_facts_wait_warm; fi
  if [[ "$FL_DOCTOR_PREREQ" == "1" ]]; then fl_prereq_take || true; fi
  fl_facts_end
}

fl_doctor_count() {
  local want="$1" n=0 s
  for s in ${FL_D_STATUS[@]+"${FL_D_STATUS[@]}"}; do [[ "$s" == "$want" ]] && n=$((n + 1)); done
  printf '%d' "$n"
}

# ---------------------------------------------------------------- acknowledged warnings
#
# doctor --ack CHECK silences one named WARN for this bench. The record is
# the bench's own state file, ACK_<id>=<the message it acknowledged>; when the
# check's message changes the ack lapses (the warning is a different one now).
# A FAIL cannot be acked. The check stays in doctor --json at level warn with
# "acked": true; the text output prints one dim line for it, and --fix-hints
# leaves it out. repair does not look at acks.

# fl_doctor_id_msg_v VAR ID: the messages of ID's rows that are not ok, joined with " | "
fl_doctor_id_msg_v() {
  local __i=0 __m=""
  while [[ "$__i" -lt "${#FL_D_IDS[@]}" ]]; do
    if [[ "${FL_D_IDS[$__i]}" == "$2" && "${FL_D_STATUS[$__i]}" != "ok" ]]; then __m="${__m}${__m:+ | }${FL_D_MSG[$__i]}"; fi
    __i=$((__i + 1))
  done
  printf -v "$1" '%s' "$__m"
}

# fl_doctor_apply_acks: marks the WARN rows whose id has an ack with the same message
fl_doctor_apply_acks() {
  local i=0 id stored msg
  FL_D_ACKED=()
  while [[ "$i" -lt "${#FL_D_IDS[@]}" ]]; do
    FL_D_ACKED[i]=0
    if [[ "${FL_D_STATUS[$i]}" == "warn" ]]; then
      id="${FL_D_IDS[$i]}"
      stored="$(fl_bstate_get "ACK_${id}")"
      if [[ -n "$stored" ]]; then
        fl_doctor_id_msg_v msg "$id"
        [[ "$stored" != "$msg" ]] || FL_D_ACKED[i]=1
      fi
    fi
    i=$((i + 1))
  done
}

fl_doctor_is_acked() { [[ "${FL_D_ACKED[$1]:-0}" == "1" ]]; }

# fl_doctor_acked_ids: the ids of acked warnings, one per line, each once
fl_doctor_acked_ids() {
  local i=0 seen=" "
  while [[ "$i" -lt "${#FL_D_IDS[@]}" ]]; do
    if fl_doctor_is_acked "$i"; then
      case "$seen" in *" ${FL_D_IDS[$i]} "*) ;; *) seen="${seen}${FL_D_IDS[$i]} "; printf '%s\n' "${FL_D_IDS[$i]}" ;; esac
    fi
    i=$((i + 1))
  done
}

# fl_doctor_ack ID: doctor --ack ID
fl_doctor_ack() {
  local id="$1" i=0 known=0 level="" msg
  [[ "$id" =~ ^[a-z][a-z0-9_]*$ ]] || fl_die "doctor --ack takes a check id (benchbar doctor --json lists them): '${id}'" "Example: benchbar doctor --ack cleanmymac"
  while [[ "$i" -lt "${#FL_D_IDS[@]}" ]]; do
    if [[ "${FL_D_IDS[$i]}" == "$id" ]]; then
      known=1
      case "${FL_D_STATUS[$i]}" in fail) level=fail ;; warn) [[ "$level" == fail ]] || level=warn ;; esac
    fi
    i=$((i + 1))
  done
  [[ "$known" == "1" ]] || fl_die "No check named '${id}' in this bench's doctor report." "benchbar doctor --json lists the check ids"
  [[ "$level" != "fail" ]] || fl_die "${id} FAILs: a failing check cannot be acknowledged." "Fix it: benchbar doctor --fix-hints"
  if [[ "$level" != "warn" ]]; then
    fl_ok "${id} is ok: nothing to acknowledge"
    return 0
  fi
  fl_doctor_id_msg_v msg "$id"
  [[ "$(fl_bstate_get "ACK_${id}")" == "$msg" ]] || fl_changed state "ack:${id}" "acknowledged: ${msg}"
  fl_bstate_set "ACK_${id}" "$msg"
  fl_ok "acknowledged ${id} for ${FL_BENCH_NAME}: ${msg}"
  fl_note "it lapses when the message changes; undo it: ${FL_SELF} doctor --unack ${id} --bench-dir $(printf '%q' "$FL_BENCH_DIR")"
}

# fl_doctor_unack ID: doctor --unack ID
fl_doctor_unack() {
  local id="$1"
  [[ "$id" =~ ^[a-z][a-z0-9_]*$ ]] || fl_die "doctor --unack takes a check id: '${id}'"
  if [[ -z "$(fl_bstate_get "ACK_${id}")" ]]; then
    fl_ok "unchanged: ${id} was not acknowledged"
    return 0
  fi
  fl_bstate_del "ACK_${id}"
  fl_changed state "ack:${id}" "no longer acknowledged"
  fl_ok "${id} is no longer acknowledged"
}

# fl_doctor_ack_doc ACTION ID: under --json the result of --ack and --unack is
# one small document: the check and every id with a stored acknowledgement
fl_doctor_ack_doc() {
  local file line ids=()
  [[ "${OPT_JSON:-0}" == "1" ]] || return 0
  file="$(fl_bench_state_file_for "$FL_BENCH_DIR")"
  if [[ -r "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" == ACK_*=* ]] || continue
      line="${line#ACK_}"; ids+=("${line%%=*}")
    done <"$file"
  fi
  fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"action":%s,"check":%s,"acked":%s}' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$1")" "$(fl_json_str "$2")" "$(fl_json_str_array ${ids[@]+"${ids[@]}"})")"
}

# fl_doctor_print [compact]: compact mode hides [OK] lines and empty groups.
# A [FAIL] gets a "see:" line with its section of the doctor guide, after
# the fix line (the [OK], [WARN], [FAIL] and fix: lines stay as they were
# for parsers; --json never has it).
fl_doctor_print() {
  local compact="${1:-}" i=0 group last_group="" label
  while [[ "$i" -lt "${#FL_D_IDS[@]}" ]]; do
    group="$(fl_check_group "${FL_D_IDS[$i]}")"
    if [[ "$compact" == "compact" && "${FL_D_STATUS[$i]}" == "ok" ]]; then i=$((i + 1)); continue; fi
    if [[ "$group" != "$last_group" ]]; then
      printf '\n%s%s%s\n' "$FL_BOLD" "$(printf '%s' "$group" | tr '[:lower:]' '[:upper:]')" "$FL_RESET"
      last_group="$group"
    fi
    label="$(fl_check_label "${FL_D_IDS[$i]}")"
    case "${FL_D_STATUS[$i]}" in
      ok) fl_ok "${label}: ${FL_D_MSG[$i]}" ;;
      warn)
        if fl_doctor_is_acked "$i"; then
          fl_info "acked: ${label}: ${FL_D_MSG[$i]}   (benchbar doctor --unack ${FL_D_IDS[$i]} undoes it)"
        else
          fl_warn "${label}: ${FL_D_MSG[$i]}"; [[ -n "${FL_D_FIX[$i]}" ]] && fl_fix "${FL_D_FIX[$i]}"
        fi ;;
      fail) fl_fail "${label}: ${FL_D_MSG[$i]}"; [[ -n "${FL_D_FIX[$i]}" ]] && fl_fix "${FL_D_FIX[$i]}"
            fl_see "$(fl_docs_check_url "${FL_D_IDS[$i]}")" ;;
    esac
    i=$((i + 1))
  done
  printf '\n  %s%d ok, %d warn, %d fail%s\n' "$FL_BOLD" "$(fl_doctor_count ok)" "$(fl_doctor_count warn)" "$(fl_doctor_count fail)" "$FL_RESET"
  [[ -z "$FL_D_SKIPPED" ]] || fl_info "quick: skipped the slow checks: ${FL_D_SKIPPED}"
}

# ---------------------------------------------------------------- prerequisites
#
# What a Mac needs before an install, without a bench (doctor --prerequisites,
# the BenchBar app's Check Your Mac page; docs/json-schema.md). The same list
# is the first group of a plain doctor and the "prerequisites" array of
# doctor --json; it is not counted in summary or in the exit code there.
# Parallel arrays like the checks above. FL_BENCH_DIR names the folder a
# new bench would go to; it does not have to exist.

FL_P_IDS=()
FL_P_LEVEL=()
FL_P_MSG=()
FL_P_FIX=()
FL_P_EXTRA=()
FL_P_RAN=0
# where Homebrew lives when it is not on PATH yet, and how to install it
# (the Apple Silicon prefix, or /usr/local on an Intel Mac)
# FL_BREW_ALT_BIN (a test sets it): else the prefix for this Mac, found only when the check runs
# shellcheck disable=SC2016  # the command is for a person to run
FL_BREW_INSTALL_CMD='/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
# free space (GB) from which the disk check is ok and from which it only warns
FL_PREREQ_DISK_OK_GB="${FL_PREREQ_DISK_OK_GB:-20}"
FL_PREREQ_DISK_WARN_GB="${FL_PREREQ_DISK_WARN_GB:-10}"

fl_prereq_label() {
  case "$1" in
    apple_silicon) printf 'Apple Silicon' ;;
    macos_version) printf 'macOS version' ;;
    command_line_tools) printf 'Command Line Tools' ;;
    homebrew) printf 'Homebrew' ;;
    disk_free) printf 'Free disk space' ;;
    bench_folder) printf 'Bench folder' ;;
    cleanmymac) printf 'CleanMyMac' ;;
    mole) printf 'Mole' ;;
    linux_distro) printf 'Linux distribution' ;;
    architecture) printf 'CPU architecture' ;;
    regular_user) printf 'Regular user' ;;
    sudo) printf 'sudo' ;;
    apt) printf 'apt' ;;
    systemd) printf 'systemd' ;;
    linger) printf 'Linger' ;;
    memory) printf 'Memory' ;;
    inotify_watches) printf 'File watchers' ;;
    user_bus) printf 'User bus' ;;
    mariadb_password) printf 'MariaDB root password' ;;
    default_ports) printf 'Default ports' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fl_prereq_add ID LEVEL MESSAGE [FIX [EXTRA_JSON]]
fl_prereq_add() {
  FL_P_IDS+=("$1"); FL_P_LEVEL+=("$2"); FL_P_MSG+=("$3"); FL_P_FIX+=("${4:-}"); FL_P_EXTRA+=("${5:-}")
  fl_log "prerequisite ${1}: ${2} ${3}"
}

fl_prereq_count() {
  local want="$1" n=0 l
  for l in ${FL_P_LEVEL[@]+"${FL_P_LEVEL[@]}"}; do [[ "$l" == "$want" ]] && n=$((n + 1)); done
  printf '%d' "$n"
}

# The checks that depend on the platform, in two places of the list: first
# (the machine itself) and extra (after the bench folder). doctor-linux.sh
# replaces both with the Linux ones.
fl_prereq_platform_first() {
  local arch os major clt brew_bin
  arch="${FL_ARCH:-$(uname -m)}"
  if [[ "$arch" == "arm64" ]]; then fl_prereq_add apple_silicon ok "arm64"
  else fl_prereq_add apple_silicon fail "this Mac is ${arch}; BenchBar and its Homebrew setup are for Apple Silicon" "BenchBar needs an Apple Silicon Mac"; fi

  os="$(sw_vers -productVersion 2>/dev/null || true)"; major="${os%%.*}"
  if [[ ! "$major" =~ ^[0-9]+$ ]]; then fl_prereq_add macos_version fail "could not read the macOS version" "update macOS in System Settings, Software Update"
  elif [[ "$major" -ge 14 ]]; then fl_prereq_add macos_version ok "macOS ${os}"
  else fl_prereq_add macos_version fail "macOS ${os}; macOS 14 or later is needed" "update macOS in System Settings, Software Update"; fi

  clt="$(xcode-select -p 2>/dev/null || true)"
  if [[ -n "$clt" && -d "$clt" ]]; then fl_prereq_add command_line_tools ok "$clt"
  else fl_prereq_add command_line_tools fail "the Xcode Command Line Tools are not installed" "xcode-select --install"; fi

  brew_bin="$(command -v brew 2>/dev/null || true)"
  local alt_bin="${FL_BREW_ALT_BIN:-$(fl_brew_default_prefix)/bin/brew}"
  [[ -n "$brew_bin" ]] || { [[ -x "$alt_bin" ]] && brew_bin="$alt_bin"; }
  if [[ -n "$brew_bin" ]]; then fl_prereq_add homebrew ok "brew at ${brew_bin}"
  else fl_prereq_add homebrew fail "brew was not found" "$FL_BREW_INSTALL_CMD"; fi
}

fl_prereq_platform_extra() {
  # CleanMyMac and Mole: doctor's own checks, for this folder
  CHK_STATUS=""; CHK_MSG=""; CHK_FIX=""; chk_cleanmymac
  fl_prereq_add cleanmymac "$CHK_STATUS" "$CHK_MSG" "$CHK_FIX"
  CHK_STATUS=""; CHK_MSG=""; CHK_FIX=""; chk_mole
  fl_prereq_add mole "$CHK_STATUS" "$CHK_MSG" "$CHK_FIX"
}

# fl_prereq_run: fills FL_P_*. The target folder is FL_BENCH_DIR.
fl_prereq_run() {
  local kb gb level dir p offset conflicts own=""
  FL_P_IDS=(); FL_P_LEVEL=(); FL_P_MSG=(); FL_P_FIX=(); FL_P_EXTRA=(); FL_P_RAN=1
  # the listeners and the benches' ports are read once for the run (facts.sh);
  # as a job of a doctor run they are the run's own
  [[ -n "$FL_FACTS_DIR" ]] || { fl_facts_begin; own=1; }

  fl_prereq_platform_first

  kb="$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [[ "$kb" =~ ^[0-9]+$ ]]; then
    gb=$((kb / 1024 / 1024))
    level=ok
    [[ "$gb" -ge "$FL_PREREQ_DISK_OK_GB" ]] || level=warn
    [[ "$gb" -ge "$FL_PREREQ_DISK_WARN_GB" ]] || level=fail
    fl_prereq_add disk_free "$level" "${gb} GB free" "$([[ "$level" == ok ]] || printf 'free space on the volume of %s' "$HOME")" ",\"free_gb\":${gb}"
  else
    fl_prereq_add disk_free warn "could not read the free disk space" "free space on the volume of ${HOME}" ",\"free_gb\":null"
  fi

  # the folder: a path benchbar can carry, and not in a place iCloud syncs
  dir="$FL_BENCH_DIR"
  if ! fl_bench_path_ok "$dir"; then
    fl_prereq_add bench_folder fail "${dir} contains ${FL_TEXT_PROBLEM}, which benchbar cannot carry as plain text" "choose a folder outside iCloud Drive, Desktop and Documents, such as ~/frappe-bench"
  else
    level=ok; p=""
    case "$dir" in
      "$HOME/Library/Mobile Documents"|"$HOME/Library/Mobile Documents/"*|"$HOME/Library/CloudStorage/iCloud"*) level=fail; p="iCloud Drive" ;;
      "$HOME/Desktop"|"$HOME/Desktop/"*) level=warn; p="Desktop" ;;
      "$HOME/Documents"|"$HOME/Documents/"*) level=warn; p="Documents" ;;
    esac
    case "$level" in
      ok) fl_prereq_add bench_folder ok "$dir" ;;
      warn) fl_prereq_add bench_folder warn "${dir} is in ${p}, which iCloud can sync and evict from" "choose a folder outside iCloud Drive, Desktop and Documents, such as ~/frappe-bench" ;;
      *) fl_prereq_add bench_folder fail "${dir} is in ${p}, whose files are evicted to the cloud and break a bench" "choose a folder outside iCloud Drive, Desktop and Documents, such as ~/frappe-bench" ;;
    esac
  fi

  fl_prereq_platform_extra

  # the default block 0: ports 8000, 9000, 11000 and 13000
  conflicts="$(fl_port_block_conflicts 0)"
  if [[ -z "$conflicts" ]]; then
    fl_prereq_add default_ports ok "ports 8000, 9000, 11000 and 13000 are free" "" ",\"port_offset\":0"
  elif offset="$(fl_port_next_free_offset)"; then
    fl_prereq_add default_ports warn "$(printf '%s' "$conflicts" | tr '\n' ';' | sed 's/;$//; s/;/; /g'); a new bench gets port block ${offset}" "the new bench gets port block ${offset} (--port-offset ${offset})" ",\"port_offset\":${offset}"
  else
    # every block is taken: install would fail after its system steps, so
    # this stops the wizard here, and no --port-offset can help
    fl_prereq_add default_ports fail "$(printf '%s' "$conflicts" | tr '\n' ';' | sed 's/;$//; s/;/; /g'); no port block up to ${FL_PORT_MAX_OFFSET} is free" "stop or remove a bench, or the program on these ports, to free a port block" ",\"port_offset\":null"
  fi
  [[ -z "$own" ]] || fl_facts_end
}

# fl_prereq_print: the group, in the shape of doctor's own
fl_prereq_print() {
  local i=0
  printf '\n%sPREREQUISITES%s\n' "$FL_BOLD" "$FL_RESET"
  while [[ "$i" -lt "${#FL_P_IDS[@]}" ]]; do
    case "${FL_P_LEVEL[$i]}" in
      ok) fl_ok "$(fl_prereq_label "${FL_P_IDS[$i]}"): ${FL_P_MSG[$i]}" ;;
      warn) fl_warn "$(fl_prereq_label "${FL_P_IDS[$i]}"): ${FL_P_MSG[$i]}"; [[ -z "${FL_P_FIX[$i]}" ]] || fl_fix "${FL_P_FIX[$i]}" ;;
      *) fl_fail "$(fl_prereq_label "${FL_P_IDS[$i]}"): ${FL_P_MSG[$i]}"; [[ -z "${FL_P_FIX[$i]}" ]] || fl_fix "${FL_P_FIX[$i]}" ;;
    esac
    i=$((i + 1))
  done
}

# fl_prereq_json_v VAR: the array of checks, [{...},...]
fl_prereq_json_v() {
  local __out="[" __sep="" __i=0 __m __f
  while [[ "$__i" -lt "${#FL_P_IDS[@]}" ]]; do
    fl_json_str_v __m "${FL_P_MSG[$__i]}"; fl_json_str_v __f "${FL_P_FIX[$__i]}"
    __out="${__out}${__sep}{\"id\":\"${FL_P_IDS[$__i]}\",\"label\":$(fl_json_str "$(fl_prereq_label "${FL_P_IDS[$__i]}")"),\"level\":\"${FL_P_LEVEL[$__i]}\",\"message\":${__m},\"fix_command\":${__f},\"fix_quoted\":$(fl_fix_quoted_json "${FL_P_FIX[$__i]}")${FL_P_EXTRA[$__i]}}"
    __sep=","; __i=$((__i + 1))
  done
  printf -v "$1" '%s]' "$__out"
}

# doctor --prerequisites --json: its own document
fl_prereq_print_json() {
  local arr
  fl_prereq_json_v arr
  printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"prerequisites":%s,"summary":{"ok":%d,"warn":%d,"fail":%d}}\n' \
    "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$arr" \
    "$(fl_prereq_count ok)" "$(fl_prereq_count warn)" "$(fl_prereq_count fail)"
}

# Schema 1 (docs/json-schema.md). "level" and "fix_command" are the contract
# names; "status" and "fix" are the frappe-mac 0.2.0 names, kept for older readers.
fl_doctor_print_json() {
  local i=0 sep="" group label e_label e_msg e_fix j_fix j_act acked_s j_site
  # status's rule: a folder benchbar does not know has no site of its own to name
  # (the one doctor would print is the default's guess)
  if fl_bench_adopted; then fl_json_str_v j_site "$FL_SITE"; else j_site=null; fi
  printf '{"schema_version":%d,"cli_version":"%s","bench":"%s","name":"%s","site":%s,"profile":"%s","profile_source":"%s","checks":[' \
    "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$(fl_json_escape "$FL_BENCH_DIR")" "$(fl_json_escape "$FL_BENCH_NAME")" \
    "$j_site" "$(fl_json_escape "$FL_PROFILE")" "$(fl_doctor_profile_source)"
  while [[ "$i" -lt "${#FL_D_IDS[@]}" ]]; do
    # the _v forms: no process for each escaped value (fifty checks, six values each)
    group="$(fl_check_group "${FL_D_IDS[$i]}")"; label="$(fl_check_label "${FL_D_IDS[$i]}")"
    fl_json_escape_v e_label "$label"; fl_json_escape_v e_msg "${FL_D_MSG[$i]}"; fl_json_escape_v e_fix "${FL_D_FIX[$i]}"
    fl_json_str_v j_fix "${FL_D_FIX[$i]}"; fl_json_str_v j_act "${FL_D_ACTION[$i]}"
    if fl_doctor_is_acked "$i"; then acked_s=true; else acked_s=false; fi
    printf '%s{"id":"%s","group":"%s","label":"%s","level":"%s","message":"%s","fix_command":%s,"fix_quoted":%s,"action":%s,"status":"%s","fix":"%s","acked":%s}' \
      "$sep" "${FL_D_IDS[$i]}" "$group" "$e_label" \
      "${FL_D_STATUS[$i]}" "$e_msg" "$j_fix" "$(fl_fix_quoted_json "${FL_D_FIX[$i]}")" "$j_act" \
      "${FL_D_STATUS[$i]}" "$e_fix" "$acked_s"
    sep=","
    i=$((i + 1))
  done
  # the acknowledged warnings, and what --quick left out
  local acked quick=false skipped ids=() id
  while IFS= read -r id; do [[ -z "$id" ]] || ids+=("$id"); done < <(fl_doctor_acked_ids)
  acked="$(fl_json_str_array ${ids[@]+"${ids[@]}"})"
  ids=()
  for id in $FL_D_SKIPPED; do ids+=("$id"); done
  skipped="$(fl_json_str_array ${ids[@]+"${ids[@]}"})"
  [[ "$FL_DOCTOR_QUICK" != "1" ]] || quick=true
  # the prerequisites of this Mac, next to the checks and not counted in the summary
  if [[ "$FL_P_RAN" == "1" ]]; then
    local prereq
    fl_prereq_json_v prereq
    printf '],"acked":%s,"quick":%s,"skipped_checks":%s,"prerequisites":%s,"summary":{"ok":%d,"warn":%d,"fail":%d}}\n' "$acked" "$quick" "$skipped" "$prereq" "$(fl_doctor_count ok)" "$(fl_doctor_count warn)" "$(fl_doctor_count fail)"
  else
    printf '],"acked":%s,"quick":%s,"skipped_checks":%s,"summary":{"ok":%d,"warn":%d,"fail":%d}}\n' "$acked" "$quick" "$skipped" "$(fl_doctor_count ok)" "$(fl_doctor_count warn)" "$(fl_doctor_count fail)"
  fi
}

# doctor --fix-hints: the fix command of every failing and warning check,
# failures first, one per line, each once. For agents and scripts.
fl_doctor_print_fix_hints() {
  local want i plain
  for want in fail warn; do
    i=0
    while [[ "$i" -lt "${#FL_D_IDS[@]}" ]]; do
      if [[ "${FL_D_STATUS[$i]}" == "$want" && -n "${FL_D_FIX[$i]}" ]] && ! fl_doctor_is_acked "$i"; then
        fl_fix_plain_v plain "${FL_D_FIX[$i]}"; printf '%s\n' "$plain"
      fi
      i=$((i + 1))
    done
  done | awk '!seen[$0]++'
}

# fl_profile_display: the profile for a header, with its source when it is
# only the default ("v15-lts (default: no profile matches this bench)")
# fl_doctor_profile_source: where the profile came from, for doctor --json
# (flag, team, stored, detected or default; default means no profile matched)
fl_doctor_profile_source() {
  printf '%s' "${FL_PROFILE_SOURCE:-default}"
}

fl_profile_display() {
  # a fresh install has no bench to match yet: its default is the choice, not a guess
  if fl_profile_is_guess; then printf '%s (default: no profile matches this bench)' "$FL_PROFILE"; else printf '%s' "$FL_PROFILE"; fi
}

# Prints the distinct repair actions of flagged checks, in dependency order.
fl_doctor_actions() {
  local a i flagged=""
  i=0
  while [[ "$i" -lt "${#FL_D_IDS[@]}" ]]; do
    if [[ "${FL_D_STATUS[$i]}" != "ok" && -n "${FL_D_ACTION[$i]}" ]]; then
      flagged="${flagged} ${FL_D_ACTION[$i]}"
    fi
    i=$((i + 1))
  done
  for a in $FL_ACTION_ORDER; do
    case " $flagged " in *" $a "*) printf '%s\n' "$a" ;; esac
  done
}

fl_doctor_checks_for_action() {
  local action="$1" i=0
  while [[ "$i" -lt "${#FL_D_IDS[@]}" ]]; do
    [[ "${FL_D_ACTION[$i]}" == "$action" && "${FL_D_STATUS[$i]}" != "ok" ]] && printf '%s\n' "$(fl_check_label "${FL_D_IDS[$i]}")"
    i=$((i + 1))
  done
}
